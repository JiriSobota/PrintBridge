import Foundation

public struct FirmwarePart: Identifiable, Hashable, Sendable {
    public var id: String
    public var version: String

    public init(id: String, version: String) {
        self.id = id
        self.version = version
    }
}

/// Údaje, které tiskárna Brother hlásí o firmwaru (`MODEL`, `SPEC`, `FIRMID`/`FIRMVER`…).
public struct FirmwareInfo: Sendable {
    public var model: String?
    public var serial: String?
    public var spec: String?
    public var parts: [FirmwarePart] = []

    public init(model: String? = nil, serial: String? = nil, spec: String? = nil, parts: [FirmwarePart] = []) {
        self.model = model
        self.serial = serial
        self.spec = spec
        self.parts = parts
    }

    /// Řádky ve tvaru `MODEL="HL-L2340D series"`, `FIRMID="MAIN"`, `FIRMVER="1.26"`…
    public init(lines: [String]) {
        var pendingID: String?
        for line in lines {
            for (rawKey, value) in PJL.keyValues(line) {
                switch rawKey.uppercased() {
                case "MODEL": model = value
                case "SERIAL": serial = value
                case "SPEC": spec = value
                case "FIRMID": pendingID = value
                case "FIRMVER":
                    parts.append(FirmwarePart(id: pendingID ?? "MAIN", version: value))
                    pendingID = nil
                default: break
                }
            }
        }
    }
}

public enum FirmwareCheck: Sendable {
    case upToDate
    case update(version: String, url: URL)
    case unknown(String)
}

public enum FirmwareError: LocalizedError {
    case missingInfo
    case badResponse(String)
    case untrustedURL(String)
    case notFirmware
    public var errorDescription: String? {
        switch self {
        case .missingInfo: return L("Model information (MODEL/SPEC) is missing. Read the firmware info from the printer first.")
        case .badResponse(let s): return L("Unexpected response from the Brother server: %@", s)
        case .untrustedURL(let s): return L("The server returned a link outside the Brother domain; download stopped: %@", s)
        case .notFirmware: return L("The file does not look like Brother firmware (no PJL header).")
        }
    }
}

/// Dotaz na oficiální aktualizační server Brother – stejný, jaký používá „Firmware Update Tool“.
/// Odesílá se jen model, SPEC, ID a verze firmwaru (žádné sériové číslo).
public enum BrotherFirmwareService {
    public static let endpoint = URL(string: "https://firmverup.brother.co.jp/kne_bh7_update_nt_ssl/ifax2.asmx/fileUpdate")!

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Tvar dotazu ověřený na HL‑L2340DW (stejný jako u nástroje oh-brother):
    /// `INSPECTMODE=0` (1 = zkušební kanál → odpověď 2), `DRIVER=EWS`, bez sériového čísla.
    /// Varianta 1 je starší tvar, který potřebují některé jiné modely.
    static func requestBody(info: FirmwareInfo, partID: String, os: String, variant: Int) -> String {
        let firms = info.parts.filter { $0.id == partID || info.parts.count == 1 }.map {
            "<FIRM><ID>\(xmlEscape($0.id))</ID><VERSION>\(xmlEscape($0.version))</VERSION></FIRM>"
        }.joined()
        let category = partID == "FIRM" ? "MAIN" : partID
        let model = "<NAME>\(xmlEscape(info.model ?? ""))</NAME><SPEC>\(xmlEscape(info.spec ?? ""))</SPEC>"
        if variant == 0 {
            return "<REQUESTINFO><FIRMUPDATETOOLINFO><FIRMCATEGORY>\(xmlEscape(category))</FIRMCATEGORY><OS>\(os)</OS>"
                + "<INSPECTMODE>0</INSPECTMODE></FIRMUPDATETOOLINFO><FIRMUPDATEINFO><MODELINFO>\(model)<DRIVER>EWS</DRIVER>"
                + "<FIRMINFO>\(firms)</FIRMINFO></MODELINFO><DRIVERCNT>1</DRIVERCNT><LOGNO>2</LOGNO>"
                + "<NEEDRESPONSE>1</NEEDRESPONSE></FIRMUPDATEINFO></REQUESTINFO>"
        }
        return "<REQUESTINFO><FIRMUPDATETOOLINFO><FIRMCATEGORY>\(xmlEscape(category))</FIRMCATEGORY><OS>\(os)</OS>"
            + "<INSPECTMODE>0</INSPECTMODE></FIRMUPDATETOOLINFO><FIRMUPDATEINFO><MODELINFO><SERIALNO></SERIALNO>\(model)"
            + "<DRIVER></DRIVER><FIRMINFO>\(firms)</FIRMINFO></MODELINFO><DRIVERCNT>1</DRIVERCNT><LOGNO>2</LOGNO>"
            + "<ERRBIT></ERRBIT><NEEDRESPONSE>1</NEEDRESPONSE></FIRMUPDATEINFO></REQUESTINFO>"
    }

    public static func requestBodyForTest(info: FirmwareInfo, partID: String) -> String {
        requestBody(info: info, partID: partID, os: "MAC", variant: 0)
    }

    static func tag(_ name: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(name)>"), let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func parse(_ xml: String) -> FirmwareCheck? {
        guard let check = tag("VERSIONCHECK", in: xml) else { return nil }
        switch check {
        case "1":
            return .upToDate
        case "0":
            guard let version = tag("LATESTVERSION", in: xml),
                  let path = tag("PATH", in: xml)?.replacingOccurrences(of: "&amp;", with: "&"),
                  let url = URL(string: path) else { return nil }
            return .update(version: version, url: url)
        default:
            return nil
        }
    }

    public static func check(info: FirmwareInfo, partID: String) async throws -> FirmwareCheck {
        guard info.model != nil, info.spec != nil else { throw FirmwareError.missingInfo }
        var lastRaw = ""
        for variant in 0...1 {
            var request = URLRequest(url: endpoint, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
            request.setValue("BrHttpc/1.00", forHTTPHeaderField: "User-Agent")
            request.httpBody = Data(requestBody(info: info, partID: partID, os: "MAC", variant: variant).utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw FirmwareError.badResponse("HTTP \(http.statusCode)")
            }
            lastRaw = String(decoding: data, as: UTF8.self)
            if let result = parse(lastRaw) { return result }
        }
        let code = tag("VERSIONCHECK", in: lastRaw) ?? "?"
        return .unknown(L("The server answered with code %@ – it does not know this model/SPEC combination (or has no update for it).", code))
    }

    public static func isTrusted(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return host == "brother.co.jp" || host.hasSuffix(".brother.co.jp") || host.hasSuffix(".brother.com")
            || host == "brother.com" || host.hasSuffix(".brother-usa.com")
    }

    /// Stáhne firmware do složky; vrátí cestu k souboru.
    public static func download(_ url: URL, model: String, part: String, version: String, to directory: URL,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard isTrusted(url) else { throw FirmwareError.untrustedURL(url.absoluteString) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = "\(model)-\(part)-\(version)".map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        let destination = directory.appendingPathComponent(String(safe)).appendingPathExtension("djf")

        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let total = max(1, response.expectedContentLength)
        var data = Data()
        data.reserveCapacity(Int(max(0, response.expectedContentLength)))
        var lastReport = 0
        for try await byte in bytes {
            data.append(byte)
            if data.count - lastReport > 64 * 1024 {
                lastReport = data.count
                progress(min(1, Double(data.count) / Double(total)))
            }
        }
        progress(1)
        guard !data.isEmpty else { throw FirmwareError.badResponse(L("empty file")) }
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Firmware Brother (.djf) je PJL úloha – začíná UEL nebo `@PJL`.
    public static func looksLikeFirmware(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(64), as: UTF8.self)
        return head.hasPrefix(PJL.uel) || head.hasPrefix("@PJL") || head.contains("@PJL")
    }
}
