#if os(macOS)
import Foundation
import PortalKit

/// A device that paired with this Host.
public struct PairedDevice: Equatable, Sendable, Identifiable {
    /// The device's public key.
    public var id: Data
    /// The device's own name, as it last told it.
    public var name: String
    public var live: Bool
    /// What the Host's menu, status line and remove question call it: the Host's rename, else the device's name, numbered when
    /// another device shows the same.
    public var shownName: String
    /// From its latest `hello`; nil for a device that has not connected since this was kept.
    public var kind: DeviceKind?
    /// The Host's own name for it, if the person gave one.
    public var alias: String?
    public init(id: Data, name: String, live: Bool, shownName: String? = nil, kind: DeviceKind? = nil, alias: String? = nil) {
        self.id = id; self.name = name; self.live = live; self.shownName = shownName ?? name; self.kind = kind; self.alias = alias
    }

    /// The name each device is shown by, by key -> .claude/host.md § admin. Devices go in the order they paired (`added`; one
    /// without a date, from an older file, comes first, in the file's order). The first of a name keeps it; each later one
    /// whose name is taken gets " 2", " 3", … until it is unique among the shown names and not another device's own name.
    /// Names are cleaned and bounded here too (whatever the file holds), compared exactly, computed on each call, never stored.
    public static func shownNames(_ peers: [PairedPeer]) -> [Data: String] {
        let ordered = peers.enumerated().sorted { l, r in
            switch (l.element.added, r.element.added) {
            case (nil, nil): return l.offset < r.offset
            case (nil, _?): return true
            case (_?, nil): return false
            case let (x?, y?): return x != y ? x < y : l.offset < r.offset
            }
        }.map(\.element)
        let bases = ordered.map { DeviceName.clean($0.alias ?? "") ?? DeviceName.clean($0.name) ?? DeviceName.fallback }
        var shown: [Data: String] = [:]
        var taken = Set<String>()
        for (i, peer) in ordered.enumerated() {
            let base = bases[i]
            var name = base
            var n = 1
            let others = Set(bases.enumerated().filter { $0.offset != i }.map(\.element))
            while taken.contains(name) || (n > 1 && others.contains(name)) {
                n += 1
                name = DeviceName.numbered(base, n)
            }
            taken.insert(name)
            shown[peer.key] = name
        }
        return shown
    }
}

/// Calls the Host app makes -> .claude/host.md § admin
/// After `stop()` each of them does nothing, returns nothing or throws `HostServiceError.stopped`: none starts, launches or publishes anything.
extension HostService {
    /// Variables the Host sets itself; a game's own environment never replaces them.
    static let reservedGameVariables: Set<String> = ["DM_STREAM", "DM_LAUNCHER"]

    /// Every paired device, sorted by shown name (computed first, `PairedDevice.shownNames`); `live` for the one with the
    /// admitted session.
    public func devices() -> [PairedDevice] {
        let live = liveLink.flatMap { links[$0]?.session?.peer.key }
        let peers = store.peers
        let shown = PairedDevice.shownNames(peers)
        return peers.map { PairedDevice(id: $0.key, name: $0.name, live: $0.key == live, shownName: shown[$0.key], kind: $0.kind, alias: $0.alias) }
            .sorted { $0.shownName != $1.shownName ? $0.shownName < $1.shownName : $0.id.lexicographicallyPrecedes($1.id) }
    }

    /// The name `key` is shown by now (the alias, else its own name, numbered), cleaned and bounded: also what goes on the wire.
    func shownName(of key: Data) -> String {
        PairedDevice.shownNames(store.peers)[key] ?? DeviceName.fallback
    }

    /// The Host's own name for a device (the alias); cleaned like any name, and nil or an empty result removes it. Allowed while
    /// the device is connected; nothing is sent to it. The store's error is thrown when it cannot write. After `stop()`: throws
    /// `HostServiceError.stopped`.
    public func renameDevice(_ id: Data, to name: String?) throws {
        guard !stopped else { throw HostServiceError.stopped }
        try store.setAlias(name, key: id)
        publishStatus()
    }

    /// What the live device last told this Host (`liveSettings`): its clamped ceiling and panel level, each nil until
    /// sent; nil when no session is live. A new session starts with neither.
    public func liveSettings() -> LiveSettings? {
        guard !stopped, let s = liveLink.flatMap({ links[$0]?.session }) else { return nil }
        return LiveSettings(ceilingBps: s.ceilingBps, panel: s.panel)
    }

    /// Unpairs the device. Its live session gets a sealed `bye` and ends (the game pauses, `by device-removed`); a connection
    /// welcomed but not admitted is closed too. A device that is not paired is no error. When the store cannot write, the
    /// sessions still end (the owner asked for the device to be gone) and the store's error is thrown: the device stays in
    /// `devices()` because it is still paired in the store. After `stop()`: throws `HostServiceError.stopped`.
    public func removeDevice(_ id: Data) throws {
        guard !stopped else { throw HostServiceError.stopped }
        var storeError: (any Error)?
        do { try store.remove(key: id) } catch { storeError = error }
        for (linkID, link) in links where link.session?.peer.key == id {
            send(linkID, .bye())
            end(linkID, afterSend: true, by: .deviceRemoved)
        }
        publishStatus()
        if let storeError { throw storeError }
    }

    /// The folders the library reads, from now on: the next `games()` and client list show them.
    public func setLibraryRoots(_ roots: [URL]) {
        guard !stopped else { return }
        library = GameLibrary(roots: roots)
        lifecycle.scanned = []
        lifecycle.scannedAt = nil
        lifecycle.libraryEpoch += 1
    }

    /// The list a client gets (the running game stays in it until it exits).
    public func games() async -> [GameEntry] {
        guard !stopped else { return [] }
        let list = await entries()
        return stopped ? [] : list
    }

    /// Ends the pairing window: status leaves `.pairing`, and a `pairStart` that follows gets `.expired`.
    public func cancelPairing() {
        guard !stopped, pairing != nil else { return }
        pairing = nil
        publishStatus()
    }

    /// The icon the service keeps for `titleID` (the PNG devices get); nil without one. The only copy -> .claude/host.md § library
    public func artwork(titleID: String) async -> Data? { stopped ? nil : artwork[titleID]?.png?.data }

    /// What the live session and the running game add to `status`, read together (the menu's second line and the game rows' tags).
    public struct SessionDetail: Equatable, Sendable {
        /// The live device's game frame rate as measured (nil until measured) and the video rate now (bit/s); nil without a live session.
        public var fps: Int?, bps: UInt32?
        /// The game that is preparing its graphics and how far it has got (`Preparing.waiting` = no progress yet); nil titleID = none.
        public var preparingTitleID: String?, preparing: Preparing?
        public init(fps: Int? = nil, bps: UInt32? = nil, preparingTitleID: String? = nil, preparing: Preparing? = nil) {
            self.fps = fps; self.bps = bps; self.preparingTitleID = preparingTitleID; self.preparing = preparing
        }
    }

    /// The measured frame rate while its measure is under 3 s old; nil after, and while none is made.
    func reportedFps(atNs now: UInt64) -> Int? { now &- fpsMeasuredNs < 3_000_000_000 ? measuredFps : nil }

    /// The live session's frame rate and rate and the game's preparation, as of now. Read when `status` moves and when the menu opens; never polled.
    public func sessionDetail() async -> SessionDetail {
        guard !stopped else { return SessionDetail() }
        var d = SessionDetail()
        if let id = liveLink, let s = links[id]?.session {
            // measured, never the device's cap: unknown until the game has delivered a second of frames
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            d.fps = model.playing ? reportedFps(atNs: now) : nil
            // the encoder's rate while the game plays for this device; else the session's own rate, under its ceiling
            let wished = min(s.rateBps ?? ceiling(of: s), ceiling(of: s))
            d.bps = game?.connected == true && model.playing ? videoBitrate : wished
        }
        if let g = game, let p = reportedPreparing { d.preparingTitleID = g.app.titleID; d.preparing = p }
        return d
    }

    /// 16 hex digits of the Host's key, advertised as `id` (`Identity.discoveryID`).
    public nonisolated var discoveryID: String { store.identity.discoveryID }

    /// The variables a game is started with besides the launcher's own: the Host-wide file's, then the per-game choices over
    /// them for the same variable; the Host's own (`reservedGameVariables`) are in neither, and a choice never sets a variable of
    /// the runtime's own (`ReservedVariables`: the owner's file may).
    static func launchEnvironment(file: [String: String], choices: [String: String],
                                  allowing: (String) -> Bool = PlayerOptions.isSettable) -> [String: String] {
        file.merging(choices.filter { allowing($0.key) && !ReservedVariables.isReserved($0.key) }) { _, choice in choice }
            .filter { !reservedGameVariables.contains($0.key) }
    }
}
#endif
