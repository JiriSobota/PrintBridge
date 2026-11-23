import Foundation
import Network

/// Obousměrné spojení na raw port tiskárny (JetDirect / PDL datastream, standardně TCP 9100).
/// Brother na tomto portu odpovídá na PJL dotazy stejně jako přes USB.
public final class TCPPrinterTransport: PrinterTransport, @unchecked Sendable {
    public let kind: TransportKind = .network
    public let displayName: String
    public private(set) var remoteHost: String?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "printbridge.tcp")
    private let condition = NSCondition()
    private var buffer = Data()
    private var failure: Error?
    private var isClosed = false

    public convenience init(host: String, port: UInt16 = 9100, timeout: TimeInterval = 8) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw TransportError.openFailed(L("Invalid port")) }
        try self.init(endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort), name: host, timeout: timeout)
        if remoteHost == nil { remoteHost = host }
    }

    public init(endpoint: NWEndpoint, name: String, timeout: TimeInterval = 8) throws {
        displayName = name
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout)
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(to: endpoint, using: params)

        let ready = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var startError: Error?
        var signalled = false
        func signalOnce() {
            stateLock.lock(); defer { stateLock.unlock() }
            if !signalled { signalled = true; ready.signal() }
        }

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                signalOnce()
            case .failed(let error):
                stateLock.lock(); startError = error; stateLock.unlock()
                signalOnce()
                self?.fail(error)
            case .waiting(let error):
                stateLock.lock(); startError = error; stateLock.unlock()
            case .cancelled:
                self?.fail(TransportError.closed)
                signalOnce()
            default:
                break
            }
        }
        connection.start(queue: queue)

        if ready.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            stateLock.lock(); let err = startError; stateLock.unlock()
            throw TransportError.openFailed(err?.localizedDescription ?? L("The printer is not responding (timeout)."))
        }
        guard connection.state == .ready else {
            connection.cancel()
            stateLock.lock(); let err = startError; stateLock.unlock()
            throw TransportError.openFailed(err?.localizedDescription ?? L("Could not establish the connection."))
        }

        if let remote = connection.currentPath?.remoteEndpoint, case let .hostPort(host, _) = remote {
            var text = "\(host)"
            if let pct = text.firstIndex(of: "%") { text = String(text[..<pct]) }
            remoteHost = text
        }
        receiveLoop()
    }

    deinit { close() }

    private func fail(_ error: Error) {
        condition.lock()
        if failure == nil { failure = error }
        condition.broadcast()
        condition.unlock()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.condition.lock()
                self.buffer.append(data)
                self.condition.broadcast()
                self.condition.unlock()
            }
            if let error {
                self.fail(error)
            } else if isComplete {
                self.fail(TransportError.closed)
            } else {
                self.receiveLoop()
            }
        }
    }

    public func write(_ data: Data) throws {
        guard !isClosed else { throw TransportError.closed }
        let done = DispatchSemaphore(value: 0)
        var sendError: Error?
        connection.send(content: data, completion: .contentProcessed { error in
            sendError = error
            done.signal()
        })
        let seconds = max(30, Double(data.count) / 50_000)
        if done.wait(timeout: .now() + seconds) == .timedOut {
            throw TransportError.io(L("Sending is taking too long."))
        }
        if let sendError { throw TransportError.io(sendError.localizedDescription) }
    }

    public func read(maxLength: Int, timeout: TimeInterval) throws -> Data {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while buffer.isEmpty && failure == nil {
            if !condition.wait(until: deadline) { break }
        }
        if buffer.isEmpty {
            if let failure, !(failure is TransportError) { throw TransportError.io(failure.localizedDescription) }
            if failure != nil { throw TransportError.closed }
            return Data()
        }
        let count = min(maxLength, buffer.count)
        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(out)
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
    }
}
