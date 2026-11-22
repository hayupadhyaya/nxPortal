#if os(macOS)
import Foundation

/// The part of the system's notification centre the Host uses; the app adapts `UNUserNotificationCenter` to it.
public protocol NotificationCentring: Sendable {
    /// Asks the person for permission; may take as long as the person takes.
    func requestPermission() async -> Bool
    func post(id: String, title: String, body: String) async
    func remove(id: String) async
}

/// `PairingAnnouncing` over a notification centre -> .claude/host.md § app
/// `announce` and `withdraw` only queue the work for a task of its own and return at once: the model awaits them inside its status
/// loop, and the permission question can stay open for ever. No permission, nothing posted, nothing fails.
public final class PairingNotifier: PairingAnnouncing, Sendable {
    private enum Job: Sendable { case announce(String), withdraw }
    private static let notificationID = "pairing-code"
    private let jobs: AsyncStream<Job>.Continuation

    public init(centre: any NotificationCentring, title: String) {
        let (stream, continuation) = AsyncStream.makeStream(of: Job.self, bufferingPolicy: .unbounded)
        jobs = continuation
        // The task holds the stream and the centre, never `self`: dropping the notifier ends it.
        Task {
            var permission: Bool?
            for await job in stream {
                switch job {
                case let .announce(code):
                    if permission == nil { permission = await centre.requestPermission() }  // once, at the first pairing
                    if permission == true { await centre.post(id: Self.notificationID, title: title, body: code) }
                case .withdraw:
                    if permission == true { await centre.remove(id: Self.notificationID) }
                }
            }
        }
    }

    deinit { jobs.finish() }

    public func announce(code: String) async { jobs.yield(.announce(code)) }
    public func withdraw() async { jobs.yield(.withdraw) }
}
#endif
