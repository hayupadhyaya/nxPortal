#if os(macOS)
import Foundation
import Network
import PortalKit

/// One `artRequest` waiting on its link.
struct ArtAsk: Equatable, Sendable { let titleID: String, hash: String }

/// A game's icon as the service keeps it: the file it came from and that file's date (rebuilt only when the date
/// changes); `png` nil when the file does not make one.
struct KeptArt: Sendable {
    let icon: URL
    let modified: Date
    let png: (hash: String, data: Data)?
    var ref: ArtRef? { png.map { ArtRef(hash: $0.hash, bytes: UInt32($0.data.count)) } }
}

/// Icons for the device: kept once per title, sent on request in chunks -> .claude/host.md § library
extension HostService {
    /// `artRequest`s one link may have waiting; more are dropped (an honest device asks for at most 2 at a time).
    static let maxArtQueue = 128
    /// Transfers sending at once, over all links.
    static let maxArtTransfers = 4

    /// Rebuilds the kept icon of each game whose icon file is new or has another modification date, off the actor;
    /// forgets games no longer listed.
    func refreshArtwork(_ apps: [GameApp]) async {
        let known = artwork.mapValues { (icon: $0.icon, modified: $0.modified) }
        let bundles = apps.map { (titleID: $0.titleID, url: $0.url) }
        let changes = await Task.detached(priority: .utility) { () -> [String: KeptArt?] in
            var out: [String: KeptArt?] = [:]
            for app in bundles {
                guard let icon = GameArtwork.iconURL(forBundle: app.url),
                      let modified = (try? icon.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                    out[app.titleID] = .some(nil)
                    continue
                }
                if let k = known[app.titleID], k.icon == icon, k.modified == modified { continue }
                let png = GameArtwork.png(icon: icon, maxEdge: 512, maxBytes: ArtChunking.maxBytes)
                out[app.titleID] = KeptArt(icon: icon, modified: modified, png: png.map { (GameArtwork.hash($0), $0) })
            }
            return out
        }.value
        let listed = Set(apps.map(\.titleID))
        for (titleID, change) in changes { artwork[titleID] = change }
        for titleID in artwork.keys where !listed.contains(titleID) { artwork[titleID] = nil }
    }

    /// A well-formed ask: a title ID of at most 64 bytes of UTF-8 and a 64-character hash. Others are dropped unanswered.
    static let maxArtTitleBytes = 64, artHashLength = 64

    /// Queues the request on its link (one over `maxArtQueue`, or a malformed one, is dropped: no queue entry, no reply, so
    /// nothing a device sends is echoed back) and starts the link's worker.
    func askArt(_ id: Int, _ ask: ArtAsk) {
        guard ask.titleID.utf8.count <= Self.maxArtTitleBytes, ask.hash.utf8.count == Self.artHashLength,
              var link = links[id], link.artQueue.count < Self.maxArtQueue else { return }
        link.artQueue.append(ask)
        let start = !link.artBusy
        link.artBusy = true
        links[id] = link
        if start { Task { await self.serveArt(id) } }
    }

    /// One link's requests in order. Unknown title or hash: `count` 0 at once (a lookup). Known: its chunks, each sent
    /// only after the one before has been taken by the connection, so a device that does not read holds one chunk.
    private func serveArt(_ id: Int) async {
        while let ask = links[id]?.artQueue.first {
            links[id]?.artQueue.removeFirst()
            guard let png = artwork[ask.titleID]?.png, png.hash == ask.hash else {
                await sendTaken(id, .art(titleID: ask.titleID, hash: ask.hash, index: 0, count: 0, bytes: Data()))
                continue
            }
            await takeArtSlot()
            let count = ArtChunking.count(bytes: png.data.count)
            for i in 0..<count where links[id] != nil {
                let lo = i * ArtChunking.chunkBytes
                let chunk = png.data.subdata(in: lo..<min(lo + ArtChunking.chunkBytes, png.data.count))
                await sendTaken(id, .art(titleID: ask.titleID, hash: ask.hash, index: UInt16(i), count: UInt16(count), bytes: chunk))
            }
            releaseArtSlot()
        }
        links[id]?.artBusy = false
    }

    func takeArtSlot() async {
        if artTransfers < Self.maxArtTransfers {
            artTransfers += 1
            artTransfersPeak = max(artTransfersPeak, artTransfers)
            return
        }
        await withCheckedContinuation { artSlotWaiters.append($0) }  // the releaser hands its slot over
    }

    func releaseArtSlot() {
        if artSlotWaiters.isEmpty { artTransfers -= 1 } else { artSlotWaiters.removeFirst().resume() }
    }

    /// `send`, returning once the connection has taken the bytes (or the link has gone).
    private func sendTaken(_ id: Int, _ m: ControlMessage) async {
        guard links[id]?.session != nil, let json = try? m.encoded(),
              let sealed = try? links[id]!.session!.controlSealer.seal(json) else { return }
        let connection = links[id]!.connection
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            connection.send(content: ControlFramer.frame(sealed), completion: .contentProcessed { _ in done.resume() })
        }
        artMessagesTaken += 1
    }
}
#endif
