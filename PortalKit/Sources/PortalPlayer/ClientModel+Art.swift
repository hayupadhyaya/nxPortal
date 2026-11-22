import Foundation
import PortalKit
import PortalClientCore

/// Icons for the library: read from `artCache`, else asked of the Host (at most `maxArtInFlight` at once), checked
/// chunk by chunk (`ArtTransfer`), kept, and their palettes computed off the main actor -> .claude/client.md § model
extension ClientModel {
    static let maxArtInFlight = 2
    /// An asked icon not complete after this long is given up (it is asked again at the next list).
    static let artTimeout: TimeInterval = 15

    static func artKey(_ titleID: String, _ hash: String) -> String { titleID + "-" + hash }

    /// The game's icon (PNG) once it is here; nil without one.
    public func art(for game: GameEntry) -> Data? {
        game.art.flatMap { artData[Self.artKey(game.titleID, $0.hash)] }
    }

    /// The game's palette; `.slate` without an icon (or until it is here).
    public func palette(for game: GameEntry) -> ArtPalette {
        game.art.flatMap { artPalettes[Self.artKey(game.titleID, $0.hash)] } ?? .slate
    }

    /// The Continue card's game: the running or paused one, else the last played on this Mac from this device; nil without either.
    public var continueGame: GameEntry? {
        games.first { $0.state == .running || $0.state == .paused || $0.state == .starting }
            ?? lastPlayedTitle.flatMap { id in games.first { $0.titleID == id } }
    }

    /// A game started on the current Mac: the Continue card's fallback from now on.
    func playedOnThisMac(_ titleID: String) {
        guard lastPlayedTitle != titleID else { return }
        lastPlayedTitle = titleID
        if let key = current?.key { cache?.setLastPlayed(titleID, for: key) }
    }

    /// Icons the listed games need: those in the cache are read (off the main actor), the others queued for the Host.
    /// Icons of games no longer listed are let go.
    func wantArt() {
        guard let artCache else { return }
        let listed = Set(games.compactMap { g in g.art.map { Self.artKey(g.titleID, $0.hash) } })
        for key in artData.keys where !listed.contains(key) { artData[key] = nil; artPalettes[key] = nil }
        let wanted = games.compactMap { g -> (titleID: String, ref: ArtRef)? in
            guard let ref = g.art, ArtTransfer(titleID: g.titleID, ref: ref) != nil else { return nil }
            let key = Self.artKey(g.titleID, ref.hash)
            return artData[key] == nil && !artLoading.contains(key) ? (g.titleID, ref) : nil
        }
        guard !wanted.isEmpty else { return pumpArt() }
        for w in wanted { artLoading.insert(Self.artKey(w.titleID, w.ref.hash)) }
        Task { [weak self] in
            let read = await Task.detached(priority: .utility) {
                wanted.map { w -> (titleID: String, ref: ArtRef, data: Data?, palette: ArtPalette?) in
                    let data = artCache.data(titleID: w.titleID, hash: w.ref.hash)
                    return (w.titleID, w.ref, data, data == nil ? nil : artCache.palette(titleID: w.titleID, hash: w.ref.hash))
                }
            }.value
            self?.artRead(read)
        }
    }

    private func artRead(_ read: [(titleID: String, ref: ArtRef, data: Data?, palette: ArtPalette?)]) {
        for r in read {
            let key = Self.artKey(r.titleID, r.ref.hash)
            artLoading.remove(key)
            if let data = r.data {
                artData[key] = data
                artPalettes[key] = r.palette ?? .slate
            } else if !artQueue.contains(where: { $0.titleID == r.titleID && $0.ref == r.ref }),
                      artInFlight[r.titleID]?.ref != r.ref {
                artQueue.append((r.titleID, r.ref))
            }
        }
        pumpArt()
    }

    /// Asks for queued icons while fewer than `maxArtInFlight` are on their way (one per title).
    func pumpArt() {
        guard let l = link else { return }
        while artInFlight.count < Self.maxArtInFlight, !artQueue.isEmpty {
            let (titleID, ref) = artQueue.removeFirst()
            guard artInFlight[titleID] == nil, artData[Self.artKey(titleID, ref.hash)] == nil,
                  games.contains(where: { $0.titleID == titleID && $0.art == ref }),
                  let transfer = ArtTransfer(titleID: titleID, ref: ref) else { continue }
            artInFlight[titleID] = transfer
            artRequestsSent += 1
            artGenerationCounter += 1
            let generation = artGenerationCounter
            artGenerations[titleID] = generation  // the give-up below belongs to this transfer only
            let session = l.session, id = l.id, wait = UInt64(Self.artTimeout * 1e9)
            Task { try? await session.requestArt(titleID: titleID, hash: ref.hash) }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: wait)
                self?.artGaveUp(titleID, generation: generation, link: id)
            }
        }
    }

    /// One `art` message: a chunk of an icon this model asked for on this session; anything else is dropped.
    func artChunk(_ chunk: ArtChunk, link id: Int) {
        guard link?.id == id, var transfer = artInFlight[chunk.titleID], transfer.ref.hash == chunk.hash else { return }
        let step = transfer.accept(chunk)
        guard step != .more else { artInFlight[chunk.titleID] = transfer; return }
        artInFlight[chunk.titleID] = nil
        if case let .done(data) = step { arrived(data, titleID: chunk.titleID, hash: chunk.hash) }
        pumpArt()
    }

    private func arrived(_ data: Data, titleID: String, hash: String) {
        let key = Self.artKey(titleID, hash)
        artData[key] = data
        guard let artCache else { return }
        Task { [weak self] in
            let palette = await Task.detached(priority: .utility) { () -> ArtPalette? in
                artCache.store(data, titleID: titleID, hash: hash)
                return artCache.palette(titleID: titleID, hash: hash) ?? ArtPalette.from(png: data)
            }.value
            guard let self, self.artData[key] != nil else { return }
            self.artPalettes[key] = palette ?? .slate
        }
    }

    /// The give-up timer of one transfer (`generation`); a later transfer of the same icon is not cut short by an older timer.
    func artGaveUp(_ titleID: String, generation: Int, link id: Int) {
        guard link?.id == id, artGenerations[titleID] == generation, artInFlight[titleID] != nil else { return }
        artInFlight[titleID] = nil
        pumpArt()
    }

    /// The session's asks end with it; a later list asks again.
    func dropArtRequests() {
        artQueue = []
        artInFlight = [:]
    }
}
