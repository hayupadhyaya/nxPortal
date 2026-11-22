import Foundation
import PortalKit
import PortalClientCore

extension DecodeReport {
    /// `run` with the product's decoder.
    public static func run(frames: AsyncStream<AssembledFrame>, session: ClientSession, decoder: VideoDecoder) async {
        await run(frames: frames, session: session, decode: { decoder.decode($0) })
    }
}
