import Foundation

/// Typ spojení s tiskárnou.
public enum TransportKind: String, Sendable {
    case usb = "USB"
    case network = "Network"
}

public enum TransportError: LocalizedError {
    case notFound
    case busy
    case openFailed(String)
    case io(String)
    case notBidirectional
    case closed

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return L("Printer not found. Check the cable or the network connection.")
        case .busy:
            return L("The printer is in use by another program (e.g. the macOS print queue). Wait for printing to finish and try again.")
        case .openFailed(let s):
            return L("Could not open the connection: %@", s)
        case .io(let s):
            return L("Communication error: %@", s)
        case .notBidirectional:
            return L("The printer's USB interface is not bidirectional, so responses cannot be read.")
        case .closed:
            return L("The connection to the printer was closed.")
        }
    }
}

/// Obousměrný kanál k tiskárně (USB bulk pipe nebo TCP port 9100).
public protocol PrinterTransport: AnyObject, Sendable {
    var kind: TransportKind { get }
    var displayName: String { get }
    /// IP adresa / hostname, pokud jde o síťové spojení.
    var remoteHost: String? { get }
    func write(_ data: Data) throws
    /// Vrátí přijatá data, nebo prázdná data při vypršení časového limitu.
    func read(maxLength: Int, timeout: TimeInterval) throws -> Data
    func close()
}

public struct LogEntry: Identifiable, Sendable {
    public enum Direction: Sendable {
        case outbound, inbound, info, error
    }

    public let id = UUID()
    public let date = Date()
    public let direction: Direction
    public let text: String

    public init(_ direction: Direction, _ text: String) {
        self.direction = direction
        self.text = text
    }
}

public typealias LogSink = @Sendable (LogEntry) -> Void
