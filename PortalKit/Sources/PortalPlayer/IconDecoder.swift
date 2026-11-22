import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Decodes icons for the library's tiles off the main actor: one decode per key however many tiles ask, at most `limit`
/// at once, a decode not yet begun is dropped when every asker has gone (its tile left the screen), and the result is
/// kept (at most `cacheLimit` icons and `byteLimit` bytes, newest first; all of it goes on a memory warning, `trim()`). The key names the icon's content and size (title, hash, pixels) -> .claude/client.md § app
public final class IconDecoder: @unchecked Sendable {  // every mutable field is behind `lock`
    public typealias Decode = @Sendable (Data, Int) -> CGImage?
    public static let defaultLimit = 4
    /// About 48 MB of pixels: a few dozen tiles at Apple TV size.
    public static let defaultByteLimit = 48 * 1024 * 1024

    private final class Entry: @unchecked Sendable {  // `users` is read and written under the decoder's lock
        let id: UUID
        let task: Task<CGImage?, Never>
        var users = 1
        init(_ id: UUID, _ task: Task<CGImage?, Never>) { self.id = id; self.task = task }
    }

    private let lock = NSLock()
    private let limit: Int
    private let cacheLimit: Int
    private let decode: Decode
    private let byteLimit: Int
    private var cache: [String: CGImage] = [:]
    private var order: [String] = []
    private var bytes = 0
    private var warning: NSObjectProtocol?
    private var inFlight: [String: Entry] = [:]
    private var running = 0
    private var waiters: [(id: UUID, resume: CheckedContinuation<Bool, Never>)] = []

    public init(limit: Int = IconDecoder.defaultLimit, cacheLimit: Int = 128, byteLimit: Int = IconDecoder.defaultByteLimit,
                decode: @escaping Decode = { AmbientImage.thumbnail($0, maxPixel: max(64, $1)) }) {
        self.limit = max(1, limit)
        self.cacheLimit = cacheLimit
        self.byteLimit = max(1, byteLimit)
        self.decode = decode
        #if canImport(UIKit) && !os(watchOS)
        warning = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.trim()
        }
        #endif
    }

    deinit { if let warning { NotificationCenter.default.removeObserver(warning) } }

    /// Decodes in flight (tests).
    var pendingCount: Int { lock.withLock { inFlight.count } }
    /// What the kept icons weigh (tests).
    var cachedBytes: Int { lock.withLock { bytes } }

    /// Drops every kept icon (a memory warning); tiles that still show one keep their own reference.
    public func trim() {
        lock.withLock { cache = [:]; order = []; bytes = 0 }
    }

    /// The icon when it is already decoded (no decoding).
    public func cached(_ key: String) -> CGImage? { lock.withLock { cache[key] } }

    /// The decoded icon; nil when it cannot be decoded or this ask was cancelled before its decode began.
    public func image(key: String, png: Data, pixels: Int) async -> CGImage? {
        let entry: Entry = lock.withLock {
            if let hit = cache[key] { return Entry(UUID(), Task { hit }) }
            // An entry whose every asker went is cancelled and only waits to be removed: a new ask never joins it.
            if let e = inFlight[key], e.users > 0 { e.users += 1; return e }
            let id = UUID()
            let e = Entry(id, Task { [self] in await run(key: key, entry: id, png: png, pixels: pixels) })
            inFlight[key] = e
            return e
        }
        return await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            let nobodyWants = lock.withLock { () -> Bool in entry.users -= 1; return entry.users <= 0 }
            // Outside the lock: cancelling runs the decode task's own cancellation handler, which takes it.
            if nobodyWants { entry.task.cancel() }  // the decode runs only while somebody still wants it
        }
    }

    private func run(key: String, entry: UUID, png: Data, pixels: Int) async -> CGImage? {
        defer { lock.withLock { if inFlight[key]?.id == entry { inFlight[key] = nil } } }
        guard await acquire() else { return nil }
        defer { release() }
        if Task.isCancelled { return nil }
        let made = decode(png, pixels)
        if let made {
            lock.withLock {
                if let old = cache[key] { bytes -= Self.cost(old); order.removeAll { $0 == key } }
                cache[key] = made
                order.append(key)
                bytes += Self.cost(made)
                // Oldest first, the newest always stays (one icon larger than the budget is still shown).
                while order.count > 1, order.count > cacheLimit || bytes > byteLimit {
                    let gone = order.removeFirst()
                    if let image = cache.removeValue(forKey: gone) { bytes -= Self.cost(image) }
                }
            }
        }
        return made
    }

    private static func cost(_ image: CGImage) -> Int { image.width * image.height * 4 }

    /// A cancel that comes before the body runs has set the task's flag, which the body reads under the lock; one that
    /// comes after finds the waiter (or nothing to undo: the slot was granted and `run` checks the flag).
    private func acquire() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                lock.lock()
                defer { lock.unlock() }
                if Task.isCancelled { c.resume(returning: false); return }
                if running < limit { running += 1; c.resume(returning: true) } else { waiters.append((id, c)) }
            }
        } onCancel: {
            let waiting: CheckedContinuation<Bool, Never>? = lock.withLock {
                guard let i = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: i).resume
            }
            waiting?.resume(returning: false)
        }
    }

    private func release() {
        let next: CheckedContinuation<Bool, Never>? = lock.withLock {
            if waiters.isEmpty { running -= 1; return nil }
            return waiters.removeFirst().resume  // the slot is handed over
        }
        next?.resume(returning: true)
    }
}
