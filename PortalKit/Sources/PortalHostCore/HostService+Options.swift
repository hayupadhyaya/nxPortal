#if os(macOS)
import Foundation
import PortalKit

/// A game's own settings, kept per game on the Mac and applied at its next start -> .claude/host.md § options
extension HostService {
    private enum OptionsOp: Sendable {
        case request, reset
        case set(env: String, value: String?)
    }

    // MARK: control

    /// `optionsRequest`: the game's list with the effective values. A title the Mac does not have, or a game without a list, is
    /// an empty answer; nothing is read from disk for a title that is not in the (cached) library. (The decoder has already
    /// refused a title that is not a title ID.)
    func optionsRequested(_ id: Int, titleID: String) async { await optionsAnswer(id, titleID: titleID, .request) }

    /// `setOption`: kept only for a variable the game's own list has (never a hidden, a reserved or the Host's own one), to a
    /// value its row offers; `value` nil removes the choice (also one whose row the list no longer has), as does a value equal
    /// to the row's default. The answer is the new state; `rejected` names the variable of a set that was refused (empty when the
    /// text is not a variable name), with nothing changed. A running game is not touched.
    func optionSet(_ id: Int, titleID: String, env: String, value: String?) async {
        await optionsAnswer(id, titleID: titleID, .set(env: env, value: value))
    }

    /// `resetOptions`: every choice for the game goes (also for a title the Mac no longer has).
    func optionsReset(_ id: Int, titleID: String) async { await optionsAnswer(id, titleID: titleID, .reset) }

    /// The library lookup is the actor's (a scan of the cached list); the file reads, the preference reads and the store's file
    /// sync run off it, so media goes on while they do.
    private func optionsAnswer(_ id: Int, titleID: String, _ op: OptionsOp) async {
        guard TitleID.isWellFormed(titleID) else { return }
        let app = await apps().first { $0.titleID == titleID }
        let store = optionsStore, saved = config.savedChoice, allowing = config.settableOption
        let answer = await Task.detached(priority: .userInitiated) {
            Self.performOptions(op, titleID: titleID, app: app, store: store, saved: saved, allowing: allowing)
        }.value
        guard !stopped else { return }
        if let out = config.optionsAnswerHook.map({ $0(answer) }) ?? answer { send(id, .options(out)) }
    }

    private nonisolated static func performOptions(_ op: OptionsOp, titleID: String, app: GameApp?, store: GameOptionsStore,
                                                   saved: @Sendable (String, String) -> String?,
                                                   allowing: @Sendable (String) -> Bool) -> GameOptions {
        if case .reset = op { store.reset(titleID: titleID) }
        let rows = app.flatMap { GameOptionsReader.read(bundle: $0.url, allowing: allowing) }
        var rejected: String?, full = false
        if case let .set(env, value) = op {
            rejected = OptionLimits.isEnvName(env) ? env : ""
            if OptionLimits.isEnvName(env), allowing(env), !ReservedVariables.isReserved(env) {
                if value == nil {
                    if store.set(nil, env: env, titleID: titleID) { rejected = nil }  // also a choice whose row is gone
                } else if let value, let row = rows?.first(where: { $0.env == env }), let canonical = GameOptionsReader.validate(value, for: row) {
                    if store.set(canonical, env: env, titleID: titleID, default: GameOptionsReader.canonical(row.defaultValue, for: row)) {
                        rejected = nil
                    } else if store.isFull(forNew: titleID) {
                        full = true  // the Mac keeps choices for as many games as it can: this one has none yet
                    }
                }
            }
        }
        let fullFlag: Bool? = full ? true : nil
        guard let app, let rows else { return GameOptions(titleID: titleID, settings: [], rejected: rejected, full: fullFlag) }
        let choices = store.choices(titleID: titleID)
        let settings = rows.map { row -> OptionSetting in
            let chosen = validChoice(choices[row.env], for: row, allowing: allowing)
            // The app's own saved choice is what a start from Finder would use; shown while this app has no choice.
            let fromApp = chosen == nil ? app.bundleID.flatMap { saved($0, row.env) }.flatMap { GameOptionsReader.validate($0, for: row) } : nil
            return OptionSetting(env: row.env, kind: row.kind, section: row.section, label: row.label, note: row.note,
                                 defaultValue: row.defaultValue, current: chosen ?? fromApp ?? row.defaultValue, chosen: chosen != nil,
                                 options: row.options, min: row.min, max: row.max, step: row.step, on: row.on, off: row.off,
                                 base: row.base, level: row.level, needs: row.needs)
        }
        return GameOptions(titleID: titleID, settings: settings, rejected: rejected, full: fullFlag)
    }

    /// A stored choice as the game's list takes it now: nil when the row does not offer it any more, it is the default or the
    /// variable is one of the Host's or the runtime's own.
    nonisolated static func validChoice(_ value: String?, for row: LauncherSetting, allowing: (String) -> Bool) -> String? {
        guard let value, allowing(row.env), !ReservedVariables.isReserved(row.env), let canonical = GameOptionsReader.validate(value, for: row),
              canonical != GameOptionsReader.canonical(row.defaultValue, for: row) else { return nil }
        return canonical
    }

    // MARK: launching

    /// What the game is started with besides the launcher's own: the Host-wide file, then the person's choices for this game that
    /// the game's list still offers (a stale or reserved one is left out), the Host's own variables in neither.
    func launchEnvironment(for app: GameApp) async -> [String: String] {
        let store = optionsStore, allowing = config.settableOption, url = app.url, titleID = app.titleID
        // The store's lock is held across its file sync: read the choices off the actor.
        let choices = await Task.detached(priority: .userInitiated) { () -> [String: String] in
            let stored = store.choices(titleID: titleID)
            guard !stored.isEmpty, let rows = GameOptionsReader.read(bundle: url, allowing: allowing) else { return [:] }
            var out: [String: String] = [:]
            for row in rows { if let value = HostService.validChoice(stored[row.env], for: row, allowing: allowing) { out[row.env] = value } }
            return out
        }.value
        return Self.launchEnvironment(file: config.gameEnvironment(app.titleID), choices: choices, allowing: allowing)
    }
}
#endif
