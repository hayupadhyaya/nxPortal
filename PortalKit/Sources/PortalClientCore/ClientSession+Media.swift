import Foundation
import PortalKit

/// Datagrams in and out, the timer, input -> .claude/client.md § session
extension ClientSession {
    static let inputInterval: UInt64 = 8_000_000, keyRetryNs: UInt64 = 100_000_000, pingEveryNs: UInt64 = 100_000_000,
        stallAfterNs: UInt64 = 1_000_000_000
    /// A `repair` is repeated every 35 ms (two frame times at 60) until a restart point is put out; with none 1 s after
    /// the first, a key frame is asked for instead (escalation, the safety net) -> .claude/client.md § repair
    static let repairRetryNs: UInt64 = 35_000_000, escalateNs: UInt64 = 1_000_000_000
    /// `ack`s go out at most 30 a second (always for a key frame and for a repair frame).
    static let ackEveryNs: UInt64 = 33_333_333
    /// No datagram from the Host this long after the media started (pings go out 10 a second): the session ends
    /// (`mediaPathSilent`) -> .claude/client.md § session
    static let mediaPathNs: UInt64 = 2_000_000_000
    /// The round trip the assembler's timings use before the first pong.
    static let defaultRttNs: UInt64 = 4_000_000
    /// The repair timer never sleeps less (no spin when a deadline is now).
    static let repairMinSleepNs: UInt64 = 200_000

    enum SilenceState: Equatable { case live, stalled, ended }

    /// What `silenceNs` and `stallAfterNs` make of the time since the Host was last heard.
    static func silenceState(nowNs: UInt64, lastHeardNs: UInt64, silenceNs: UInt64) -> SilenceState {
        guard nowNs >= lastHeardNs else { return .live }
        let quiet = nowNs - lastHeardNs
        return quiet >= silenceNs ? .ended : quiet >= stallAfterNs ? .stalled : .live
    }

    /// For this long after a recovery, pictures and sound captured before it are dropped (see `heard`).
    static let staleWindowNs: UInt64 = 5_000_000_000

    /// Captured (Host clock) before the link came back, within the window after it: released by a radio that kept it.
    func isStale(captureNs: UInt64, now: UInt64) -> Bool {
        now < staleUntilNs && Int64(bitPattern: captureNs) < staleBeforeHostNs
    }

    var rttNs: UInt64 { tracker.medianRttNs ?? Self.defaultRttNs }

    /// Called once `ready` is sent: the first ping (and the first `rate`) at once, then the timer.
    func startedMedia() {
        lastPingNs = 0
        lastHeardNs = uptimeNs()
        lastRateSampleNs = lastHeardNs
        mediaStartNs = lastHeardNs
        if let r = rate {  // the hello's start rate again (the Host has it from admission; a repeat changes nothing)
            logRate(lastHeardNs, from: 0, to: r.rateBps, why: .start, delivered: 0, produced: 0, floorNs: nil)
            sendRate(lastHeardNs)
        }
        tasks.append(Self.timer(self))
        _ = tick()
    }

    // MARK: rate -> .claude/client.md § rate

    static let rateRepeatNs: UInt64 = 1_000_000_000
    /// A cut goes out 3 times, 30 ms apart (the link is congested when it is sent; the Host ignores a repeat).
    static let cutRepeatNs: UInt64 = 30_000_000, cutRepeats = 2
    /// Frames given up in a stream's first second are not counted for the rate: the first key frame is all there is.
    static let givenUpIgnoredNs: UInt64 = 1_000_000_000

    /// The newest rate; repeated once a second (a lost datagram must not leave the Host at the old one).
    func sendRate(_ now: UInt64) {
        guard let r = rate?.rateBps else { return }
        lastRateSentNs = now
        sendDatagram(.rate(bitsPerSecond: r))
    }

    /// What the link did since the last sample, to the controller; a change goes to the Host at once.
    func rateSample(_ now: UInt64) {
        guard let before = rate?.rateBps else { return }
        let c = assembler.counts
        let known = videoSinceNs.map { now - $0 >= 300_000_000 } == true  // a younger stream's 300 ms are not all its
        let deliveredNow = known ? delivered.bps(now, slots: 6) : 0
        let floor = tracker.rttFloorNs(nowNs: now)
        // Only give-ups 150 ms old with no late fragment since count (a delayed burst is not a shortage).
        let settled = assembler.settledGiveUps(nowNs: now)
        let young = videoSinceNs.map { now - $0 < Self.givenUpIgnoredNs } ?? true
        let sampledGivenUpBefore = sampledGivenUp
        let sample = RateSample(nowNs: now, framesGivenUp: young ? 0 : settled,
                                fragmentsAsked: max(0, c.fragmentsAsked - sampledAsked), fragmentsReceived: fragmentsIn - sampledIn,
                                framesCompleted: framesCompleted - sampledCompleted, deliveredBps: deliveredNow,
                                producedBps: known ? produced.bps(now, slots: 20) : 0,
                                producedRecentBps: known ? produced.bps(now, slots: 6) : 0,
                                bytesReceived: bytesIn - sampledBytes, rttFloorNs: floor, rttNs: rttNs)
        sampledAsked = c.fragmentsAsked; sampledGivenUp = c.framesGivenUp; sampledIn = fragmentsIn; sampledBytes = bytesIn
        sampledCompleted = framesCompleted
        lastRateSampleNs = now
        var s = sample
        s.framesGivenUpRecent = max(0, c.framesGivenUp - sampledGivenUpBefore)
        guard let r = rate?.update(s) else { return }
        logRate(now, from: before, to: r, why: rate?.reason ?? .climb, delivered: deliveredNow, produced: sample.producedBps, floorNs: floor)
        sendRate(now)
        if r < before { cutRepeatsLeft = Self.cutRepeats }
    }

    func logRate(_ now: UInt64, from: UInt32, to: UInt32, why: RateReason, delivered: Double, produced: Double, floorNs: UInt64?) {
        rateChangeSeq += 1
        if rateStartBps == 0 { rateStartBps = to }
        rateLowBps = rateLowBps == 0 ? to : min(rateLowBps, to)
        if rateChanges.count >= 32 { rateChanges.removeFirst() }
        rateChanges.append(RateChange(seq: rateChangeSeq, atSeconds: Double(now &- mediaStartNs) / 1e9, fromBps: from, toBps: to,
                                      why: why, rttMinMs: Double(rate?.rttMinNs ?? 0) / 1e6, rttFloorMs: Double(floorNs ?? 0) / 1e6,
                                      deliveredBps: delivered, producedBps: produced))
    }

    /// Per datagram: two counters and two slot adds; a frame's size (as its fragments tell it) once, at its first.
    func noteVideo(_ f: VideoFragment, _ now: UInt64) {
        tracker.videoDatagram(nowNs: now)
        fragmentsIn += 1
        bytesIn += f.payload.count
        if videoSinceNs == nil { videoSinceNs = now }
        delivered.add(f.payload.count, now)
        if newestFrameSeen.map({ f.frame > $0 }) ?? true {
            newestFrameSeen = f.frame
            let n = Int(f.count), last = f.index + 1 == f.count ? f.payload.count : Wire.maxVideoPayload / 2
            produced.add(n <= 1 ? f.payload.count : (n - 1) * Wire.maxVideoPayload + last, now)
        }
    }

    static let neutralRepeats = 5

    /// Replaces the caller's `seq`; sent at once and re-sent by the timer every 8 ms.
    public func send(_ input: InputState) {
        guard !closed else { return }  // `sendDatagram` drops what has no key yet
        latestInput[input.player] = input
        inputSent[input.player] = 0
        transmit(input)
    }

    private func transmit(_ input: InputState) {
        var s = input
        s.seq = inputSeq
        inputSeq &+= 1
        inputSent[input.player, default: 0] += 1
        sendDatagram(.input(s))
    }

    func sendDatagram(_ d: Datagram) {
        sendObserver?(d)
        guard mediaSealer != nil, let bytes = try? mediaSealer!.seal(type: d.type, body: d.body()) else { return }
        mediaLink?.send(bytes)
    }

    /// Holds the session only while a tick runs, and ends when it is gone or closed.
    private static func timer(_ session: ClientSession) -> Task<Void, Never> {
        Task { [weak session] in
            let clock = ContinuousClock()
            var next = clock.now
            while !Task.isCancelled {
                next += .nanoseconds(inputInterval)
                if next < clock.now { next = clock.now }
                try? await Task.sleep(until: next, clock: clock)
                guard let session, await session.tick() else { return }
            }
        }
    }

    /// False once the session is closed.
    func tick() -> Bool {
        guard !closed else { return false }
        let now = uptimeNs()
        let silence = lastHeardNs == 0 ? .live : Self.silenceState(nowNs: now, lastHeardNs: lastHeardNs, silenceNs: silenceNs)
        if silence == .ended {
            shutdown(final: nil, reason: .silence)  // the Host's close may never arrive -> .claude/client.md § session
            return false
        }
        if !mediaOpened, mediaStartNs != 0, now &- mediaStartNs >= Self.mediaPathNs {
            shutdown(final: nil, reason: .mediaPathSilent)  // control works, media never came -> .claude/client.md § session
            return false
        }
        if !stalled, silence == .stalled {
            stalled = true
            stallsOut.yield(true)
        }
        if lastPingNs == 0 || now - lastPingNs >= Self.pingEveryNs {
            lastPingNs = now
            sendDatagram(.ping(clientNs: now))
        }
        if awaitingKey, now - lastKeyRequestNs >= Self.keyRetryNs { requestKey(now) }
        if let w = repairWait {
            if now - w.firstNs >= Self.escalateNs {
                escalate(now)
            } else if now - w.lastNs >= Self.repairRetryNs {
                sendRepair(now)
            }
        }
        if rate != nil {
            if now - lastRateSampleNs >= RateController.samplePeriodNs { rateSample(now) }
            if now - lastRateSentNs >= Self.rateRepeatNs { sendRate(now) }
            if cutRepeatsLeft > 0, now - lastRateSentNs >= Self.cutRepeatNs { cutRepeatsLeft -= 1; sendRate(now) }
        }
        // A neutral input rests once it has gone out `neutralRepeats` times (loss cover only) -> .claude/client.md § session
        for input in latestInput.values where !(input.isNeutral && inputSent[input.player, default: 0] >= Self.neutralRepeats) {
            transmit(input)
        }
        return true
    }

    /// Counts only once `open()` has started the media.
    func heard(_ now: UInt64) {
        guard lastHeardNs != 0 else { return }
        lastHeardNs = now
        if stalled {
            stalled = false
            stallsOut.yield(false)
            // The stream restarts: what the assembler held is from before the stall (never asked for now), and a
            // fresh picture comes with one key request (the timer repeats it until the key frame is in).
            restartVideo()
            sendRate(now)  // before the key request: the refresh is sized by the newest rate
            requestKeyframe()
            // A radio that kept what it could not deliver releases it now: what was captured before this moment is
            // stale (the ping offset maps the Host's capture clock to ours; no offset yet, no filter).
            if let offset = tracker.clockOffsetNs {
                staleBeforeHostNs = Int64(bitPattern: now) &+ offset
                staleUntilNs = now &+ Self.staleWindowNs
            }
        }
    }

    /// Delta frames are held back until a key frame arrives; a `keyRequest` goes out now (at most one per 100 ms)
    /// and the timer repeats it until the key frame is in. Repair frames are no restart point until a key frame decodes.
    public func requestKeyframe() {
        guard !closed else { return }
        assembler.awaitKeyframe()
        repairWait = nil
        awaitingKey = true
        let now = uptimeNs()
        if now - lastKeyRequestNs >= Self.keyRetryNs { requestKey(now) }
    }

    /// The frame with `captureNs` went to the display at local `atNs` (`uptimeNs()`, taken by the caller)
    /// -> `SessionStats.framesDisplayed`, `p95DisplayMs`.
    public func markDisplayed(captureNs: UInt64, at atNs: UInt64) { tracker.displayed(captureNs: captureNs, nowNs: atNs) }

    /// The player decoded `f` (the decoder's callback reported success): it is acknowledged to the Host, at most 30 a
    /// second and always for a key frame or a repair frame; a key frame makes repair frames restart points again.
    /// Never call it for a frame that was assembled but not decoded -> .claude/client.md § repair
    public func frameDecoded(_ f: AssembledFrame) {
        guard !closed else { return }
        if f.key {
            tracker.keyDecoded()
            assembler.acceptsRepair = true
        }
        let now = uptimeNs()
        guard f.key || f.repair || now &- lastAckNs >= Self.ackEveryNs else { return }
        lastAckNs = now
        tracker.ackSent()
        sendDatagram(.ack(frame: f.frame))
    }

    /// The player could not decode `f` (or its decoder was made again): a key frame now, and no repair frame counts as a
    /// restart point until a key frame decodes.
    public func decodeFailed(_ f: AssembledFrame) {
        guard !closed else { return }
        tracker.decodeFailed()
        requestKeyframe()
    }

    /// A fresh video stream: new assembler (awaits a key frame), no key wait, no last frame; not counted as skipped.
    func restartVideo() {
        assembler.restart()  // the old stream's holes and counts go with it (and repair frames are no restart point)
        sampledAsked = 0; sampledGivenUp = 0; videoSinceNs = nil; newestFrameSeen = nil
        repairWait = nil
        givenUpSeen = 0  // the new assembler's counts start at 0
        awaitingKey = false
        lastGoodFrame = 0
        tracker.videoRestarted()
    }

    /// The first `repair` of a wait, or a repeat.
    private func sendRepair(_ now: UInt64) {
        repairWait = (repairWait?.firstNs ?? now, now, (repairWait?.sent ?? 0) + 1)
        tracker.repairSent()
        sendDatagram(.repair(lastGoodFrame: lastGoodFrame))
    }

    /// No restart point in time: a key frame is asked for (the repair frames may be lost or the game cannot make them).
    private func escalate(_ now: UInt64) {
        tracker.escalated()
        requestKeyframe()
    }

    private func requestKey(_ now: UInt64) {
        awaitingKey = true
        lastKeyRequestNs = now
        tracker.keyRequestSent()
        sendDatagram(.keyRequest(lastGoodFrame: lastGoodFrame))
    }

    func datagram(_ bytes: Data) {
        guard !closed else { return }
        let index = datagramIndex
        datagramIndex += 1
        if let keep = datagramFilter, !keep(index) { return }
        guard bytes.count <= Wire.maxDatagram, mediaOpener != nil,
              let (type, body) = try? mediaOpener!.open(bytes),
              let d = try? Datagram(type: type, body: body) else { return }
        let now = uptimeNs()
        heard(now)
        mediaOpened = true
        newestHostNs = now
        switch d {
        case let .video(fragment): video(fragment, now)
        case let .audio(seq, captureNs, pcm):
            if tracker.audioArrived(seq: seq), !isStale(captureNs: captureNs, now: now) { audioOut.yield(AudioBlock(seq: seq, captureNs: captureNs, pcm: pcm)) }
        case let .pong(sendNs, hostNs): tracker.pong(sendNs: sendNs, receiveNs: now, hostNs: hostNs)
        case let .hostStats(h): tracker.hostStats(h)
        case let .load(l): tracker.load(l, atNs: now)
        default: break
        }
        if case .video = d {} else if assembler.hasOpenTail {
            // Any Host datagram proves the link alive: a tail quiet for 4 ms before it is lost, not stalled.
            handle(assembler.tick(nowNs: now, rttNs: rttNs, heardNs: now), now)
            armRepair()
        }
    }

    func video(_ fragment: VideoFragment, _ now: UInt64) {
        if let drop = videoDrop, drop(fragment) { return }
        noteVideo(fragment, now)
        // A restart point on its way holds the repeat (a key frame takes longer than 35 ms to arrive; asking again would
        // make the game send another); the repeat resumes 35 ms after its fragments stop.
        if repairWait != nil, fragment.key || fragment.repair, fragment.frame > lastGoodFrame { repairWait?.lastNs = now }
        if isStale(captureNs: fragment.captureNs, now: now) { return }  // a key frame from before the stall is not the answer to the refresh
        handle(assembler.push(fragment, nowNs: now), now)
        armRepair()
    }

    /// One timer task while the assembler has something missing; it ends when nothing is (no task per datagram).
    /// A deadline earlier than the one it sleeps to (a hole seen after its frame's first ask) replaces it.
    private func armRepair() {
        guard !closed, let next = assembler.nextTickNs(rttNs: rttNs, heardNs: newestHostNs) else { return }
        if repairTimer != nil {
            guard next &+ Self.repairMinSleepNs < repairDueNs else { return }
            repairTimer?.cancel()
        }
        repairGeneration &+= 1
        let generation = repairGeneration
        repairDueNs = next
        repairTimer = Task { [weak self] in
            while !Task.isCancelled, let due = await self?.repairStep(generation) {
                let now = uptimeNs()
                // A tight tolerance: the default lets the system coalesce the wake by milliseconds.
                try? await Task.sleep(for: .nanoseconds(max(due > now ? due - now : 0, Self.repairMinSleepNs)),
                                      tolerance: .microseconds(100), clock: .continuous)
            }
        }
    }

    /// Ticks the assembler; the next time it is due, or nil (the timer ends) when nothing is missing.
    func repairStep(_ generation: Int) -> UInt64? {
        guard generation == repairGeneration else { return nil }  // replaced: the newer timer ticks
        guard !closed else { repairTimer = nil; return nil }
        let now = uptimeNs()
        handle(assembler.tick(nowNs: now, rttNs: rttNs, heardNs: newestHostNs), now)
        guard let next = assembler.nextTickNs(rttNs: rttNs, heardNs: newestHostNs) else { repairTimer = nil; return nil }
        repairDueNs = next
        return next
    }

    func handle(_ events: [AssemblerEvent], _ now: UInt64) {
        // While waiting, a frame given up is in practice the restart point on its way (the other frames are dropped unasked;
        // a malformed fragment also gives up its frame): `repair` is asked again at once, not when the hold on its
        // fragments runs out.
        let givenUp = assembler.counts.framesGivenUp
        if repairWait != nil, givenUp > givenUpSeen { sendRepair(now) }
        givenUpSeen = givenUp
        for e in events {
            switch e {
            case let .frame(f):
                if f.key { awaitingKey = false }
                if f.key || f.repair { repairWait = nil }  // a restart point is out
                lastGoodFrame = f.frame
                tracker.frameShown(f, arrivalNs: now)
                framesCompleted += 1
                framesOut.yield(f)
            case let .nack(frame, indices):
                sendDatagram(.nack(frame: frame, indices: indices))
            case .refresh:
                rateSample(now)  // a frame given up is trouble now: a cut goes before the request
                // A repair frame where the decoder can take one (a key frame decoded since it last started), else a key frame.
                if assembler.acceptsRepair, !awaitingKey {
                    if repairWait == nil { sendRepair(now) }
                } else {
                    requestKey(now)
                }
            }
        }
    }
}

/// Bytes per 50 ms slot, the newest `slots`; a rate over the newest k of them (the current one partly) -> .claude/client.md § rate
struct SlotRate {
    static let slotNs: UInt64 = 50_000_000
    private var bytes: [Int]
    /// The newest slot's number (time / 50 ms).
    private var newest: UInt64 = 0

    init(slots: Int) { bytes = [Int](repeating: 0, count: slots) }

    /// Clears the slots that passed since the newest.
    private mutating func advance(_ now: UInt64) {
        let slot = now / Self.slotNs
        guard slot > newest else { return }
        var k = newest + 1
        while k <= slot && k <= newest + UInt64(bytes.count) {
            bytes[Int(k % UInt64(bytes.count))] = 0
            k += 1
        }
        newest = slot
    }

    mutating func add(_ n: Int, _ now: UInt64) {
        advance(now)
        bytes[Int(newest % UInt64(bytes.count))] += n
    }

    /// Over this slot and the `slots - 1` before, bit/s.
    mutating func bps(_ now: UInt64, slots: Int) -> Double {
        advance(now)
        let k = min(slots, bytes.count)
        var sum = 0
        for i in 0..<k where newest >= UInt64(i) { sum += bytes[Int((newest - UInt64(i)) % UInt64(bytes.count))] }
        let span = Double(UInt64(k - 1) * Self.slotNs + now % Self.slotNs) / 1e9
        return span > 0 ? Double(sum) * 8 / span : 0
    }
}

extension InputState {
    /// No button, no stick, no motion.
    var isNeutral: Bool { buttons == 0 && lx == 0 && ly == 0 && rx == 0 && ry == 0 && motion == nil }
}
