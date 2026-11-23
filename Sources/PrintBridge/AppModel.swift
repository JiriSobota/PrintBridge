import AppKit
import BrotherKit
import Foundation
import Network
import Observation

enum AppSection: String, CaseIterable, Identifiable {
    case connect, overview, print, wifi, firmware, console, tips
    var id: String { rawValue }

    var title: String {
        switch self {
        case .connect: return L("Connection")
        case .overview: return L("Overview")
        case .print: return L("Print")
        case .wifi: return "Wi‑Fi"
        case .firmware: return "Firmware"
        case .console: return L("Console")
        case .tips: return L("Reliability")
        }
    }

    var symbol: String {
        switch self {
        case .connect: return "cable.connector"
        case .overview: return "printer.fill"
        case .print: return "doc.on.doc"
        case .wifi: return "wifi"
        case .firmware: return "arrow.down.circle"
        case .console: return "terminal"
        case .tips: return "checkmark.shield"
        }
    }
}

struct NetworkPrinter: Identifiable, Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting(String)
    case connected(name: String, kind: TransportKind, host: String?)
    case failed(String)

    var isConnected: Bool { if case .connected = self { return true }; return false }
}

enum ApplyState {
    case idle
    case running(WiFiApplyStage)
    case done(WiFiApplyOutcome)
    case error(String)
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var section: AppSection = .connect
    var usbDevices: [USBPrinterDevice] = []
    var networkPrinters: [NetworkPrinter] = []
    var manualHost = ""
    var connection: ConnectionState = .disconnected
    var log: [LogEntry] = []
    var activity: String?
    var lastError: String?

    var status: PrinterStatus?
    var currentNetwork: CurrentNetwork?
    var tonerPercent: Int?

    var scanResult: WiFiScanResult?
    var scanProgress: String?
    var applyState: ApplyState = .idle

    var firmware: FirmwareInfo?
    var firmwareChecks: [String: FirmwareCheck] = [:]
    var downloadProgress: Double?
    var downloadedFiles: [String: URL] = [:]
    var uploadProgress: Double?
    var uploadMessage: String?

    // Tisk
    var printItems: [PrintItem] = []
    var printOptions = PrintOptions()
    var queues: [PrintQueue] = []
    var selectedQueue: String?
    var jobs: [PrintJob] = []
    var printMessage: String?
    var printError: String?
    var isPrinting = false
    var isSettingUpQueue = false
    var launchAtLogin = LoginItem.isEnabled
    var languagePreference: String? = L10n.preference
    /// Zvýší se při změně jazyka – kořenový pohled se tím překreslí.
    var languageRevision = 0

    @ObservationIgnored private var printer: BrotherPrinter?
    @ObservationIgnored private var jobTimer: Timer?
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "printbridge.io", qos: .userInitiated)
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var cancelFlag = CancelFlag()
    @ObservationIgnored private var usbTimer: Timer?

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }

    init() {
        if DemoMode.isEnabled {
            DemoMode.populate(self)
            return
        }
        refreshUSB()
        startBrowsing()
        usbTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUSB() }
        }
        jobTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.section == .print else { return }
                await self.refreshJobs()
            }
        }
        Task { await refreshQueues() }
    }

    // MARK: Log

    nonisolated func makeLogSink() -> LogSink {
        { [weak self] entry in
            Task { @MainActor in self?.appendLog(entry) }
        }
    }

    func appendLog(_ entry: LogEntry) {
        log.append(entry)
        if log.count > 3000 { log.removeFirst(log.count - 3000) }
    }

    func info(_ text: String) { appendLog(LogEntry(.info, text)) }

    // MARK: Hledání tiskáren

    func refreshUSB() {
        let devices = USBPrinterTransport.enumerate()
        if devices != usbDevices { usbDevices = devices }
    }

    func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_pdl-datastream._tcp", domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let printers: [NetworkPrinter] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return NetworkPrinter(id: name, name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in
                self?.networkPrinters = printers.sorted {
                    ($0.name.localizedCaseInsensitiveContains("brother") ? 0 : 1, $0.name)
                        < ($1.name.localizedCaseInsensitiveContains("brother") ? 0 : 1, $1.name)
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    // MARK: Spuštění práce na pracovním vlákně

    private func run<T>(_ title: String, _ work: @escaping (BrotherPrinter, CancelFlag) throws -> T) async throws -> T {
        guard let printer else { throw TransportError.closed }
        activity = title
        lastError = nil
        let flag = CancelFlag()
        cancelFlag = flag
        defer { activity = nil }
        return try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do { continuation.resume(returning: try work(printer, flag)) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func cancelActivity() { cancelFlag.cancel() }

    private func report(_ error: Error) {
        if error is CancellationError { info(L("Cancelled.")); return }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = message
        appendLog(LogEntry(.error, message))
    }

    // MARK: Připojení

    func connect(usb device: USBPrinterDevice) async {
        await connect(label: device.name) { try USBPrinterTransport(device: device) }
    }

    func connect(network printer: NetworkPrinter) async {
        await connect(label: printer.name) { try TCPPrinterTransport(endpoint: printer.endpoint, name: printer.name) }
    }

    func connectManual() async {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        await connect(label: host) { try TCPPrinterTransport(host: host) }
    }

    private func connect(label: String, open: @escaping () throws -> PrinterTransport) async {
        disconnect()
        connection = .connecting(label)
        info(L("Connecting: %@", label))
        let sink = makeLogSink()
        do {
            let transport = try await withCheckedThrowingContinuation { (c: CheckedContinuation<PrinterTransport, Error>) in
                ioQueue.async { do { c.resume(returning: try open()) } catch { c.resume(throwing: error) } }
            }
            printer = BrotherPrinter(transport: transport, log: sink)
            connection = .connected(name: transport.displayName, kind: transport.kind, host: transport.remoteHost)
            info(L("Connected (%@).", L(transport.kind.rawValue)))
            section = .overview
            await refreshStatus()
        } catch {
            connection = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            report(error)
        }
    }

    func disconnect() {
        cancelFlag.cancel()
        if let printer {
            let transport = printer.transport
            ioQueue.async { transport.close() }
        }
        printer = nil
        connection = .disconnected
        status = nil
        currentNetwork = nil
        tonerPercent = nil
        scanResult = nil
        firmware = nil
        firmwareChecks = [:]
        applyState = .idle
    }

    var host: String? {
        if case let .connected(_, _, host) = connection { return host }
        return nil
    }

    var isUSB: Bool {
        if case let .connected(_, kind, _) = connection { return kind == .usb }
        return false
    }

    // MARK: Přehled

    func refreshStatus() async {
        do {
            status = try await run(L("Reading printer status…")) { p, _ in try p.readStatus() }
        } catch { report(error) }
        if let host { await readToner(host: host) }
    }

    private func readToner(host: String) async {
        let result = await Task.detached { () -> Int? in
            let level = try? SNMP.walk(host: host, root: "1.3.6.1.2.1.43.11.1.1.9.1", maxItems: 2).first?.1.intValue
            let max = try? SNMP.walk(host: host, root: "1.3.6.1.2.1.43.11.1.1.8.1", maxItems: 2).first?.1.intValue
            guard let level, let max, max > 0, level >= 0 else { return nil }
            return Int((Double(level) / Double(max) * 100).rounded())
        }.value
        tonerPercent = result
    }

    func setDisplay(_ text: String) async {
        do {
            try await run(L("Sending text to the display…")) { p, _ in try p.setReadyMessage(text) }
            info(text.isEmpty ? L("Display restored to the default text.") : L("Text sent to the display: %@", BrotherPrinter.displayText(text)))
        } catch { report(error) }
    }

    func readCurrentNetwork() async {
        do {
            currentNetwork = try await run(L("Reading network settings…")) { p, _ in try p.readCurrentNetwork() }
        } catch { report(error) }
    }

    // MARK: Wi‑Fi

    func scan() async {
        scanProgress = L("Starting…")
        defer { scanProgress = nil }
        do {
            scanResult = try await run(L("Scanning for Wi‑Fi networks…")) { [weak self] p, flag in
                try p.scanNetworks(progress: { text in
                    Task { @MainActor in self?.scanProgress = text }
                }, isCancelled: { flag.isCancelled })
            }
        } catch { report(error) }
    }

    func apply(_ config: WiFiConfig) async {
        applyState = .running(.sending)
        var cfg = config
        if cfg.macAddress == nil, let mac = scanResult?.device[BrNet.macAddress], !mac.isEmpty { cfg.macAddress = mac }
        let finalConfig = cfg
        do {
            let outcome = try await run(L("Configuring Wi‑Fi…")) { [weak self] p, flag in
                try p.applyWiFi(finalConfig, progress: { stage in
                    Task { @MainActor in self?.applyState = .running(stage) }
                }, isCancelled: { flag.isCancelled })
            }
            applyState = .done(outcome)
            switch outcome {
            case .connected(let ip): info((ip.map { L("The printer is connected to Wi‑Fi – IP %@.", $0) } ?? L("The printer is connected to Wi‑Fi.")))
            case .failed(let code, _): appendLog(LogEntry(.error, (code.map { L("Connection failed (code %d).", $0) } ?? L("Connection failed."))))
            }
        } catch is CancellationError {
            applyState = .idle
            info(L("Stopped waiting for the result. The printer may still be trying to connect."))
        } catch {
            applyState = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            report(error)
        }
    }

    // MARK: Firmware

    func readFirmware() async {
        var info: FirmwareInfo?
        if printer != nil {
            info = try? await run(L("Reading firmware version…")) { p, _ in try p.readFirmwareInfo() }
        }
        if (info == nil || info?.spec == nil), let host {
            let snmp = await Task.detached { () -> FirmwareInfo? in
                guard let rows = try? SNMP.walk(host: host, root: "1.3.6.1.4.1.2435.2.4.3.99.3.1.6.1.2") else { return nil }
                return FirmwareInfo(lines: rows.map { $0.1.description })
            }.value
            if let snmp, !snmp.parts.isEmpty || snmp.model != nil { info = snmp }
        }
        if let info {
            firmware = info
            self.info("Firmware: \(info.parts.map { "\($0.id) \($0.version)" }.joined(separator: ", "))")
        } else {
            lastError = L("The printer did not return firmware info. Try the console (@PJL INFO BRFIRMWARE) or a network connection.")
            appendLog(LogEntry(.error, lastError!))
        }
    }

    func checkFirmware() async {
        guard let firmware else { return }
        activity = L("Asking the Brother server…")
        defer { activity = nil }
        firmwareChecks = [:]
        for part in firmware.parts {
            do {
                firmwareChecks[part.id] = try await BrotherFirmwareService.check(info: firmware, partID: part.id)
            } catch {
                firmwareChecks[part.id] = .unknown((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func download(part: String, version: String, url: URL) async {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PrintBridge Firmware", isDirectory: true)
        downloadProgress = 0
        defer { downloadProgress = nil }
        do {
            let file = try await BrotherFirmwareService.download(
                url, model: firmware?.model ?? "Brother", part: part, version: version, to: dir,
                progress: { [weak self] value in Task { @MainActor in self?.downloadProgress = value } }
            )
            downloadedFiles[part] = file
            info(L("Firmware saved: %@", file.path))
        } catch { report(error) }
    }

    func upload(file: URL) async {
        guard let data = try? Data(contentsOf: file) else {
            lastError = L("The file could not be read.")
            return
        }
        uploadProgress = 0
        uploadMessage = nil
        defer { uploadProgress = nil }
        do {
            try await run(L("Uploading firmware – do not turn the printer off!")) { [weak self] p, _ in
                try p.session.sendRaw(data, progress: { value in
                    Task { @MainActor in self?.uploadProgress = value }
                }, isCancelled: { false }) // přenos firmwaru se nesmí přerušit
            }
            uploadMessage = L("Firmware sent. The printer is now writing it and will restart by itself (usually 3–10 minutes). Do not turn it off or disconnect it until then.")
            info(uploadMessage!)
        } catch { report(error) }
    }

    // MARK: Konzole

    func sendRaw(_ text: String) async {
        let commands = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.uppercased().hasPrefix("@PJL") ? $0 : "@PJL " + $0 }
        guard !commands.isEmpty else { return }
        do {
            _ = try await run(L("Sending…")) { p, _ in try p.session.query(commands, timeout: 12) }
        } catch { report(error) }
    }

    func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PrintBridge-log.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let text = log.map { entry in
            let arrow: String
            switch entry.direction {
            case .outbound: arrow = "→"
            case .inbound: arrow = "←"
            case .info: arrow = "•"
            case .error: arrow = "!"
            }
            return "\(formatter.string(from: entry.date)) \(arrow) \(entry.text)"
        }.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Tisk

    var printBridgeQueue: PrintQueue? { queues.first { $0.isPrintBridge } }
    var fragileBrotherQueues: [PrintQueue] { queues.filter { $0.isBrother && $0.usesFragileDiscovery } }

    func receivePrintFiles(_ urls: [URL]) {
        section = .print
        addPrintFiles(urls)
    }

    func addPrintFiles(_ urls: [URL]) {
        for url in urls where !printItems.contains(where: { $0.url == url }) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let item = PrintItem(url: url)
            printItems.append(item)
            Task {
                let image = await DocumentConverter.thumbnail(for: url)
                if let index = printItems.firstIndex(where: { $0.id == item.id }) { printItems[index].thumbnail = image }
            }
        }
        printMessage = nil
        printError = nil
    }

    func removePrintItem(_ item: PrintItem) { printItems.removeAll { $0.id == item.id } }

    func refreshQueues() async {
        if DemoMode.isEnabled { return } // ukázková data se nesmí přepsat skutečnými frontami
        let result = await Task.detached { PrintSystem.queues() }.value
        queues = result
        if selectedQueue == nil || !result.contains(where: { $0.name == selectedQueue }) {
            selectedQueue = result.first(where: \.isPrintBridge)?.name
                ?? result.first(where: { $0.isDefault && $0.isBrother })?.name
                ?? result.first(where: \.isBrother)?.name
                ?? result.first?.name
        }
        await refreshJobs()
    }

    func refreshJobs() async {
        if DemoMode.isEnabled { return }
        let list = await Task.detached { PrintSystem.jobs(queue: nil) }.value
        if list != jobs { jobs = list }
    }

    /// Vytvoří spolehlivou frontu. `preferUSB` = tisk přes kabel místo Wi‑Fi.
    func setupQueue(preferUSB: Bool, makeDefault: Bool) async {
        isSettingUpQueue = true
        printError = nil
        printMessage = nil
        defer { isSettingUpQueue = false }
        let hostHint = host
        do {
            let uri = try await Task.detached { () throws -> String in
                let found = PrintSystem.discoverPrinterURIs(preferHost: hostHint)
                let pick = preferUSB ? found.first { $0.hasPrefix("usb://") } : found.first { $0.hasPrefix("ipp") }
                guard let uri = pick ?? found.first else { throw PrintSystemError.noPrinterFound }
                try PrintSystem.createQueue(uri: uri, makeDefault: makeDefault)
                return uri
            }.value
            info(L("Created print queue %@ → %@", PrintSystem.queueName, uri))
            printMessage = L("The printer is ready in macOS as “%@”. File › Print works in every app too.", PrintSystem.queueDescription)
            await refreshQueues()
            selectedQueue = PrintSystem.queueName
        } catch {
            printError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            appendLog(LogEntry(.error, L("Creating the queue failed: %@", printError!)))
        }
    }

    func setDefaultQueue(_ name: String) async {
        do { try await Task.detached { try PrintSystem.setDefault(name) }.value } catch { printError = error.localizedDescription }
        await refreshQueues()
    }

    func removeQueue(_ name: String) async {
        do {
            try await Task.detached { try PrintSystem.removeQueue(name) }.value
            info(L("Removed queue %@", name))
        } catch { printError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        await refreshQueues()
    }

    func resumeQueue(_ name: String) async {
        do { try await Task.detached { try PrintSystem.resume(name) }.value } catch { printError = error.localizedDescription }
        await refreshQueues()
    }

    func printAll() async {
        guard let queue = selectedQueue, !printItems.isEmpty else { return }
        isPrinting = true
        printError = nil
        printMessage = nil
        defer { isPrinting = false }
        let options = printOptions
        var sent = 0
        var openedElsewhere: [String] = []
        for item in printItems {
            if item.kind == .unsupported {
                NSWorkspace.shared.open(item.url)
                openedElsewhere.append(item.name)
                continue
            }
            do {
                let file = try DocumentConverter.pdf(for: item)
                let jobID = try await Task.detached {
                    try PrintSystem.submit(file: file, title: item.name, queue: queue, options: options)
                }.value
                info(L("Sent to print: %@ (%@)", item.name, jobID))
                sent += 1
            } catch {
                printError = "\(item.name): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                appendLog(LogEntry(.error, printError!))
            }
        }
        var parts: [String] = []
        if sent > 0 { parts.append(L("Files sent to print: %d.", sent)) }
        if !openedElsewhere.isEmpty {
            parts.append(L("Opened in its own app (print with ⌘P): %@.", openedElsewhere.joined(separator: ", ")))
        }
        printMessage = parts.isEmpty ? nil : parts.joined(separator: " ")
        if printError == nil { printItems.removeAll() }
        await refreshJobs()
    }

    func cancelJob(_ id: String) async {
        do { try await Task.detached { try PrintSystem.cancel(job: id) }.value } catch { printError = error.localizedDescription }
        await refreshJobs()
    }

    func setLanguage(_ code: String?) {
        L10n.preference = code
        languagePreference = code
        // Systémové nabídky (Úpravy, Okno…) se řídí AppleLanguages – projeví se po restartu aplikace.
        if let code { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
        else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        languageRevision += 1
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
        } catch {
            printError = L("Could not set Open at Login: %@. The app must be in the Applications folder.", error.localizedDescription)
        }
        launchAtLogin = LoginItem.isEnabled
    }
}
