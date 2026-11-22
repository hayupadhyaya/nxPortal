import AVFoundation
import PortalClientCore
import PortalPlayer
import SwiftUI
import UIKit

/// A view whose layer is an `AVSampleBufferDisplayLayer`, aspect-fit.
final class PictureUIView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    /// Pictures wait here between arrival and the display refresh (`smooth`) or pass straight through (`immediate`).
    private var pacer = FramePacer<DecodedFrame>(mode: .immediate)
    private var link: CADisplayLink?
    private weak var model: ClientModel?
    private var countedSeconds = 0.0
    private var lastTimestamp = 0.0
    /// Reads times only (arrival against refresh): it changes nothing about what is shown or when -> .claude/client.md § recorder
    private var meter = ArrivalMeter()

    /// Told the interface orientation whenever the view lays out (iOS).
    weak var controller: ControllerInput? { didSet { reportOrientation() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Starts the display link (one tick per refresh, at most 60 a second: the stream's own rate).
    func startPacing(model: ClientModel) {
        stopPacing()
        self.model = model
        pacer = FramePacer(mode: model.settings.picturePacing)
        countedSeconds = 0
        lastTimestamp = 0
        meter.reset()
        model.displayMaxHz = window?.screen.maximumFramesPerSecond
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)  // never 30: that would drop half the stream
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stopPacing() {
        link?.invalidate()
        link = nil
        pacer.reset()
    }

    /// A decoded picture arrived (main queue): shown now (`immediate`) or at the next refresh (`smooth`).
    func arrived(_ frame: DecodedFrame) {
        guard link != nil else { return }  // not playing (a late picture from the decode task)
        meter.arrival(atNs: uptimeNs())
        followMode()
        if let now = pacer.push(frame) { present(now) }
    }

    fileprivate func refresh(_ link: CADisplayLink) {
        // The link's clock is the one `uptimeNs()` reads (mach absolute time).
        meter.refresh(atNs: UInt64(max(0, link.timestamp) * 1e9), intervalMs: (link.targetTimestamp - link.timestamp) * 1000)
        followMode()
        if let next = pacer.refresh() { present(next) }
        if lastTimestamp > 0 {
            let step = link.timestamp - lastTimestamp
            if step > 0.25 {
                let lost = pacer.takeCounts()  // the link was paused: no rate from a window with a hole in it, but its late pictures count
                model?.displayCounts(shown: lost.shown, late: lost.late, empty: lost.empty, seconds: 0)
                _ = meter.take()
                meter.linkPaused()
                countedSeconds = 0
            } else {
                countedSeconds += step
            }
        }
        lastTimestamp = link.timestamp
        if countedSeconds >= 1 {
            let counts = pacer.takeCounts()
            model?.displayCounts(shown: counts.shown, late: counts.late, empty: counts.empty, seconds: countedSeconds,
                                 pending: pacer.pending, phase: meter.take())
            countedSeconds = 0
        }
    }

    private func followMode() {
        if let wanted = model?.settings.picturePacing, wanted != pacer.mode { pacer.mode = wanted }
    }

    /// Every enqueue, whichever path, is marked with the time right after it.
    private func present(_ frame: DecodedFrame) {
        guard show(frame) else { return }
        model?.picturesShown(captureNs: frame.captureNs, at: uptimeNs())
    }

    /// Enqueues one decoded picture (a failed renderer is flushed first); false when nothing was enqueued.
    func show(_ frame: DecodedFrame) -> Bool {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        guard let sample = DisplaySample.make(frame.pixelBuffer) else { return false }
        renderer.enqueue(sample)
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportOrientation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let hz = window?.screen.maximumFramesPerSecond { model?.displayMaxHz = hz }
        reportOrientation()
    }

    private func reportOrientation() {
        #if os(iOS)
        if let orientation = window?.windowScene?.interfaceOrientation { controller?.interfaceOrientation = orientation.rawValue }
        #endif
    }
}

/// Holds the view weakly so the display link (which retains its target) does not keep it alive.
@MainActor private final class DisplayLinkProxy: NSObject {
    private weak var view: PictureUIView?
    init(_ view: PictureUIView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); return }  // the view is gone: stop ticking
        view.refresh(link)
    }
}

struct PictureView: UIViewRepresentable {
    let view: PictureUIView
    func makeUIView(context: Context) -> PictureUIView { view }
    func updateUIView(_ uiView: PictureUIView, context: Context) {}
}
