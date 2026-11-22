import Foundation
import PortalKit

extension ClientModel {
    /// The stream size of the current game (nothing known: the setting), with the reason.
    public var effectiveStreamSize: (width: Int, height: Int, reason: String) { effectiveStreamSize(for: gameState?.titleID) }

    public func effectiveStreamSize(for titleID: String?) -> (width: Int, height: Int, reason: String) {
        RenderSizes.effective(cap: (settings.maxWidth, settings.maxHeight), known: titleID.flatMap { knownRender[$0] })
    }

    /// The line of `effectiveStreamSize(for:)`.
    public func streamSizeLine(for titleID: String?) -> String {
        let e = effectiveStreamSize(for: titleID)
        return RenderSizes.line(width: e.width, height: e.height, reason: e.reason)
    }

    /// The sizes of `SettingsChoices.sizes(for:)` with whether each is still offered for `titleID`'s game.
    public func sizeOffers(for titleID: String?) -> [(size: SettingsChoices.Size, enabled: Bool)] {
        let known = titleID.flatMap { knownRender[$0] }
        let list = SettingsChoices.sizes(for: settings)
        let offered = RenderSizes.offered(all: list.map { ($0.width, $0.height) }, known: known)
        return zip(list, offered).map { ($0, $1.enabled) }  // a saved cap above the game stays selected, shown disabled
    }

    /// The game page shows its size line only for a game whose size is known.
    public func showsSizeLine(for titleID: String) -> Bool { knownRender[titleID] != nil }

    /// Keeps the render size the Host reports for a game: a report that is not plausible, or for a title ID that is not
    /// well formed, is ignored; merging follows `RenderSizes.merged`; at most `RenderMemory.limit` titles are kept.
    func noteRender(_ state: GameState) {
        guard let id = state.titleID, let r = state.render, TitleID.isWellFormed(id), RenderSizes.plausible(r) else { return }
        guard let keep = RenderSizes.merged(old: knownRender[id], new: r) else { return renders.touch(id) }
        renders.set(keep, for: id)
        knownRender = renders.all
    }

    /// The note under the size choice for the current game: its stream size line when the game's size is known, and
    /// why some sizes are off; nil when there is nothing to say.
    public func sizeNote(for titleID: String?) -> String? {
        let known = titleID.map { knownRender[$0] != nil } ?? false
        return RenderSizes.note(line: known ? streamSizeLine(for: titleID) : nil, someAbove: sizeOffers(for: titleID).contains { !$0.enabled })
    }
}
