#if os(macOS)
import Foundation
import PortalHostCore

/// What the app writes to its log (and, in an automated run, to stdout) -> .claude/host.md § app
public enum HostEvent: Equatable, Sendable {
    case listening(port: UInt16)
    /// Every status the service publishes (a failure comes as `.failed`).
    case status(HostStatus)
    /// A `session end: …` line exactly as the Host core produces it (`SessionEndReport.line`).
    case sessionEnd(String)
    /// The service is not serving (once per reason until it runs again).
    case failed(String)
    /// A line the model passes on as it is (a game that did not exit after SIGKILL).
    case note(String)
}

public enum HostEventLine {
    /// The line for `event`, as `portal-hostd` prints it. `showCode: false` leaves a pairing code out (the log file never has one).
    public static func text(_ event: HostEvent, showCode: Bool) -> String {
        switch event {
        case let .listening(port): return "listening on port \(port)"
        case let .sessionEnd(line), let .note(line): return line
        case let .failed(text): return "failed (\(text))"
        case let .status(s): return s.logText(showCode: showCode)
        }
    }
}
#endif
