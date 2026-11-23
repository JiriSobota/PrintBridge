import Foundation

public enum PJL {
    /// Universal Exit Language – začátek a konec každé PJL úlohy.
    public static let uel = "\u{1B}%-12345X"

    /// Zabalí příkazy do PJL úlohy přesně jako originální Brother průvodce:
    /// `ESC%-12345X@PJL\r\n` + příkazy + `ESC%-12345X`
    public static func job(_ commands: [String]) -> Data {
        var text = uel + "@PJL\r\n"
        for command in commands { text += command + "\r\n" }
        text += uel
        return Data(text.utf8)
    }

    /// Počet příkazů, na které tiskárna posílá odpověď ukončenou znakem FF (0x0C).
    static func expectedResponses(_ commands: [String]) -> Int {
        commands.filter {
            let upper = $0.uppercased()
            return upper.hasPrefix("@PJL INFO") || upper.hasPrefix("@PJL INQUIRE")
                || upper.hasPrefix("@PJL DINQUIRE") || upper.hasPrefix("@PJL ECHO")
        }.count
    }

    /// Vrátí text odpovědi následující za ozvěnou příkazu (až po FF).
    public static func section(of response: String, for command: String) -> String? {
        guard let range = response.range(of: command, options: [.caseInsensitive, .backwards]) else { return nil }
        var rest = response[range.upperBound...]
        if rest.hasPrefix("\r\n") { rest = rest.dropFirst(2) } else if rest.hasPrefix("\n") { rest = rest.dropFirst() }
        if let ff = rest.firstIndex(of: "\u{0C}") { rest = rest[..<ff] }
        return String(rest)
    }

    /// Rozparsuje řádky `KLÍČ=HODNOTA` / `KLÍČ="HODNOTA"` z odpovědi.
    public static func keyValues(_ text: String) -> [(String, String)] {
        text.components(separatedBy: CharacterSet.newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { return nil }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, !key.hasPrefix("@") else { return nil }
            return (key, value)
        }
    }
}

/// Synchronní PJL relace nad libovolným transportem. Volat jen z jednoho (pracovního) vlákna.
public final class PJLSession: @unchecked Sendable {
    public let transport: PrinterTransport
    private let log: LogSink

    public init(transport: PrinterTransport, log: @escaping LogSink) {
        self.transport = transport
        self.log = log
    }

    /// Zahodí stará data čekající ve vstupní frontě (stejně jako `readTrashData` v originálu).
    public func drain(timeout: TimeInterval = 0.2) {
        var total = 0
        while total < 1 << 20, let chunk = try? transport.read(maxLength: 16 * 1024, timeout: timeout), !chunk.isEmpty {
            total += chunk.count
        }
        if total > 0 { log(LogEntry(.info, L("Discarded %d bytes of stale data from the printer.", total))) }
    }

    /// Odešle PJL úlohu bez čekání na odpověď.
    /// - Parameter logAs: text, který se zapíše do logu místo skutečných příkazů (kvůli heslům).
    public func send(_ commands: [String], logAs: [String]? = nil) throws {
        log(LogEntry(.outbound, (logAs ?? commands).joined(separator: "\n")))
        try transport.write(PJL.job(commands))
    }

    /// Odešle PJL úlohu a sbírá odpověď.
    /// Končí, když přijdou všechny očekávané odpovědi (FF), když `isComplete` vrátí true,
    /// po `idle` sekundách ticha od posledních dat, nebo po `timeout`.
    @discardableResult
    public func query(_ commands: [String],
                      timeout: TimeInterval = 10,
                      idle: TimeInterval = 1.5,
                      isComplete: ((String) -> Bool)? = nil) throws -> String {
        drain(timeout: 0.1)
        try send(commands)
        let expected = PJL.expectedResponses(commands)
        var received = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var lastData: Date?
        let sentAt = Date()
        var nudges = 0

        while Date() < deadline {
            let chunk = try transport.read(maxLength: 16 * 1024, timeout: 0.4)
            if !chunk.isEmpty {
                received.append(chunk)
                lastData = Date()
                let text = PJLSession.decode(received)
                if let isComplete {
                    if isComplete(text) { break }
                } else if expected > 0, text.filter({ $0 == "\u{0C}" }).count >= expected {
                    break
                }
            } else if let lastData, Date().timeIntervalSince(lastData) > idle {
                break
            } else if lastData == nil, nudges < 3, Date().timeIntervalSince(sentAt) > 2 + Double(nudges) * 3 {
                // Brother přes USB pošle odpověď až po dalších datech (parser čeká za UEL).
                // Samotná značka UEL úlohu uzavře a odpověď „vytlačí“, nic netiskne.
                nudges += 1
                try transport.write(Data(PJL.uel.utf8))
            }
        }
        let text = PJLSession.decode(received)
        if text.isEmpty {
            log(LogEntry(.info, L("No response.")))
        } else {
            log(LogEntry(.inbound, text.replacingOccurrences(of: "\u{0C}", with: "⏎")))
        }
        return text
    }

    static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    /// Pošle libovolná binární data (např. firmware) po kouscích s průběhem.
    public func sendRaw(_ data: Data, chunkSize: Int = 32 * 1024,
                        progress: (Double) -> Void, isCancelled: () -> Bool) throws {
        log(LogEntry(.outbound, L("‹binary data, %d bytes›", data.count)))
        var offset = 0
        while offset < data.count {
            if isCancelled() { throw CancellationError() }
            let end = min(offset + chunkSize, data.count)
            try transport.write(data.subdata(in: offset..<end))
            offset = end
            progress(Double(offset) / Double(max(1, data.count)))
        }
    }
}
