import Foundation
import AVFoundation
import os
import PortalClientCore

/// Plays decoded sound blocks through a jitter buffer -> .claude/client.md § sound
public final class AudioOutput: @unchecked Sendable {
    /// Render-thread state: the scratch is allocated once and only touched by the render block.
    private final class Render: @unchecked Sendable {
        static let scratchFrames = 4096
        struct State: Sendable { var buffer: JitterBuffer; var pulledFrames = 0 }
        let state: OSAllocatedUnfairLock<State>
        let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: scratchFrames * 2)
        init(_ b: JitterBuffer) { state = OSAllocatedUnfairLock(initialState: State(buffer: b)) }
        deinit { scratch.deallocate() }

        func render(_ frameCount: Int, _ list: UnsafeMutablePointer<AudioBufferList>) {
            let bufs = UnsafeMutableAudioBufferListPointer(list)
            guard bufs.count >= 2,
                  let l = bufs[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = bufs[1].mData?.assumingMemoryBound(to: Float.self) else { return }
            var done = 0
            while done < frameCount {
                let n = min(Self.scratchFrames, frameCount - done)
                state.withLock { $0.buffer.pull(frames: n, into: scratch); $0.pulledFrames += n }
                for i in 0..<n {
                    l[done + i] = Float(scratch[2 * i]) / 32768
                    r[done + i] = Float(scratch[2 * i + 1]) / 32768
                }
                done += n
            }
        }
    }

    private let render: Render
    /// Automatic mode: the target follows the arrivals. Touched by `push` and `stop` only, never by the render thread.
    private struct Auto: Sendable { var target = SoundBufferTarget(); var seenUnderruns = 0; var appliedMs = SoundBufferTarget.startMs }
    private let auto: OSAllocatedUnfairLock<Auto>?
    let engine = AVAudioEngine()
    private let stateLock = NSLock()
    private var source: AVAudioSourceNode?
    /// Started and not stopped by the caller: notifications restart the output only then.
    private var wanted = false
    private var observers: [NSObjectProtocol] = []

    /// The jitter buffer's maximum: the target plus 50 ms, never under 100 ms -> .claude/client.md § sound
    static func maxFrames(targetFrames: Int) -> Int { max(4800, targetFrames + 2400) }

    /// `automatic`: the buffer follows the measured arrival gaps (`bufferMs` is ignored); the maximum is sized once for 100 ms.
    public init(bufferMs: Int = 25, automatic: Bool = false) {
        let ms = automatic ? SoundBufferTarget.startMs : min(100, max(10, bufferMs))
        let maxMs = automatic ? SoundBufferTarget.maxMs : ms
        render = Render(JitterBuffer(targetFrames: ms * 48, maxFrames: Self.maxFrames(targetFrames: maxMs * 48)))
        auto = automatic ? OSAllocatedUnfairLock(initialState: Auto()) : nil
    }

    deinit { removeObservers() }

    /// Starts, or restarts when the engine is no longer running. Harmless when already running.
    public func start() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        wanted = true
        installObservers()
        // A failure keeps `wanted` and the observers: an interruption's end or a route change tries again.
        try bringUpLocked()
    }

    /// Stops and resets the jitter buffer (empty, filling, no last `seq`, counters zero) so a new stream can start at any `seq`.
    public func stop() {
        stateLock.lock(); defer { stateLock.unlock() }
        wanted = false
        removeObservers()
        engine.stop()
        if let node = source { engine.detach(node) }
        source = nil
#if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)  // other apps' sound resumes
#endif
        let automatic = auto != nil
        render.state.withLock { $0.buffer.reset(); if automatic { $0.buffer.setTarget(frames: SoundBufferTarget.startMs * 48) } }
        auto?.withLock { $0 = Auto() }
    }

    /// Caller holds `stateLock`. Sets up the session, attaches the node once, starts the engine if it is not running.
    private func bringUpLocked() throws {
        if failNextStartForTesting { failNextStartForTesting = false; throw NSError(domain: "AudioOutputTests", code: 1) }
#if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
#endif
        let created = source == nil
        if created {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
            let render = self.render
            let node = AVAudioSourceNode(format: format) { _, _, frameCount, list in
                render.render(Int(frameCount), list)
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            source = node
        }
        guard !engine.isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            if created, let node = source {
                engine.disconnectNodeOutput(node)
                engine.detach(node)
                source = nil
            }
            throw error
        }
    }

    /// A failed restart is dropped here; the next notification or `start()` tries again.
    private func restart() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard wanted else { return }
        try? bringUpLocked()
    }

    /// Caller holds `stateLock`.
    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restart()
        })
#if os(iOS) || os(tvOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended { self?.restart() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            self?.restart()
        })
#endif
    }

    private func removeObservers() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
    }

    /// Silence until the buffer has filled again; counters stay (a stall of the link, not a new stream).
    public func flush() { render.state.withLock { $0.buffer.flush() } }

    /// `nowNs`: the arrival time (uptime clock); only automatic mode reads it.
    public func push(_ block: AudioBlock, atNs nowNs: UInt64 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) {
        let (taken, underruns) = render.state.withLock { ($0.buffer.push(seq: block.seq, pcm: block.pcm), $0.buffer.underruns) }
        guard let auto else { return }
        // The wanted size is worked out outside the render lock (a sort); only the new target goes in under it.
        let change: Int? = auto.withLock { a in
            if underruns < a.seenUnderruns { a.seenUnderruns = underruns }   // the buffer was reset
            while a.seenUnderruns < underruns { a.target.underrun(atNs: nowNs); a.seenUnderruns += 1 }
            if taken { a.target.arrival(atNs: nowNs) }   // a repeat is not an arrival
            let ms = a.target.wantedMs(atNs: nowNs)
            guard ms != a.appliedMs else { return nil }
            a.appliedMs = ms
            return ms
        }
        if let ms = change { render.state.withLock { $0.buffer.setTarget(frames: ms * 48) } }
    }

    /// The jitter buffer's target now, ms.
    public var targetMs: Int { render.state.withLock { $0.buffer.targetFrames / 48 } }

    /// How much sound is waiting in the buffer now, ms.
    public var levelMs: Int { render.state.withLock { $0.buffer.bufferedFrames / 48 } }

    var bufferedFrames: Int { render.state.withLock { $0.buffer.bufferedFrames } }
    /// The jitter buffer's maximum (tests).
    var maxFrames: Int { render.state.withLock { $0.buffer.maxFrames } }
    /// Frames the render block has pulled since creation (tests).
    var pulledFrames: Int { render.state.withLock { $0.pulledFrames } }
    /// The next bring-up throws before touching the engine (tests).
    var failNextStartForTesting = false
    /// Stops the engine without telling `AudioOutput`, as an interruption would (tests).
    func simulateEngineStopForTesting() { engine.stop() }

    public var underruns: Int { render.state.withLock { $0.buffer.underruns } }
    public var lostBlocks: Int { render.state.withLock { $0.buffer.lostBlocks } }
}
