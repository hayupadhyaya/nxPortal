import Foundation

/// How the play screen says that the picture stopped arriving -> `§ screen-errors`, .claude/client.md § app
public enum TroubleStage: Equatable, Sendable {
    case none, pill, reconnecting, ended(reason: String)

    /// Seconds of silence at which the pill and the blurred picture begin.
    public static let pillAfter: TimeInterval = 1
    public static let reconnectingAfter: TimeInterval = 3

    /// `ended` wins; no silence (nil) or under a second: nothing; a second to three: the pill; three and more: reconnecting.
    public static func at(silence: TimeInterval?, ended: String?) -> TroubleStage {
        if let ended { return .ended(reason: ended) }
        guard let silence, silence >= pillAfter else { return .none }
        return silence >= reconnectingAfter ? .reconnecting : .pill
    }

    /// The picture under the stage, as the spec has it: a multiply (brightness) and a blur; the palette's scrim goes over it
    /// while the stage covers the screen, so the text holds 4.5:1 over any picture (tested).
    public var pictureBrightness: Double {
        switch self { case .none, .pill: 1; case .reconnecting: 0.55; case .ended: 0.40 }
    }
    public var pictureBlur: Double {
        switch self { case .none, .pill: 0; case .reconnecting: 14; case .ended: 18 }
    }
    /// The stage covers the picture (and the screen's own controls): the scrim shows and no menu opens over it.
    public var covers: Bool {
        switch self { case .none, .pill: false; case .reconnecting, .ended: true }
    }
}
