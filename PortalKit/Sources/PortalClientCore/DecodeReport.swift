import Foundation
import PortalKit

/// What a player tells the session about each frame it decodes -> .claude/client.md § repair
/// The one rule, for the player's pump, `portal-fakeclient --decode` and the scenario harness.
public enum DecodeReport {
    /// One frame through `decode`: a picture -> `picture`, then `decoded` (the session acknowledges it to the Host);
    /// nil (not decodable) -> `failed` (the session asks for a key frame), `picture` not called.
    public static func step<Picture>(_ f: AssembledFrame, decode: (AssembledFrame) -> Picture?,
                                     picture: (Picture) -> Void = { _ in },
                                     decoded: @Sendable (AssembledFrame) async -> Void,
                                     failed: @Sendable (AssembledFrame) async -> Void) async {
        if let p = decode(f) {
            picture(p)
            await decoded(f)
        } else { await failed(f) }
    }

    /// Every frame of `frames` through `decode` and reported to `session`; returns when the stream ends.
    public static func run<Picture>(frames: AsyncStream<AssembledFrame>, session: ClientSession,
                                    decode: (AssembledFrame) -> Picture?) async {
        for await f in frames {
            await step(f, decode: decode, decoded: { await session.frameDecoded($0) }, failed: { await session.decodeFailed($0) })
        }
    }
}
