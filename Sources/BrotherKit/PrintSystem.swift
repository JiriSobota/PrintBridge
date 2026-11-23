import Foundation

/// Tisková fronta macOS (CUPS).
public struct PrintQueue: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let uri: String
    public var isDefault: Bool
    public var state: String
    public var message: String?

    public init(name: String, uri: String, isDefault: Bool, state: String, message: String? = nil) {
        self.name = name; self.uri = uri; self.isDefault = isDefault; self.state = state; self.message = message
    }

    public var isPrintBridge: Bool { name == PrintSystem.queueName }
    public var isBrother: Bool { uri.localizedCaseInsensitiveContains("brother") || uri.contains("BRW") || name.localizedCaseInsensitiveContains("brother") }
    /// Fronty s `dnssd://` hledají tiskárnu přes Bonjour při každém tisku – u uspané tiskárny to selhává.
    public var usesFragileDiscovery: Bool { uri.hasPrefix("dnssd://") }
    public var connection: String {
        if uri.hasPrefix("usb://") { return "USB" }
        if uri.hasPrefix("dnssd://") { return L("Bonjour (by service name)") }
        if uri.hasPrefix("ipp://") || uri.hasPrefix("ipps://") { return "IPP · \(URL(string: uri)?.host ?? uri)" }
        if uri.hasPrefix("socket://") { return "RAW · \(URL(string: uri)?.host ?? uri)" }
        return uri
    }
}

public struct PrintJob: Identifiable, Hashable, Sendable {
    public let id: String
    public let user: String
    public let size: String
    public let date: String
    public var status: String?

    public init(id: String, user: String, size: String, date: String, status: String? = nil) {
        self.id = id; self.user = user; self.size = size; self.date = date; self.status = status
    }
}

public struct PrintOptions: Sendable {
    public enum Sides: String, CaseIterable, Identifiable, Sendable {
        case oneSided = "one-sided"
        case longEdge = "two-sided-long-edge"
        case shortEdge = "two-sided-short-edge"
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .oneSided: return L("One-sided")
            case .longEdge: return L("Two-sided (long edge)")
            case .shortEdge: return L("Two-sided (short edge)")
            }
        }
    }

    public enum Quality: String, CaseIterable, Identifiable, Sendable {
        case draft = "3", normal = "4", high = "5"
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .draft: return L("Draft")
            case .normal: return L("Normal")
            case .high: return L("High")
            }
        }
    }

    public var copies = 1
    public var sides: Sides = .oneSided
    public var pageRange = ""
    public var quality: Quality = .normal
    public var fitToPage = true

    public init() {}

    public var validationError: String? {
        let r = pageRange.trimmingCharacters(in: .whitespaces)
        guard !r.isEmpty else { return nil }
        let ok = r.range(of: #"^\d+(-\d+)?(,\s*\d+(-\d+)?)*$"#, options: .regularExpression) != nil
        return ok ? nil : L("Enter a page range such as 1-3,5")
    }
}

public enum PrintSystemError: LocalizedError {
    case command(String)
    case noPrinterFound
    public var errorDescription: String? {
        switch self {
        case .command(let s): return s
        case .noPrinterFound: return L("The printer was not found on the network or USB. Make sure it is turned on.")
        }
    }
}

/// Práce s tiskovým systémem macOS přes standardní nástroje CUPS (`lp`, `lpstat`, `lpadmin`, `ippfind`).
/// Všechny funkce blokují – volejte je mimo hlavní vlákno.
public enum PrintSystem {
    public static let queueName = "PrintBridge_HL_L2340DW"
    public static let queueDescription = "Brother HL-L2340DW (PrintBridge)"

    @discardableResult
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 60) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "C"
        env["LC_ALL"] = "C"
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        let handle = out.fileHandleForReading
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate() }
        data.append(handle.readDataToEndOfFile())
        let text = String(decoding: data, as: UTF8.self)
        if process.terminationStatus != 0 {
            throw PrintSystemError.command(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? L("%@ failed with code %d", (tool as NSString).lastPathComponent, Int(process.terminationStatus))
                : text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }

    // MARK: Fronty

    public static func queues() -> [PrintQueue] {
        let devices = (try? run("/usr/bin/lpstat", ["-v"])) ?? ""
        let states = (try? run("/usr/bin/lpstat", ["-l", "-p"])) ?? ""
        let def = (try? run("/usr/bin/lpstat", ["-d"])) ?? ""
        let defaultName = def.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespacesAndNewlines)

        var stateByName: [String: (String, String?)] = [:]
        var current: String?
        var expectMessage = false
        for line in states.components(separatedBy: "\n") {
            if line.hasPrefix("printer ") {
                let parts = line.split(separator: " ")
                guard parts.count >= 4 else { continue }
                let name = String(parts[1])
                current = name
                expectMessage = true
                let state = parts[3].trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
                stateByName[name] = (state, nil)
            } else if let c = current, expectMessage, line.hasPrefix("\t") {
                expectMessage = false
                // První odsazený řádek bez dvojtečky je stavová zpráva (např. „The printer is not responding.“).
                let msg = line.trimmingCharacters(in: .whitespaces)
                if !msg.isEmpty, !msg.contains(":") { stateByName[c]?.1 = msg }
            }
        }

        return devices.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix("device for "), let colon = line.range(of: ": ") else { return nil }
            let name = String(line[line.index(line.startIndex, offsetBy: 11)..<colon.lowerBound])
            let uri = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            let st = stateByName[name]
            return PrintQueue(name: name, uri: uri, isDefault: name == defaultName,
                              state: translate(st?.0 ?? "unknown"), message: st?.1)
        }
    }

    static func translate(_ state: String) -> String {
        switch state {
        case "idle": return L("Ready")
        case "now": return L("Printing")
        case "disabled": return L("Paused")
        default: return state
        }
    }

    /// Najde adresu tiskárny: síťové IPP (podle stálého jména BRW…local), případně USB.
    public static func discoverPrinterURIs(preferHost: String? = nil) -> [String] {
        var result: [String] = []
        let found = (try? run("/usr/bin/ippfind", ["-T", "5", "_ipp._tcp"], timeout: 10)) ?? ""
        for line in found.components(separatedBy: "\n") {
            let uri = line.trimmingCharacters(in: .whitespaces)
            guard uri.hasPrefix("ipp"), !uri.contains("/printers/"), !uri.contains("/classes/") else { continue }
            // Sdílené fronty jiných Maců mají cestu /printers/…; tiskárna sama /ipp/print.
            result.append(uri)
        }
        if let host = preferHost, !result.contains(where: { $0.contains(host) }) {
            result.append("ipp://\(host)/ipp/print")
        }
        // USB (lpinfo ukáže i tiskárnu připojenou kabelem)
        let usb = (try? run("/usr/sbin/lpinfo", ["--include-schemes", "usb", "-v"], timeout: 20)) ?? ""
        for line in usb.components(separatedBy: "\n") where line.contains("usb://") {
            if let uri = line.split(separator: " ").last.map(String.init), uri.localizedCaseInsensitiveContains("brother") {
                result.append(uri)
            }
        }
        return result
    }

    /// Vytvoří (nebo přepíše) spolehlivou frontu:
    /// stálá adresa místo Bonjour hledání, AirPrint ovladač, při nedostupnosti se úloha opakuje místo zahození.
    public static func createQueue(uri: String, makeDefault: Bool) throws {
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                try run("/usr/sbin/lpadmin", [
                    "-p", queueName, "-D", queueDescription, "-L", uri.hasPrefix("usb") ? "USB" : "Wi‑Fi",
                    "-v", uri, "-m", "everywhere",
                    "-o", "printer-error-policy=retry-job",
                    "-o", "printer-is-shared=false",
                    "-o", "PageSize=A4",
                    "-E",
                ], timeout: 90)
                lastError = nil
                break
            } catch {
                lastError = error
                if attempt == 0 { Thread.sleep(forTimeInterval: 3) } // tiskárna se mohla teprve probouzet
            }
        }
        if let lastError { throw lastError }
        if makeDefault { try setDefault(queueName) }
    }

    /// Nastaví výchozí tiskárnu systémově i pro uživatele (`~/.cups/lpoptions` má v macOS přednost).
    public static func setDefault(_ name: String) throws {
        try? run("/usr/sbin/lpadmin", ["-d", name])
        try run("/usr/bin/lpoptions", ["-d", name])
    }

    public static func removeQueue(_ name: String) throws {
        try run("/usr/sbin/lpadmin", ["-x", name])
    }

    public static func resume(_ name: String) throws {
        try run("/usr/sbin/cupsenable", [name])
        try run("/usr/sbin/cupsaccept", [name])
    }

    // MARK: Úlohy

    /// Odešle soubor do fronty. Vrátí ID úlohy (např. "PrintBridge_HL_L2340DW-12").
    public static func submit(file: URL, title: String, queue: String, options: PrintOptions) throws -> String {
        var args = ["-d", queue, "-t", title, "-n", "\(max(1, options.copies))",
                    "-o", "sides=\(options.sides.rawValue)",
                    "-o", "print-quality=\(options.quality.rawValue)"]
        let range = options.pageRange.replacingOccurrences(of: " ", with: "")
        if !range.isEmpty { args += ["-P", range] }
        if options.fitToPage { args += ["-o", "fit-to-page"] }
        args.append(file.path)
        let out = try run("/usr/bin/lp", args, timeout: 120)
        // "request id is Queue-12 (1 file(s))"
        if let r = out.range(of: "request id is ") {
            return out[r.upperBound...].split(separator: " ").first.map(String.init) ?? out
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func jobs(queue: String?) -> [PrintJob] {
        var args = ["-W", "not-completed", "-l", "-o"]
        if let queue { args.append(queue) }
        let out = (try? run("/usr/bin/lpstat", args)) ?? ""
        var jobs: [PrintJob] = []
        for line in out.components(separatedBy: "\n") {
            if !line.hasPrefix("\t") && !line.hasPrefix(" ") && !line.isEmpty {
                let p = line.split(separator: " ", omittingEmptySubsequences: true)
                guard p.count >= 4 else { continue }
                jobs.append(PrintJob(id: String(p[0]), user: String(p[1]), size: String(p[2]),
                                     date: p[3...].joined(separator: " "), status: nil))
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("Status:"), !jobs.isEmpty {
                let s = line.trimmingCharacters(in: .whitespaces).dropFirst(7).trimmingCharacters(in: .whitespaces)
                jobs[jobs.count - 1].status = s.isEmpty ? nil : s
            }
        }
        return jobs
    }

    public static func cancel(job: String) throws {
        try run("/usr/bin/cancel", [job])
    }

    /// Formáty, které tiskový systém macOS vytiskne přímo (bez převodu).
    public static let directTypes: Set<String> = ["pdf", "jpg", "jpeg", "png", "tif", "tiff", "gif", "heic", "bmp", "txt", "text", "ps"]
}
