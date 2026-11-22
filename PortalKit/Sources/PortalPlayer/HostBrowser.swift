import Foundation
import Network

/// A Mac seen on the network; `name` is the Host's name -> .claude/client.md § discovery
public struct FoundHost: Equatable, Hashable, Sendable {
    public var name: String
    public var endpoint: NWEndpoint
    /// The service's TXT `id` (`Identity.discoveryID` of the Host's key); nil for a Host that sends none.
    public var id: String?
    public init(name: String, endpoint: NWEndpoint, id: String? = nil) { self.name = name; self.endpoint = endpoint; self.id = id }
}

public protocol HostBrowsing: Sendable {
    /// The full current list on every change, sorted by name; one stream for the object's lifetime.
    var hosts: AsyncStream<[FoundHost]> { get }
    /// True while browsing is failed or waiting (local network access not allowed, mDNS error); false once it works.
    var failures: AsyncStream<Bool> { get }
    func start()
    func stop()
    /// A new browser now when started (a permission granted meanwhile takes effect); nothing when stopped.
    func restart()
}

/// Bonjour `_nxportal._tcp` -> .claude/client.md § discovery
public final class HostBrowser: HostBrowsing, @unchecked Sendable {
    public static let serviceType = "_nxportal._tcp"
    /// What is browsed for. The TXT record rides on this descriptor only: a plain `.bonjour` never delivers the Host's `id`.
    static let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: serviceType, domain: nil)
    /// A failed browser is replaced after this long while still started.
    static let restartDelay: TimeInterval = 2
    public let hosts: AsyncStream<[FoundHost]>
    public let failures: AsyncStream<Bool>
    private let out: AsyncStream<[FoundHost]>.Continuation
    private let failuresOut: AsyncStream<Bool>.Continuation
    private let queue = DispatchQueue(label: "nxportal.client.browser")
    private let lock = NSLock()  // guards the vars below
    private var browser: NWBrowser?
    private var started = false
    private var pendingRestart: DispatchWorkItem?

    public init() {
        (hosts, out) = AsyncStream.makeStream(of: [FoundHost].self, bufferingPolicy: .bufferingNewest(1))
        (failures, failuresOut) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        pendingRestart?.cancel()
        browser?.cancel()
        out.finish()
        failuresOut.finish()
    }

    /// Harmless when already browsing.
    public func start() {
        lock.withLock {
            started = true
            guard browser == nil, pendingRestart == nil else { return }
            browseLocked()
        }
    }

    /// Stops browsing (and any pending restart) and yields an empty list; `start()` browses again.
    public func stop() {
        let b = lock.withLock { () -> NWBrowser? in
            started = false
            pendingRestart?.cancel()
            pendingRestart = nil
            let b = browser
            browser = nil
            return b
        }
        b?.cancel()
        out.yield([])
        failuresOut.yield(false)
    }

    public func restart() {
        let old = lock.withLock { () -> NWBrowser? in
            guard started else { return nil }
            pendingRestart?.cancel()
            pendingRestart = nil
            let b = browser
            browser = nil
            browseLocked()
            return b
        }
        old?.cancel()  // outside the lock: its state handler may run on this queue
    }

    /// Caller holds `lock`.
    private func browseLocked() {
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: Self.descriptor, using: params)
        b.browseResultsChangedHandler = { [weak self, weak b] results, _ in
            guard let self, let b else { return }
            self.changed(results, from: b)
        }
        b.stateUpdateHandler = { [weak self, weak b] state in
            guard let self, let b else { return }
            self.stateChanged(state, of: b)
        }
        browser = b
        b.start(queue: queue)
    }

    /// `.failed`: the browser is dropped and a new one starts after `restartDelay` while still started.
    private func stateChanged(_ state: NWBrowser.State, of b: NWBrowser) {
        let failed = lock.withLock { () -> Bool in
            guard browser === b else { return false }
            switch state {
            case .ready: failuresOut.yield(false)
            case .waiting: failuresOut.yield(true)
            case .failed:
                failuresOut.yield(true)
                browser = nil
                let item = DispatchWorkItem { [weak self] in self?.restarted() }
                pendingRestart = item
                queue.asyncAfter(deadline: .now() + Self.restartDelay, execute: item)
                return true
            default: break
            }
            return false
        }
        if failed { b.cancel() }  // outside the lock: its state handler may run on this queue
    }

    private func restarted() {
        lock.withLock {
            pendingRestart = nil
            guard started, browser == nil else { return }
            browseLocked()
        }
    }

    /// One advertisement as read from a browse result.
    struct Advertised: Equatable {
        var name: String, endpoint: NWEndpoint, id: String?
    }

    /// An advertised `id` counts only as exactly 16 lowercase hex characters (`Identity.discoveryID`); anything else is "no id".
    /// The length is checked first, so a long value costs nothing.
    static func validID(_ value: String?) -> String? {
        guard let value, value.utf8.count == 16,
              value.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else { return nil }
        return value
    }

    /// One entry per name and one per `id`, sorted by name. Entries are taken in name order, so when several advertisements
    /// share a name or an `id` the first by name wins (then by endpoint description): the list does not depend on the
    /// order a browse reports them in, and the app can key its rows by `id`.
    static func list(_ entries: [Advertised]) -> [FoundHost] {
        var names = Set<String>(), ids = Set<String>()
        var out: [FoundHost] = []
        for e in entries.sorted(by: { ($0.name, "\($0.endpoint)") < ($1.name, "\($1.endpoint)") }) {
            let id = validID(e.id)
            // The id is checked first: an entry dropped for it reserves no name.
            if let id, ids.contains(id) { continue }
            guard names.insert(e.name).inserted else { continue }
            if let id { ids.insert(id) }
            out.append(FoundHost(name: e.name, endpoint: e.endpoint, id: id))
        }
        return out
    }

    private func changed(_ results: Set<NWBrowser.Result>, from b: NWBrowser) {
        // A cancelled browser's late results are dropped; `stop()` already yielded the empty list.
        lock.withLock {
            guard browser === b else { return }
            var entries: [Advertised] = []
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint else { continue }
                var id: String?
                if case let .bonjour(txt) = r.metadata { id = txt["id"] }
                entries.append(Advertised(name: name, endpoint: r.endpoint, id: id))
            }
            out.yield(Self.list(entries))
        }
    }
}
