#if os(macOS)
import Foundation
import Network

enum ControlEvent: Sendable {
    case opened(Int, NWConnection)
    case data(Int, Data)
    /// May repeat, or follow the service's own cancel. `failed`: the receive ended with an error, not a close.
    case closed(Int, failed: Bool)
    /// The listener failed after it was ready (once); nothing more is accepted.
    case failed(any Error)
}

/// TCP listener for control connections; every connection's bytes reach `events` in order -> .claude/host.md § service
final class ControlListener: @unchecked Sendable {
    static let serviceType = "_nxportal._tcp"

    let events: AsyncStream<ControlEvent>
    private let continuation: AsyncStream<ControlEvent>.Continuation
    private let queue = DispatchQueue(label: "nxportal.control")
    private let lock = NSLock()  // guards listener, stopped, beforeStore
    private var listener: NWListener?
    private var stopped = false
    private var beforeStore: (@Sendable () async -> Void)?
    private var nextID = 0  // queue only
    private let cancelled = CancelSignal()

    init() {
        (events, continuation) = AsyncStream.makeStream(of: ControlEvent.self, bufferingPolicy: .unbounded)
    }

    /// Port 0 = any. Returns the bound port once listening; advertises when `serviceName` is given, with `txt` in its TXT record.
    func start(port: UInt16, serviceName: String?, txt: [String: String] = [:]) async throws -> UInt16 {
        let l = try NWListener(using: .tcp, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port) ?? .any)
        if let serviceName {
            l.service = NWListener.Service(name: serviceName, type: Self.serviceType, txtRecord: NWTXTRecord(txt))
        }
        l.newConnectionHandler = { [self] connection in
            let id = nextID
            nextID += 1
            // After stop() nobody owns it.
            if case .terminated = continuation.yield(.opened(id, connection)) { return connection.cancel() }
            connection.start(queue: queue)
            receive(connection, id)
        }
        let hold = lock.withLock { beforeStore }
        await hold?()
        // A stop() that came first has nothing to cancel: it is remembered here, before the listener opens.
        let refused = lock.withLock { () -> Bool in
            if stopped { return true }
            listener = l
            return false
        }
        if refused { throw CancellationError() }
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            once.set(c)
            l.stateUpdateHandler = { [self] state in
                switch state {
                case .ready: _ = once.resume(.success(l.port?.rawValue ?? 0))
                case let .failed(error): if !once.resume(.failure(error)) { listenerFailed(error) }  // after ready: reported
                case .cancelled:
                    _ = once.resume(.failure(CancellationError()))
                    cancelled.fire()
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, _ id: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty { continuation.yield(.data(id, data)) }
            if isComplete || error != nil { continuation.yield(.closed(id, failed: error != nil)); return }
            receive(connection, id)
        }
    }

    /// A listener that fails after `start()` returned: one `.failed` event, then it accepts nothing.
    private func listenerFailed(_ error: any Error) {
        lock.lock(); let l = listener; listener = nil; lock.unlock()
        guard let l else { return }  // stopped, or already reported
        l.cancel()
        continuation.yield(.failed(error))
    }

    /// Test hook: awaited in `start()` before the listener is stored (a `stop()` there must still close it).
    func holdBeforeStore(_ hold: (@Sendable () async -> Void)?) { lock.withLock { beforeStore = hold } }

    /// Test hook: the listener fails as it would after it was ready.
    func failForTest(_ error: any Error) { listenerFailed(error) }

    /// `stop()` that returns only when the listener has really cancelled (the port is free again).
    /// Waits at most 2 s (a listener cancelled before it started never reports it).
    func stopAndWait() async {
        let had = lock.withLock { listener != nil }
        stop()
        if had { await cancelled.wait(seconds: 2) }
    }

    /// Stops accepting; the stream finishes. Connections are the service's to cancel.
    func stop() {
        lock.lock(); let l = listener; listener = nil; stopped = true; lock.unlock()
        l?.cancel()
        continuation.finish()
    }
}

/// One event, waited for by any number of tasks.
private final class CancelSignal: @unchecked Sendable {
    private let lock = NSLock()  // guards fired, waiting
    private var fired = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func fire() {
        lock.lock(); fired = true; let w = waiting; waiting = []; lock.unlock()
        for c in w { c.resume() }
    }

    func wait(seconds: Double) async {
        let timer = Task { [self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            fire()  // gives up: the waiters go on
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired { lock.unlock(); c.resume() } else { waiting.append(c); lock.unlock() }
        }
        timer.cancel()
    }
}

/// Resumes a continuation at most once (listener state can change many times).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()  // guards continuation
    private var continuation: CheckedContinuation<UInt16, Error>?

    func set(_ c: CheckedContinuation<UInt16, Error>) { lock.lock(); continuation = c; lock.unlock() }

    /// False when it had been resumed already.
    @discardableResult
    func resume(_ result: Result<UInt16, Error>) -> Bool {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with: result)
        return c != nil
    }
}
#endif
