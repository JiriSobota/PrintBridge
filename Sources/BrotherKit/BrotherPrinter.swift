import Foundation

public struct PrinterStatus: Sendable {
    public init(model: String? = nil, statusCode: Int? = nil, display: String? = nil, online: Bool? = nil,
                pageCount: Int? = nil, deviceID: String? = nil, firmwareVersion: String? = nil) {
        self.model = model; self.statusCode = statusCode; self.display = display; self.online = online
        self.pageCount = pageCount; self.deviceID = deviceID; self.firmwareVersion = firmwareVersion
    }

    public var model: String?
    public var statusCode: Int?
    public var display: String?
    public var online: Bool?
    public var pageCount: Int?
    public var deviceID: String?
    /// Verze firmwaru z `@PJL INFO ID` (např. "1.30").
    public var firmwareVersion: String?

    /// Rozdělí `"Brother HL-L2340D series:84U-F56:Ver.1.30"` na model a verzi.
    public static func splitID(_ id: String) -> (model: String, version: String?) {
        let parts = id.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        let version = parts.first { $0.lowercased().hasPrefix("ver.") }.map { String($0.dropFirst(4)) }
        return (parts.first ?? id, version)
    }

    public var statusTitle: String {
        guard let code = statusCode else { return display ?? L("Unknown status") }
        switch code {
        case 10001, 10002: return L("Ready")
        case 10003: return L("Warming up")
        case 10006: return L("Toner low")
        case 10023, 10024: return L("Printing")
        case 10005, 35078, 40000: return L("Sleep mode")
        case 30016, 30119: return L("Toner low")
        case 40010, 40019, 40038: return L("Replace toner")
        case 40021: return L("Cover open")
        case 41000...41999: return L("Out of paper")
        case 42000...42999: return L("Paper jam")
        default: return display.map { "\($0) (\(code))" } ?? L("Code %d", code)
        }
    }

    public var isError: Bool {
        guard let code = statusCode else { return false }
        return code >= 40000 && code != 40000
    }
}

public struct CurrentNetwork: Sendable {
    public init(ssid: String? = nil, ipAddress: String? = nil, subnetMask: String? = nil, gateway: String? = nil,
                macAddress: String? = nil, bootMethod: String? = nil, wirelessEnabled: Bool? = nil) {
        self.ssid = ssid; self.ipAddress = ipAddress; self.subnetMask = subnetMask; self.gateway = gateway
        self.macAddress = macAddress; self.bootMethod = bootMethod; self.wirelessEnabled = wirelessEnabled
    }

    public var ssid: String?
    public var ipAddress: String?
    public var subnetMask: String?
    public var gateway: String?
    public var macAddress: String?
    public var bootMethod: String?
    public var wirelessEnabled: Bool?
}

public enum WiFiApplyStage: Sendable, Equatable {
    case sending
    case waiting(attempt: Int, of: Int, secondsLeft: Int)
    case retryingWithTKIP
    case readingResult
}

public enum WiFiApplyOutcome: Sendable {
    case connected(ip: String?)
    case failed(code: Int?, status: String?)
}

public enum BrotherError: LocalizedError {
    case noResponse(String)
    case scanFailed
    public var errorDescription: String? {
        switch self {
        case .noResponse(let what): return L("The printer did not answer the query: %@.", what)
        case .scanFailed: return L("The printer could not scan for networks. Make sure Wi‑Fi is enabled on the printer.")
        }
    }
}

/// Vysokoúrovňové operace nad tiskárnou Brother (bezdrátové nastavení, stav, firmware).
/// Všechny metody blokují – volejte je z pracovního vlákna.
public final class BrotherPrinter: @unchecked Sendable {
    public let session: PJLSession
    private let log: LogSink

    public init(transport: PrinterTransport, log: @escaping LogSink) {
        self.session = PJLSession(transport: transport, log: log)
        self.log = log
    }

    public var transport: PrinterTransport { session.transport }

    private func sleep(_ seconds: Int, isCancelled: () -> Bool, tick: (Int) -> Void) throws {
        for left in stride(from: seconds, to: 0, by: -1) {
            if isCancelled() { throw CancellationError() }
            tick(left)
            Thread.sleep(forTimeInterval: 1)
        }
    }

    // MARK: Stav

    public func readStatus() throws -> PrinterStatus {
        var status = PrinterStatus()
        if let usb = transport as? USBPrinterTransport, let id = usb.ieee1284DeviceID() {
            status.deviceID = id
            for part in id.split(separator: ";") {
                let kv = part.split(separator: ":", maxSplits: 1).map(String.init)
                if kv.count == 2, ["MDL", "MODEL"].contains(kv[0].uppercased()) { status.model = kv[1] }
            }
        }
        let response = try session.query(["@PJL INFO ID", "@PJL INFO STATUS", "@PJL INFO PAGECOUNT"], timeout: 8)
        if response.isEmpty { throw BrotherError.noResponse("@PJL INFO") }

        if let id = PJL.section(of: response, for: "@PJL INFO ID") {
            let line = id.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if let line {
                let parsed = PrinterStatus.splitID(line.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t\r")))
                status.model = parsed.model
                status.firmwareVersion = parsed.version
            }
        }
        if let st = PJL.section(of: response, for: "@PJL INFO STATUS") {
            for (k, v) in PJL.keyValues(st) {
                switch k.uppercased() {
                case "CODE": status.statusCode = Int(v)
                case "DISPLAY": status.display = v
                case "ONLINE": status.online = v.uppercased() == "TRUE"
                default: break
                }
            }
        }
        if let pc = PJL.section(of: response, for: "@PJL INFO PAGECOUNT") {
            let digits = pc.components(separatedBy: CharacterSet.decimalDigits.inverted).first { !$0.isEmpty }
            status.pageCount = digits.flatMap(Int.init)
        }
        return status
    }

    // MARK: Displej

    /// Text pro jednořádkový displej (16 znaků, jen ASCII – diakritiku displej neumí).
    public static func displayText(_ text: String) -> String {
        let ascii = text.applyingTransform(.stripDiacritics, reverse: false) ?? text
        let cleaned = ascii.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F && $0 != "\"" }
        return String(String.UnicodeScalarView(cleaned).prefix(16))
    }

    /// Nastaví vlastní text místo „Ready“ (`@PJL RDYMSG`). Prázdný text vrátí výchozí zobrazení.
    public func setReadyMessage(_ text: String) throws {
        try session.send(["@PJL RDYMSG DISPLAY = \"\(BrotherPrinter.displayText(text))\""])
    }

    // MARK: OBJBRNET

    public func inquire(_ id: String, timeout: TimeInterval = 8) throws -> String? {
        let response = try session.query(BrWiFiCommands.inquire(id), timeout: timeout)
        return BrWiFiCommands.parseInquire(response, id: id)
    }

    public func readCurrentNetwork() throws -> CurrentNetwork {
        var net = CurrentNetwork()
        net.ssid = try inquire(BrNet.ssid).map { BrCodec.decode($0) }
        net.ipAddress = try inquire(BrNet.ipAddress).map { BrCodec.decode($0, as: .ipv4) }
        net.subnetMask = try inquire(BrNet.subnetMask).map { BrCodec.decode($0, as: .ipv4) }
        net.gateway = try inquire(BrNet.gateway).map { BrCodec.decode($0, as: .ipv4) }
        net.macAddress = try inquire(BrNet.macAddress).map { BrCodec.decode($0, as: .mac) }
        net.bootMethod = try inquire(BrNet.bootMethod).map { $0 == "7" ? L("Static") : ($0 == "0" ? L("Automatic (DHCP)") : $0) }
        net.wirelessEnabled = try inquire(BrNet.wirelessEnable).map { $0 == "1" }
        return net
    }

    // MARK: Skenování sítí

    public func scanNetworks(progress: (String) -> Void, isCancelled: () -> Bool) throws -> WiFiScanResult {
        progress(L("Starting network scan…"))
        try session.send(["@PJL DEFAULT OBJBRNET=\"\(BrNet.startScan):31-3a\""])

        // Originál čekal 20 s a pak se ptal až 5×. Ptáme se dřív a častěji, ať je výsledek rychle.
        try sleep(6, isCancelled: isCancelled) { progress(L("The printer is scanning… %d s", $0)) }
        for attempt in 1...12 {
            if isCancelled() { throw CancellationError() }
            progress(L("Reading results (attempt %d)…", attempt))
            let response = try session.query(["@PJL INFO AVAILABLEWLAN"], timeout: 15, idle: 2.5)
            let section = PJL.section(of: response, for: "@PJL INFO AVAILABLEWLAN") ?? response
            let (status, result) = BrScanParser.parse(section)
            if status == -2 { throw BrotherError.scanFailed }
            if let status, status > 0, !result.networks.isEmpty || result.lines.count > 1 {
                log(LogEntry(.info, L("Networks found: %d", result.networks.count)))
                return result
            }
            try sleep(4, isCancelled: isCancelled) { progress(L("Still scanning… %d s", $0)) }
        }
        throw BrotherError.scanFailed
    }

    // MARK: Nastavení Wi‑Fi

    /// Odešle nastavení a čeká na výsledek stejně jako originál (15 s × max. 12 pokusů),
    /// navíc s automatickým druhým pokusem s TKIP pro smíšené sítě a čitelnou chybou.
    public func applyWiFi(_ config: WiFiConfig,
                          progress: (WiFiApplyStage) -> Void,
                          isCancelled: () -> Bool) throws -> WiFiApplyOutcome {
        let encryptions: [Int?] = config.security == .wpaPersonalMixed ? [4, 3] : [nil]
        var lastStatus: String?

        for (round, enc) in encryptions.enumerated() {
            if round > 0 { progress(.retryingWithTKIP) }
            progress(.sending)
            session.drain(timeout: 0.2)
            let pairs = BrWiFiCommands.pairs(for: config, encryptionOverride: enc)
            try session.send(BrWiFiCommands.commands(pairs), logAs: BrWiFiCommands.redacted(pairs))

            let attempts = 12
            for attempt in 1...attempts {
                try sleep(15, isCancelled: isCancelled) {
                    progress(.waiting(attempt: attempt, of: attempts, secondsLeft: $0))
                }
                progress(.readingResult)
                // Během připojování tiskárna občas neodpovídá – chyby čtení přeskakujeme.
                guard let value = try? inquire(BrNet.setupStatus, timeout: 10) else { continue }
                lastStatus = value
                let code = Int(String(value.suffix(1))) ?? -1
                if code == 1 {
                    let ip = (try? inquire(BrNet.ipAddress)).flatMap { $0 }.map { BrCodec.decode($0, as: .ipv4) }
                    return .connected(ip: ip)
                }
                if code != 0 { break } // jiný kód = definitivní chyba
            }
        }

        progress(.readingResult)
        let report = (try? inquire(BrNet.reportCode)).flatMap { $0 }.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return .failed(code: report, status: lastStatus)
    }

    // MARK: Firmware

    /// Informace o firmwaru přes PJL (Brother odpovídá na `@PJL INFO BRFIRMWARE` – stejné údaje jako v SNMP).
    public func readFirmwareInfo() throws -> FirmwareInfo? {
        let response = try session.query(["@PJL INFO BRFIRMWARE"], timeout: 8)
        let section = PJL.section(of: response, for: "@PJL INFO BRFIRMWARE") ?? response
        var info = FirmwareInfo(lines: section.components(separatedBy: .newlines))
        if info.parts.isEmpty {
            // Starší firmwary BRFIRMWARE neznají – verzi vezmeme z INFO ID.
            let idResponse = try session.query(["@PJL INFO ID"], timeout: 8)
            if let line = PJL.section(of: idResponse, for: "@PJL INFO ID")?
                .components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                let parsed = PrinterStatus.splitID(line.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t\r")))
                info.model = info.model ?? parsed.model.replacingOccurrences(of: "Brother ", with: "")
                if let v = parsed.version { info.parts = [FirmwarePart(id: "MAIN", version: v)] }
            }
        }
        return info.parts.isEmpty && info.model == nil ? nil : info
    }
}
