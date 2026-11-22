import Foundation
import PortalKit
import PortalClientCore

/// What the person changed in a game's options and the Host has not answered yet: a value, or nil = remove the choice.
struct OptionWish: Equatable {
    var value: String?
    var seq: Int
}

/// One options message sent and not yet answered.
struct OptionAsk: Equatable {
    enum Kind: Equatable { case request, set(env: String), reset }
    var id: Int
    var title: String
    var kind: Kind
}

/// A game's own options on the open session: asked, edited optimistically, dropped with the session
/// -> .claude/client.md § model. The app knows kinds, not options: every label, value and list is the Host's, cleaned
/// (`OptionClean`) before it is kept.
extension ClientModel {
    /// Titles one session asks about; a reply for any other is dropped.
    static let maxOptionTitles = 32

    /// The game's options with the unanswered changes over them (a change shows at once); nil until the Mac has answered
    /// for this session, and never another session's or another Mac's.
    public func options(for titleID: String) -> GameOptions? {
        guard link != nil, var o = optionLists[titleID] else { return nil }
        if optionResets.contains(titleID) {
            for i in o.settings.indices { o.settings[i].current = o.settings[i].defaultValue; o.settings[i].chosen = false }
        }
        for (env, wish) in optionWishes[titleID] ?? [:] {
            guard let i = o.settings.firstIndex(where: { $0.env == env }) else { continue }
            let value = wish.value ?? o.settings[i].defaultValue
            o.settings[i].current = value
            o.settings[i].chosen = wish.value != nil && !Self.sameOptionValue(value, o.settings[i].defaultValue)
        }
        return o
    }

    public enum OptionsState: Equatable, Sendable { case loaded, loading, unavailable }

    /// What the page says while it has no list: loading, or unavailable (no session, or this session asked about as many
    /// titles as it may).
    public func optionsState(for titleID: String) -> OptionsState {
        if optionLists[titleID] != nil { return .loaded }
        guard link != nil, TitleID.isWellFormed(titleID), !optionLoadFailed.contains(titleID),
              optionAsked.contains(titleID) || optionAsked.count < Self.maxOptionTitles else { return .unavailable }
        return .loading
    }

    /// Something sent for this game has not been answered yet.
    public func optionsPending(titleID: String) -> Bool { (optionInFlight[titleID] ?? 0) > 0 }

    /// "1" and "1.0" are one value for a range.
    static func sameOptionValue(_ a: String, _ b: String) -> Bool {
        a == b || (Double(a).flatMap { x in Double(b).map { abs(x - $0) < 1e-9 } } ?? false)
    }

    /// Asks the Mac for the game's options and returns when the answer is in (or the session is gone).
    public func loadOptions(titleID: String) async {
        guard let l = link, TitleID.isWellFormed(titleID), optionAsked.contains(titleID) || optionAsked.count < Self.maxOptionTitles else { return }
        optionAsked.insert(titleID)
        optionLoadFailed.remove(titleID)
        let ask = noteOption(titleID, .request)
        let sent = await queueOption(l, titleID, ask) { try await $0.optionsRequest(titleID: titleID) }
        guard sent else { return }
        await settled(titleID, link: l.id)
    }

    /// Changes one row for the next start: shown at once; the Mac's answer replaces it, and a refusal (or a message that
    /// could not go) puts the old value back and says so in `message`. `value` nil removes the person's choice.
    public func setOption(titleID: String, env: String, value: String?) async {
        guard let l = link, let row = optionLists[titleID]?.settings.first(where: { $0.env == env }) else { return }
        optionWishCounter += 1
        let seq = optionWishCounter
        optionWishes[titleID, default: [:]][env] = OptionWish(value: value, seq: seq)
        let ask = noteOption(titleID, .set(env: env))
        let sent = await queueOption(l, titleID, ask) { try await $0.setOption(titleID: titleID, env: env, value: value) }
        guard sent else {
            guard link?.id == l.id else { return }
            if optionWishes[titleID]?[env]?.seq == seq { optionWishes[titleID]?[env] = nil }
            message = OptionText.notSent(label: row.label)
            return
        }
        await settled(titleID, link: l.id)
    }

    /// "Reset to tested defaults": every row shows its default at once; the Mac removes the person's choices.
    public func resetOptions(titleID: String) async {
        guard let l = link, optionLists[titleID] != nil else { return }
        let kept = optionWishes[titleID]
        optionWishes[titleID] = nil
        optionResets.insert(titleID)
        let ask = noteOption(titleID, .reset)
        let sent = await queueOption(l, titleID, ask) { try await $0.resetOptions(titleID: titleID) }
        guard sent else {
            guard link?.id == l.id else { return }
            optionResets.remove(titleID)
            // changes still waiting for their answer stay; once nothing is in flight the Mac's list is the truth
            if (optionInFlight[titleID] ?? 0) > 0, let kept { optionWishes[titleID] = kept }
            message = OptionText.resetNotSent
            return
        }
        await settled(titleID, link: l.id)
    }

    private func noteOption(_ title: String, _ kind: OptionAsk.Kind) -> Int {
        optionAskCounter += 1
        optionOrder.append(OptionAsk(id: optionAskCounter, title: title, kind: kind))
        optionInFlight[title, default: 0] += 1
        return optionAskCounter
    }

    /// One `options` reply: kept only for a title this session asked about, cleaned. A refusal drops that row's pending
    /// change (the answer holds the value it keeps) and says so; once every message for the title is answered the Mac's
    /// list is the truth.
    func optionsReply(_ reply: GameOptions, link id: Int) {
        guard link?.id == id, optionAsked.contains(reply.titleID), let clean = OptionClean.cleaned(reply) else { return }
        let title = clean.titleID
        if let i = optionOrder.firstIndex(where: { $0.title == title }) { optionOrder.remove(at: i) }
        optionInFlight[title] = max(0, (optionInFlight[title] ?? 0) - 1)
        optionLists[title] = GameOptions(titleID: title, settings: clean.settings)
        if let env = clean.rejected {
            optionWishes[title]?[env] = nil
            message = clean.full == true ? OptionText.macFull : OptionText.rejected(label: clean.settings.first { $0.env == env }?.label ?? env)
        }
        optionSettle(title)
    }

    /// An `options` reply the decoder refused (over the limits): it answered the oldest message still unanswered, whatever
    /// it was. That message is given up the way a refused one is (the wish goes back, the sentence says so) and its call
    /// returns; the session and the other calls go on.
    func optionsRefused(link id: Int) {
        guard link?.id == id, !optionOrder.isEmpty else { return }
        giveUp(optionOrder.removeFirst())
        optionSettle(nil)
    }

    private func giveUp(_ ask: OptionAsk, timedOut: Bool = false) {
        optionInFlight[ask.title] = max(0, (optionInFlight[ask.title] ?? 0) - 1)
        switch ask.kind {
        case .request:
            if optionLists[ask.title] == nil { optionLoadFailed.insert(ask.title) }
            message = OptionText.couldNotLoad
        case let .set(env):
            let label = optionLists[ask.title]?.settings.first { $0.env == env }?.label ?? env
            optionWishes[ask.title]?[env] = nil
            message = timedOut ? OptionText.didNotAnswer(label: label) : OptionText.rejected(label: label)
        case .reset:
            optionResets.remove(ask.title)
            message = OptionText.resetNotSent
        }
        settleTitle = ask.title
    }

    /// When nothing is in flight for the title: the Mac's list is the truth, and the calls waiting for it return.
    private func optionSettle(_ title: String?) {
        guard let title = title ?? settleTitle else { return }
        settleTitle = nil
        guard (optionInFlight[title] ?? 0) == 0 else { return }
        optionWishes[title] = nil
        optionResets.remove(title)
        for c in optionWaiters.removeValue(forKey: title) ?? [] { c.resume() }
    }

    /// Sends in the order the calls were made; false when the message could not go (the count it added is taken back).
    private func queueOption(_ l: Link, _ titleID: String, _ ask: Int, _ call: @escaping @Sendable (ClientSession) async throws -> Void) async -> Bool {
        let previous = optionSend, hook = optionSendHook
        let task = Task { () -> Bool in
            _ = await previous?.value
            do { try await hook?(); try await call(l.session); return true } catch { return false }
        }
        optionSend = task
        let sent = await task.value
        if !sent, link?.id == l.id {
            optionOrder.removeAll { $0.id == ask }
            optionInFlight[titleID] = max(0, (optionInFlight[titleID] ?? 0) - 1)
            if optionInFlight[titleID] == 0 { for c in optionWaiters.removeValue(forKey: titleID) ?? [] { c.resume() } }
        }
        return sent
    }

    /// Returns when everything sent for `titleID` has been answered, the session `id` is gone, or the Mac has not answered
    /// within `optionReplyTimeout` (then what is unanswered for the title is given up like a refused message).
    private func settled(_ titleID: String, link id: Int) async {
        let timeout = optionReplyTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.optionsTimedOut(titleID, link: id)
        }
        defer { timer.cancel() }
        while link?.id == id, optionsPending(titleID: titleID) {
            await withCheckedContinuation { optionWaiters[titleID, default: []].append($0) }
        }
    }

    private func optionsTimedOut(_ title: String, link id: Int) {
        guard link?.id == id, optionsPending(titleID: title) else { return }
        for ask in optionOrder.filter({ $0.title == title }) { giveUp(ask, timedOut: true) }
        optionOrder.removeAll { $0.title == title }
        optionSettle(title)
    }

    /// The session ended or the Mac changed: nothing of its options stays, and nobody keeps waiting.
    func dropOptions() {
        optionLists = [:]
        optionWishes = [:]
        optionResets = []
        optionAsked = []
        optionInFlight = [:]
        optionOrder = []
        optionLoadFailed = []
        optionSend?.cancel()
        optionSend = nil
        let waiting = optionWaiters.values.flatMap { $0 }
        optionWaiters = [:]
        for c in waiting { c.resume() }
    }
}
