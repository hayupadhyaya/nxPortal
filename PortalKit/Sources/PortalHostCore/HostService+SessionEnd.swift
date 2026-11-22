#if os(macOS)
import Foundation
import Network
import os

/// Why a live session ended, as the session-end line names it -> .claude/host.md § session-end
public enum SessionEndCause: String, Sendable {
    /// The device closed the connection or said `bye`.
    case clientClosed = "client-closed"
    /// Nothing from the device for the silence limit.
    case clientSilent = "client-silent"
    /// The Host stopped.
    case hostStop = "host-stop"
    /// The same device opened a new session.
    case replaced
    /// A control frame that did not frame, open or decode.
    case controlError = "control-error"
    /// The Host's owner removed the device.
    case deviceRemoved = "device-removed"
}

/// Whether the device's datagrams arrived at the address its control connection reached.
public enum MediaAddressMatch: String, Sendable { case same, differs, unknown }

/// One ended live session, counted from its `welcome`; no addresses, no names.
public struct SessionEndReport: Equatable, Sendable {
    /// The device's tag (`PairedPeer.tag`), never its name.
    public let device: String
    /// From admission to the end.
    public let seconds: Double
    public let cause: SessionEndCause
    /// Datagrams from the device that opened; datagrams the sender put on the wire; sends the socket refused.
    public let datagramsIn: Int, datagramsOut: Int, sendFailures: Int
    /// From `welcome` to the first datagram that opened; nil when none did.
    public let firstDatagramMs: Int?
    public let mediaAddress: MediaAddressMatch

    /// `session end: <device> after <s> s, by <cause>, datagrams in <n> out <n>, send failures <n>,
    /// first datagram after <ms|never> ms, media local address <same|differs|unknown> from control`
    public var line: String {
        let first = firstDatagramMs.map { "\($0) ms" } ?? "never"
        return "session end: \(device) after \(String(format: "%.1f", seconds)) s, by \(cause.rawValue), "
            + "datagrams in \(datagramsIn) out \(datagramsOut), send failures \(sendFailures), "
            + "first datagram after \(first), media local address \(mediaAddress.rawValue) from control"
    }
}

/// What a session's media path did, kept from `welcome` to its end.
struct SessionCounters {
    let welcomedAt: Date
    var admittedAt: Date?
    var datagramsIn = 0
    var firstDatagramAt: Date?

    mutating func datagramOpened(at now: Date) {
        datagramsIn += 1
        if firstDatagramAt == nil { firstDatagramAt = now }
    }
}

extension HostService {
    static let sessionLog = Logger(subsystem: "nxportal", category: "session")

    /// The live link `id` ends by `cause`: its line goes to `sessionEnds` and the log (call before the sender detaches).
    func reportEnd(_ id: Int, by cause: SessionEndCause) {
        guard let link = links[id], let s = link.session else { return }
        let now = self.now()
        let c = s.counters
        let totals = sender.sessionTotals
        let report = SessionEndReport(
            device: s.peer.tag, seconds: now.timeIntervalSince(c.admittedAt ?? c.welcomedAt), cause: cause,
            datagramsIn: c.datagramsIn, datagramsOut: totals.sent, sendFailures: totals.failed,
            firstDatagramMs: c.firstDatagramAt.map { Int(($0.timeIntervalSince(c.welcomedAt) * 1000).rounded()) },
            mediaAddress: Self.match(media: s.address?.local, control: s.controlLocal))
        let line = report.line
        Self.sessionLog.notice("\(line, privacy: .public)")
        sessionEndsOut.yield(report)
    }

    /// The media arrival address against the control connection's local address (an IPv4-mapped one read as IPv4).
    static func match(media: LocalAddress?, control: NWEndpoint?) -> MediaAddressMatch {
        guard let media, case let .hostPort(host, _)? = control else { return .unknown }
        let controlIP: Data
        switch host {
        case let .ipv4(a): controlIP = a.rawValue
        case let .ipv6(a): controlIP = a.asIPv4?.rawValue ?? a.rawValue
        default: return .unknown
        }
        var mediaIP = media.ip
        if mediaIP.count == 16, let a = IPv6Address(mediaIP), let v4 = a.asIPv4 { mediaIP = v4.rawValue }
        return mediaIP == controlIP ? .same : .differs
    }
}
#endif
