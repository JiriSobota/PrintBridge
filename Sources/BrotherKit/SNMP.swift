import Foundation
import Darwin

/// Minimální SNMPv2c klient (GET-NEXT walk) – stačí na čtení informací o firmwaru a toneru.
public enum SNMP {
    public enum Value: CustomStringConvertible, Sendable {
        case int(Int)
        case string(String)
        case other(UInt8)
        public var description: String {
            switch self {
            case .int(let i): return "\(i)"
            case .string(let s): return s
            case .other(let t): return "‹0x\(String(t, radix: 16))›"
            }
        }
        public var intValue: Int? { if case .int(let i) = self { return i }; return Int(description) }
    }

    public enum SNMPError: LocalizedError {
        case resolve, socket, timeout, malformed
        public var errorDescription: String? {
            switch self {
            case .resolve: return L("Could not resolve the printer address.")
            case .socket: return L("Could not open a UDP socket.")
            case .timeout: return L("The printer did not answer SNMP (it may be disabled).")
            case .malformed: return L("Invalid SNMP response.")
            }
        }
    }

    // MARK: BER

    static func encodeLength(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + encodeLength(content.count) + content }

    static func encodeInt(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = value
        repeat { bytes.insert(UInt8(truncatingIfNeeded: v), at: 0); v >>= 8 } while v != 0 && v != -1
        if value >= 0, let f = bytes.first, f & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }

    static func encodeOID(_ oid: [UInt32]) -> [UInt8] {
        guard oid.count >= 2 else { return tlv(0x06, []) }
        var out: [UInt8] = [UInt8(oid[0] * 40 + oid[1])]
        for component in oid.dropFirst(2) {
            var stack: [UInt8] = [UInt8(component & 0x7F)]
            var v = component >> 7
            while v > 0 { stack.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            out += stack
        }
        return tlv(0x06, out)
    }

    public static func request(community: String, requestID: Int, oid: [UInt32]) -> [UInt8] {
        let varbind = tlv(0x30, encodeOID(oid) + [0x05, 0x00])
        let pdu = tlv(0xA1, encodeInt(requestID) + encodeInt(0) + encodeInt(0) + tlv(0x30, varbind))
        return tlv(0x30, encodeInt(1) + tlv(0x04, Array(community.utf8)) + pdu)
    }

    struct Reader {
        let bytes: [UInt8]
        var pos = 0
        mutating func readTLV() throws -> (tag: UInt8, content: ArraySlice<UInt8>) {
            guard pos + 2 <= bytes.count else { throw SNMPError.malformed }
            let tag = bytes[pos]; pos += 1
            var length = Int(bytes[pos]); pos += 1
            if length & 0x80 != 0 {
                let n = length & 0x7F
                guard n <= 4, pos + n <= bytes.count else { throw SNMPError.malformed }
                length = 0
                for _ in 0..<n { length = (length << 8) | Int(bytes[pos]); pos += 1 }
            }
            guard pos + length <= bytes.count else { throw SNMPError.malformed }
            let content = bytes[pos..<(pos + length)]
            pos += length
            return (tag, content)
        }
    }

    static func decodeOID(_ c: ArraySlice<UInt8>) -> [UInt32] {
        guard let first = c.first else { return [] }
        var out: [UInt32] = [UInt32(first / 40), UInt32(first % 40)]
        var v: UInt32 = 0
        for b in c.dropFirst() {
            v = (v << 7) | UInt32(b & 0x7F)
            if b & 0x80 == 0 { out.append(v); v = 0 }
        }
        return out
    }

    static func parseResponse(_ data: [UInt8]) throws -> (oid: [UInt32], value: Value?, requestID: Int) {
        var top = Reader(bytes: data)
        let msg = try top.readTLV()
        var m = Reader(bytes: Array(msg.content))
        _ = try m.readTLV() // verze
        _ = try m.readTLV() // community
        let pdu = try m.readTLV()
        var p = Reader(bytes: Array(pdu.content))
        let rid = try p.readTLV()
        let requestID = rid.content.reduce(0) { ($0 << 8) | Int($1) }
        _ = try p.readTLV(); _ = try p.readTLV()
        let list = try p.readTLV()
        var l = Reader(bytes: Array(list.content))
        let vb = try l.readTLV()
        var v = Reader(bytes: Array(vb.content))
        let oid = decodeOID(try v.readTLV().content)
        let val = try v.readTLV()
        let value: Value?
        switch val.tag {
        case 0x02, 0x41, 0x42, 0x43:
            var n = 0
            for b in val.content { n = (n << 8) | Int(b) }
            if val.tag == 0x02, let f = val.content.first, f & 0x80 != 0 { n -= 1 << (8 * val.content.count) }
            value = .int(n)
        case 0x04:
            value = .string(String(decoding: val.content, as: UTF8.self))
        case 0x80, 0x81, 0x82:
            value = nil // noSuchObject / noSuchInstance / endOfMibView
        default:
            value = .other(val.tag)
        }
        return (oid, value, requestID)
    }

    // MARK: UDP

    public static func parseOID(_ s: String) -> [UInt32] { s.split(separator: ".").compactMap { UInt32($0) } }

    /// Projde podstrom MIB. Blokující volání.
    public static func walk(host: String, root: String, community: String = "public",
                            timeout: TimeInterval = 2, maxItems: Int = 200) throws -> [(String, Value)] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "161", &hints, &res) == 0, let info = res else { throw SNMPError.resolve }
        defer { freeaddrinfo(res) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { throw SNMPError.socket }
        defer { Darwin.close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else { throw SNMPError.socket }

        let rootOID = parseOID(root)
        var current = rootOID
        var results: [(String, Value)] = []
        var requestID = Int.random(in: 1000...30000)
        var buffer = [UInt8](repeating: 0, count: 65_535)

        while results.count < maxItems {
            requestID += 1
            let packet = request(community: community, requestID: requestID, oid: current)
            var received = -1
            for _ in 0..<2 { // jeden opakovaný pokus
                _ = packet.withUnsafeBytes { send(fd, $0.baseAddress, packet.count, 0) }
                received = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                if received > 0 { break }
            }
            guard received > 0 else {
                if results.isEmpty { throw SNMPError.timeout }
                break
            }
            let parsed = try parseResponse(Array(buffer[0..<received]))
            guard let value = parsed.value, parsed.oid.starts(with: rootOID), parsed.oid != current else { break }
            results.append((parsed.oid.map(String.init).joined(separator: "."), value))
            current = parsed.oid
        }
        return results
    }
}
