import Foundation

/// Identifikátory objektů `OBJBRNET`, které používá originální Brother „USB Wireless Setup Wizard“.
/// Zjištěno rozborem binárky `USBWirelessSetupWizard` (Brother, verze 1.0.2).
public enum BrNet {
    // Řízení nastavení
    public static let setupStatus = "458867"      // 0 = reset, po aplikaci 1 = úspěch, 0 = probíhá
    public static let apply = "458865"            // 5 = jednoduchý režim (tiskárna sama zvolí zabezpečení), 1 = ruční
    public static let startScan = "458845"        // hodnota "31-3a" spustí vyhledání sítí
    public static let wirelessEnable = "459138.2"
    public static let wiredEnable = "459138.1"
    public static let reportCode = "459619"       // kód chyby z WLAN reportu (TS-xx)

    // Parametry sítě
    public static let wlanMode = "458876"
    public static let ssid = "458877"
    public static let commMode = "458878"         // 1 = infrastruktura (router), 2 = ad-hoc
    public static let channel = "458879"
    public static let encryption = "458880"       // 1 žádné, 2 WEP, 3 TKIP, 4 AES
    public static let authentication = "458881"   // 1 otevřené, 2 sdílený klíč, 3 WPA/WPA2-PSK
    public static let wepKeyIndex = "458885"
    public static let wepKeySize = "458887.1"     // 1 = 64 bit, 2 = 128 bit
    public static let wepKeyType = "458888.1"     // 1 = hex, 2 = ASCII
    public static let wepKey = "458889.1"
    public static let wpaPSK = "458890"
    public static let simpleKey = "459288"        // heslo v jednoduchém režimu

    // TCP/IP bezdrátového rozhraní (.2)
    public static let bootMethod = "458970.2"     // 0 = automaticky (DHCP), 7 = statická
    public static let ipAddress = "458967.2"
    public static let subnetMask = "458968.2"
    public static let gateway = "458969.2"
    public static let macAddress = "458971.2"

    // Položky výsledku skenování
    public static let scanSSID = "458848.*"
    public static let scanWlanMode = "458849.*"
    public static let scanCommMode = "458850.*"
    public static let scanChannel = "458851.*"
    public static let scanSignal = "458852.*"
    public static let scanSecurity = "458853.*"   // 1 bez zabezpečení, 2 WEP, 3 Personal, 4 Enterprise
    public static let scanEncryption = "458854.*"
}

// MARK: - Kódování hodnot

/// Kódování textu pro OBJBRNET (odpovídá `UWSWTranslate` v originálu):
/// UTF-8 bajty → hex → oddělené pomlčkami ("Wifi" → "57-69-66-69"); jediný bajt dostane prefix "0x".
public enum BrCodec {
    public static func hex(_ text: String) -> String {
        text.utf8.map { String(format: "%02x", $0) }.joined()
    }

    public static func divided(_ hex: String) -> String {
        var parts: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            parts.append(String(hex[index..<next]))
            index = next
        }
        let joined = parts.joined(separator: "-")
        return hex.count == 2 ? "0x" + joined : joined
    }

    public static func encode(_ text: String) -> String { divided(hex(text)) }

    /// Dlouhé hodnoty (> 32 bajtů) originál dělí na dva objekty `<id>.0` a `<id>.1`.
    public static func pairsForLong(id: String, text: String) -> [(String, String)] {
        let h = hex(text)
        if h.count >= 65 {
            let cut = h.index(h.startIndex, offsetBy: 64)
            return [("\(id).0", divided(String(h[..<cut])) + "="),
                    ("\(id).1", "=-" + divided(String(h[cut...])))]
        }
        return [(id, divided(h))]
    }

    public static func encodeIPv4(_ ip: String) -> String? {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        return parts.map { String(format: "%02X", $0) }.joined(separator: "-")
    }

    public enum ValueKind { case text, ipv4, mac }

    /// Bajty z hodnoty "57-69-66-69" nebo "0x57"; nil, pokud hodnota není v tomto tvaru.
    public static func bytes(of value: String) -> [UInt8]? {
        var v = value.trimmingCharacters(in: .whitespaces)
        let hadPrefix = v.lowercased().hasPrefix("0x")
        if hadPrefix { v = String(v.dropFirst(2)) }
        guard hadPrefix || v.contains("-") else { return nil }
        let parts = v.split(separator: "-", omittingEmptySubsequences: false)
        let raw = parts.compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
        return raw.count == parts.count && !raw.isEmpty ? raw : nil
    }

    /// Dekóduje hodnotu vrácenou tiskárnou: "57-69-66-69" → "Wifi", "C0-A8-01-0A" → "192.168.1.10".
    public static func decode(_ value: String, as kind: ValueKind = .text) -> String {
        guard let raw = bytes(of: value) else { return value }
        switch kind {
        case .ipv4 where raw.count == 4:
            return raw.map(String.init).joined(separator: ".")
        case .mac where raw.count == 6:
            return raw.map { String(format: "%02X", $0) }.joined(separator: ":")
        default:
            return String(decoding: raw, as: UTF8.self)
        }
    }
}

// MARK: - Konfigurace Wi‑Fi

public enum WiFiSecurity: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case wpaPersonalAES
    case wpaPersonalMixed
    case wpaPersonalTKIP
    case wep
    case open

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: return L("Automatic (recommended)")
        case .wpaPersonalAES: return "WPA2‑Personal (AES)"
        case .wpaPersonalMixed: return "WPA/WPA2‑Personal (TKIP+AES)"
        case .wpaPersonalTKIP: return "WPA‑Personal (TKIP)"
        case .wep: return L("WEP (obsolete)")
        case .open: return L("No password")
        }
    }

    public var needsKey: Bool { self != .open }
}

public struct StaticIPConfig: Equatable, Sendable {
    public var address: String
    public var mask: String
    public var gateway: String

    public init(address: String = "", mask: String = "255.255.255.0", gateway: String = "") {
        self.address = address
        self.mask = mask
        self.gateway = gateway
    }
}

public struct WiFiConfig: Sendable {
    public var ssid: String
    public var key: String
    public var security: WiFiSecurity
    public var wlanMode: Int
    public var commMode: Int
    public var channel: Int
    public var staticIP: StaticIPConfig?
    public var macAddress: String?

    public init(ssid: String, key: String, security: WiFiSecurity = .automatic,
                wlanMode: Int = 5, commMode: Int = 1, channel: Int = 0,
                staticIP: StaticIPConfig? = nil, macAddress: String? = nil) {
        self.ssid = ssid
        self.key = key
        self.security = security
        self.wlanMode = wlanMode
        self.commMode = commMode
        self.channel = channel
        self.staticIP = staticIP
        self.macAddress = macAddress
    }

    /// Kontrola před odesláním – originál tohle dělal jen částečně a chyby se dozvěděl až po 3 minutách.
    public func validate() -> [String] {
        var problems: [String] = []
        let ssidBytes = ssid.utf8.count
        if ssidBytes == 0 { problems.append(L("Enter the network name (SSID).")) }
        if ssidBytes > 32 { problems.append(L("The network name can be at most 32 bytes (now %d).", ssidBytes)) }

        switch security {
        case .automatic, .wpaPersonalAES, .wpaPersonalMixed, .wpaPersonalTKIP:
            let isHex64 = key.count == 64 && key.allSatisfy(\.isHexDigit)
            let ascii = key.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E }
            if security == .automatic && key.isEmpty {
                problems.append(L("Enter the Wi‑Fi password (for an open network choose “No password”)."))
            } else if !isHex64 && (key.count < 8 || key.count > 63) {
                problems.append(L("A WPA password must be 8–63 characters (or exactly 64 hex digits)."))
            } else if !ascii && !isHex64 {
                problems.append(L("The password contains non-ASCII characters (accents, emoji). The printer will probably reject them."))
            }
        case .wep:
            if ![5, 10, 13, 26].contains(key.count) {
                problems.append(L("A WEP key must be 5 or 13 characters, or 10 or 26 hex digits."))
            }
        case .open:
            break
        }

        if commMode == 2 && !(1...13).contains(channel) {
            problems.append(L("Choose channel 1–13 for an ad-hoc network."))
        }
        if let ip = staticIP {
            if BrCodec.encodeIPv4(ip.address) == nil { problems.append(L("Invalid IP address.")) }
            if BrCodec.encodeIPv4(ip.mask) == nil { problems.append(L("Invalid subnet mask.")) }
            if BrCodec.encodeIPv4(ip.gateway) == nil { problems.append(L("Invalid gateway.")) }
        }
        return problems
    }
}

public enum BrWiFiCommands {
    /// Seznam dvojic (objekt, hodnota) ve stejném pořadí jako `settingInfoToArray:` originálu.
    public static func pairs(for config: WiFiConfig, encryptionOverride: Int? = nil) -> [(String, String)] {
        var p: [(String, String)] = [
            (BrNet.setupStatus, "0"),
            (BrNet.wirelessEnable, "1"),
            (BrNet.wiredEnable, "0"),
            (BrNet.wlanMode, "\(config.wlanMode)"),
            (BrNet.ssid, BrCodec.encode(config.ssid)),
            (BrNet.commMode, "\(config.commMode)"),
        ]
        if config.commMode == 2 { p.append((BrNet.channel, "\(config.channel)")) }

        switch config.security {
        case .automatic:
            if !config.key.isEmpty { p += BrCodec.pairsForLong(id: BrNet.simpleKey, text: config.key) }
        case .open:
            p.append((BrNet.authentication, "1"))
            p.append((BrNet.encryption, "1"))
        case .wep:
            let isHex = [10, 26].contains(config.key.count) && config.key.allSatisfy(\.isHexDigit)
            let size = [13, 26].contains(config.key.count) ? 2 : 1
            p.append((BrNet.authentication, "1"))
            p.append((BrNet.encryption, "2"))
            p.append((BrNet.wepKeyIndex, "1"))
            p.append((BrNet.wepKeySize, "\(size)"))
            p.append((BrNet.wepKeyType, isHex ? "1" : "2"))
            p.append((BrNet.wepKey, isHex ? BrCodec.divided(config.key.lowercased()) : BrCodec.encode(config.key)))
        case .wpaPersonalAES, .wpaPersonalMixed, .wpaPersonalTKIP:
            let enc = encryptionOverride ?? (config.security == .wpaPersonalTKIP ? 3 : 4)
            p.append((BrNet.authentication, "3"))
            p.append((BrNet.encryption, "\(enc)"))
            p += BrCodec.pairsForLong(id: BrNet.wpaPSK, text: config.key)
        }

        if let ip = config.staticIP,
           let a = BrCodec.encodeIPv4(ip.address), let m = BrCodec.encodeIPv4(ip.mask), let g = BrCodec.encodeIPv4(ip.gateway) {
            p.append((BrNet.bootMethod, "7"))
            p.append((BrNet.ipAddress, a))
            p.append((BrNet.subnetMask, m))
            p.append((BrNet.gateway, g))
        } else {
            p.append((BrNet.bootMethod, "0"))
        }
        if let mac = config.macAddress, !mac.isEmpty { p.append((BrNet.macAddress, mac)) }
        p.append((BrNet.apply, config.security == .automatic ? "5" : "1"))
        return p
    }

    public static func commands(_ pairs: [(String, String)]) -> [String] {
        pairs.map { "@PJL DEFAULT OBJBRNET=\"\($0.0):\($0.1)\"" }
    }

    /// Stejné příkazy, ale s hesly nahrazenými tečkami – pro zápis do logu.
    public static func redacted(_ pairs: [(String, String)]) -> [String] {
        let secret: Set<String> = [BrNet.simpleKey, BrNet.wpaPSK, BrNet.wepKey]
        return pairs.map { id, value in
            let base = id.hasSuffix(".0") || id.hasSuffix(".1") ? String(id.dropLast(2)) : id
            return "@PJL DEFAULT OBJBRNET=\"\(id):\(secret.contains(base) ? "••••••" : value)\""
        }
    }

    public static func inquire(_ id: String) -> [String] {
        ["@PJL DEFAULT OBJBRNET=\"\(id)\"", "@PJL INQUIRE OBJBRNET"]
    }

    /// Najde v odpovědi `"<id>:<hodnota>"`.
    public static func parseInquire(_ response: String, id: String) -> String? {
        let pattern = "\"" + NSRegularExpression.escapedPattern(for: id) + ":([^\"]*)\""
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
           let r = Range(m.range(at: 1), in: response) {
            return String(response[r])
        }
        // Záloha jako v originálu: druhá část po rozdělení uvozovkami, za dvojtečkou.
        let parts = response.components(separatedBy: "\"")
        if parts.count > 1, let colon = parts[1].firstIndex(of: ":"), parts[1].hasPrefix(id) {
            return String(parts[1][parts[1].index(after: colon)...])
        }
        return nil
    }
}

// MARK: - Výsledky skenování

public struct WiFiNetwork: Identifiable, Hashable, Sendable {
    public var id: String { "\(ssid)#\(channel ?? 0)#\(index)" }
    public let index: Int
    public let ssid: String
    public let channel: Int?
    public let signal: Int?
    public let security: Int?
    public let encryption: Int?
    public let wlanMode: Int?
    public let commMode: Int?
    public let raw: [String: String]

    public init(index: Int, ssid: String, channel: Int?, signal: Int?, security: Int?, encryption: Int?,
                wlanMode: Int?, commMode: Int?, raw: [String: String] = [:]) {
        self.index = index; self.ssid = ssid; self.channel = channel; self.signal = signal
        self.security = security; self.encryption = encryption; self.wlanMode = wlanMode
        self.commMode = commMode; self.raw = raw
    }

    public var isAdHoc: Bool { commMode == 2 }

    public var securityTitle: String {
        switch security {
        case 1: return L("Open")
        case 2: return "WEP"
        case 3: return "WPA/WPA2‑Personal"
        case 4: return "WPA/WPA2‑Enterprise"
        default: return L("Unknown")
        }
    }

    public var isSecured: Bool { (security ?? 3) > 1 }

    /// Síla signálu 0–3 (originál zobrazoval 4 obrázky wavepower01–04).
    public var bars: Int {
        guard let signal else { return 0 }
        if signal <= 4 { return max(0, min(3, signal)) }
        return max(0, min(3, signal / 25))
    }

    public var suggestedSecurity: WiFiSecurity {
        switch security {
        case 1: return .open
        case 2: return .wep
        default: return .automatic
        }
    }
}

public struct WiFiScanResult: Sendable {
    public var networks: [WiFiNetwork]
    public var device: [String: String]
    public var lines: [String]

    public init(networks: [WiFiNetwork], device: [String: String] = [:], lines: [String] = []) {
        self.networks = networks; self.device = device; self.lines = lines
    }
}

public enum BrScanParser {
    /// Rozdělí řádek podle čárek s escapováním `$,` → `,` a `$$` → `$`.
    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var iterator = Array(line)
        var i = 0
        while i < iterator.count {
            let c = iterator[i]
            if c == "$", i + 1 < iterator.count, iterator[i + 1] == "," || iterator[i + 1] == "$" {
                current.append(iterator[i + 1])
                i += 2
                continue
            }
            if c == "," {
                tokens.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        tokens.append(current)
        iterator.removeAll()
        return tokens
    }

    /// Výsledek `@PJL INFO AVAILABLEWLAN`. První řádek je stav / počet řádků
    /// (-1 = skenování ještě běží, -2 = chyba), další jsou dvojice hlavička (L…) a hodnoty (V…).
    public static func parse(_ section: String) -> (status: Int?, result: WiFiScanResult) {
        let lines = section.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else {
            return (nil, WiFiScanResult(networks: [], device: [:], lines: []))
        }
        let status = Int(first.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        var headers: [String: [String]] = [:]
        var device: [String: String] = [:]
        var networks: [WiFiNetwork] = []

        for line in lines.dropFirst() {
            let tokens = tokenize(line)
            guard let tag = tokens.first?.uppercased(), tag.count >= 2 else { continue }
            let fields = Array(tokens.dropFirst())
            if tag.hasPrefix("L") {
                headers[String(tag.dropFirst())] = fields
                continue
            }
            guard tag.hasPrefix("V") else { continue }
            let kind = String(tag.dropFirst())
            var dict: [String: String] = [:]
            if let keys = headers[kind] {
                for (i, key) in keys.enumerated() where i < fields.count { dict[key] = fields[i] }
            } else {
                // Záloha: hodnoty ve tvaru klíč:hodnota.
                for field in fields {
                    if let colon = field.firstIndex(of: ":") {
                        dict[String(field[..<colon])] = String(field[field.index(after: colon)...])
                    }
                }
            }
            switch kind {
            case "DEV":
                device.merge(dict) { $1 }
            case "AP":
                networks.append(network(from: dict, index: networks.count))
            default:
                break
            }
        }

        networks.sort { ($0.bars, $0.ssid) > ($1.bars, $1.ssid) }
        return (status, WiFiScanResult(networks: networks, device: device, lines: lines))
    }

    static func network(from dict: [String: String], index: Int) -> WiFiNetwork {
        func int(_ key: String) -> Int? { dict[key].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        // Originál bere SSID ze skenu jako prostý text (jen s escapováním `$,`), proto ho nedekódujeme.
        let ssid = dict[BrNet.scanSSID] ?? ""
        return WiFiNetwork(index: index, ssid: ssid, channel: int(BrNet.scanChannel), signal: int(BrNet.scanSignal),
                           security: int(BrNet.scanSecurity), encryption: int(BrNet.scanEncryption),
                           wlanMode: int(BrNet.scanWlanMode), commMode: int(BrNet.scanCommMode), raw: dict)
    }
}

// MARK: - Chybové kódy WLAN reportu

public enum BrWLANReport {
    public static func describe(_ code: Int) -> (title: String, advice: String) {
        switch code {
        case 0:
            return (L("No error"), L("The printer reports no wireless connection error."))
        case 1:
            return (L("TS‑01: Wi‑Fi is turned off"),
                    L("Turn on wireless on the printer (Menu › Network › WLAN › WLAN Enable) and try again."))
        case 2:
            return (L("TS‑02: Router not found"),
                    L("The printer cannot see the network. Move it closer to the router and make sure the network broadcasts on 2.4 GHz and is not hidden."))
        case 3:
            return (L("TS‑03: Wrong network settings"),
                    L("Check the network name and security type. If the router uses WPA3 only, enable WPA2/WPA3 mode."))
        case 4:
            return (L("TS‑04: Unsupported security"),
                    L("The printer does not support WPA3 or some Enterprise modes. Set the router to WPA2‑Personal (AES)."))
        case 5:
            return (L("TS‑05: Wrong network name or password"),
                    L("The password does not match. Watch out for upper/lower case and trailing spaces."))
        case 6:
            return (L("TS‑06: Wrong security details"),
                    L("The chosen encryption does not match the router. Try “Automatic” or “WPA2‑Personal (AES)”."))
        case 7:
            return (L("TS‑07: No WPS router found"), L("WPS was not activated on the router in time."))
        case 8:
            return (L("TS‑08: Several routers in WPS mode"), L("Wait a few minutes and try again with only one router."))
        default:
            return (L("Error %d", code), L("Print the “WLAN Report” from the printer (Menu › Print Reports) – it describes the error in detail."))
        }
    }
}
