import Foundation
import Network

/// TCP CAT server: accepts multiple simultaneous clients (WSJT-X, fldigi, loggers)
/// and answers Kenwood TS-2000 commands via CATCommandProcessor.
///
/// All state lives on the MainActor; Network framework callbacks are delivered on
/// the main queue and re-enter the actor via `MainActor.assumeIsolated`.
@MainActor
@Observable
final class CATServer {
    private(set) var isRunning = false
    private(set) var port: UInt16 = 0
    private(set) var clientCount = 0
    private(set) var lastError: String?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var processor: CATCommandProcessor?

    /// Longest run of bytes tolerated without a ';' terminator before the
    /// connection's input buffer is discarded (protects against garbage clients).
    private static let maxBufferedBytes = 4096

    func start(port: UInt16, radio: CATRadioControl) {
        stop()
        lastError = nil
        guard let nwPort = NWEndpoint.Port(rawValue: port), port > 0 else {
            lastError = "Invalid port \(port)"
            return
        }
        processor = CATCommandProcessor(radio: radio)
        do {
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                    case .failed(let error):
                        self.lastError = error.localizedDescription
                        self.stop()
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
            self.port = port
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        buffers.removeAll()
        clientCount = 0
        isRunning = false
        processor = nil
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        buffers[id] = Data()
        clientCount = connections.count
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled:
                    self?.remove(id)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receive(on: connection, id: id)
    }

    private func remove(_ id: ObjectIdentifier) {
        connections.removeValue(forKey: id)?.cancel()
        buffers.removeValue(forKey: id)
        clientCount = connections.count
    }

    private func receive(on connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else {
                    connection.cancel()
                    return
                }
                if let data, !data.isEmpty {
                    self.consume(data, from: connection, id: id)
                }
                if isComplete || error != nil {
                    self.remove(id)
                } else {
                    self.receive(on: connection, id: id)
                }
            }
        }
    }

    /// Appends incoming bytes to the client's buffer, executes every complete
    /// ';'-terminated command, and sends the concatenated replies.
    private func consume(_ data: Data, from connection: NWConnection, id: ObjectIdentifier) {
        var buffer = (buffers[id] ?? Data()) + data
        var reply = ""
        while let sep = buffer.firstIndex(of: UInt8(ascii: ";")) {
            let chunk = Data(buffer[buffer.startIndex..<sep])
            buffer.removeSubrange(buffer.startIndex...sep)
            guard let command = String(data: chunk, encoding: .utf8),
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let processor else { continue }
            reply += processor.handle(command)
        }
        if buffer.count > Self.maxBufferedBytes { buffer.removeAll(keepingCapacity: false) }
        buffers[id] = buffer
        if !reply.isEmpty {
            connection.send(content: Data(reply.utf8), completion: .idempotent)
        }
    }
}
