import Foundation
import Network

/// One `NWConnection` with its inbound bytes (TCP) or datagrams (UDP) as an ordered stream.
/// The stream finishes when the connection ends. -> .claude/client.md § session
final class NWLink: @unchecked Sendable {
    let inbound: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let connection: NWConnection
    private let udp: Bool
    private let queue = DispatchQueue(label: "nxportal.client.link")
    private let lock = NSLock()  // guards ready
    private var ready: CheckedContinuation<Void, Error>?

    /// `from`: the local endpoint to send from (test tools); nil = the system picks.
    init(endpoint: NWEndpoint, udp: Bool, from: NWEndpoint? = nil) {
        let params: NWParameters = udp ? .udp : .tcp
        params.requiredLocalEndpoint = from
        if udp { params.serviceClass = .interactiveVideo }  // the media datagrams; control stays best effort
        if !udp, let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options { tcp.noDelay = true }
        connection = NWConnection(to: endpoint, using: params)
        self.udp = udp
        (inbound, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
    }

    deinit { connection.cancel() }

    /// Returns once the connection is ready; throws `ClientError.timeout` or `.closed`.
    func start(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.withLock { ready = c }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    resumeReady(nil)
                    receive()
                case let .waiting(error):
                    if case .posix(.ECONNREFUSED) = error { resumeReady(ClientError.closed); finish() }
                case .failed, .cancelled:
                    resumeReady(ClientError.closed)
                    finish()
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                if self?.resumeReady(ClientError.timeout) == true { self?.cancel() }
            }
        }
    }

    /// The peer address once connected.
    var remoteHost: NWEndpoint.Host? {
        if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint { return host }
        return nil
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Sends `last`, then cancels once it is written.
    func close(sending last: Data?) {
        if let last {
            connection.send(content: last, completion: .contentProcessed { [connection] _ in connection.cancel() })
        } else {
            connection.cancel()
        }
    }

    func cancel() { connection.cancel(); finish() }

    func finish() { continuation.finish() }

    @discardableResult
    private func resumeReady(_ error: Error?) -> Bool {
        let c = lock.withLock { () -> CheckedContinuation<Void, Error>? in let c = ready; ready = nil; return c }
        guard let c else { return false }
        if let error { c.resume(throwing: error) } else { c.resume() }
        return true
    }

    private func receive() {
        if udp {
            connection.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }
                if let data, !data.isEmpty { continuation.yield(data) }
                if error != nil { return finish() }
                receive()
            }
        } else {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty { continuation.yield(data) }
                if isComplete || error != nil { return finish() }
                receive()
            }
        }
    }
}
