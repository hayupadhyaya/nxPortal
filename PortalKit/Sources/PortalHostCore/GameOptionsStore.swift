#if os(macOS)
import Foundation
import PortalKit

/// The choices a paired device makes per game, kept on the Mac as text by variable name: `{"version":1,"titles":{<title ID>:
/// {<variable>: <value>}}}` in a 0600 file inside a 0700 folder -> .claude/host.md § options
/// Only values that differ from the game's tested default are kept. A file that does not read is treated as empty and is
/// not touched until the next deliberate `set` (the old one is then kept beside it as `<name>.corrupt`).
final class GameOptionsStore: @unchecked Sendable {  // `titles` and `corrupt` are behind `lock`
    static let maxChoicesPerTitle = OptionLimits.maxSettings, maxTitles = 64, maxTitleBytes = 32
    /// What the store reads and what it will write: one cap, and the limits above fit under it (`GameOptionsStoreTests`), so a
    /// file the store wrote is never one it reads as corrupt.
    static let maxFileBytes = 4 << 20

    private struct File: Codable { var version: Int?, titles: [String: [String: String]] }

    private let lock = NSLock()
    private let url: URL?
    private var titles: [String: [String: String]] = [:]
    private var corrupt = false

    /// `nil` keeps the choices in memory only.
    init(fileURL: URL?) {
        url = fileURL
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = Self.readFile(url), let file = try? JSONDecoder().decode(File.self, from: data) else { corrupt = true; return }
        // A file that decodes can still hold what no set would have written: keep only what a set could.
        for (title, values) in file.titles.sorted(by: { $0.key < $1.key }) where Self.isTitle(title) && titles.count < Self.maxTitles {
            let kept = values.filter { Self.isChoice(env: $0.key, value: $0.value) }.prefix(Self.maxChoicesPerTitle)
            if !kept.isEmpty { titles[title] = Dictionary(uniqueKeysWithValues: Array(kept)) }
        }
    }

    var titleCount: Int { lock.withLock { titles.count } }

    func choices(titleID: String) -> [String: String] { lock.withLock { titles[titleID] ?? [:] } }

    /// Keeps `value` for `env` of `titleID` (nil, or a value equal to `defaultValue`, removes it). False: nothing changed,
    /// because the name, the title or the value is not one a set may take, a limit is reached, or the file cannot be written.
    @discardableResult
    func set(_ value: String?, env: String, titleID: String, default defaultValue: String? = nil) -> Bool {
        guard Self.isTitle(titleID), GameOptionsReader.isEnvName(env) else { return false }
        if let value, !GameOptionsReader.isPlainValue(value) { return false }
        let kept = value == defaultValue ? nil : value
        return lock.withLock {
            var next = titles
            var mine = next[titleID] ?? [:]
            if let kept {
                if mine[env] == nil {
                    guard mine.count < Self.maxChoicesPerTitle, next[titleID] != nil || next.count < Self.maxTitles else { return false }
                }
                mine[env] = kept
            } else {
                guard mine.removeValue(forKey: env) != nil else { return true }
            }
            next[titleID] = mine.isEmpty ? nil : mine
            return commit(next)
        }
    }

    /// A choice for `titleID` would be refused for want of room: it has none yet and the store keeps `maxTitles` games already.
    func isFull(forNew titleID: String) -> Bool { lock.withLock { titles[titleID] == nil && titles.count >= Self.maxTitles } }

    func reset(titleID: String) {
        lock.withLock {
            guard titles[titleID] != nil else { return }
            var next = titles
            next[titleID] = nil
            _ = commit(next)
        }
    }

    // MARK: file

    private static func isTitle(_ s: String) -> Bool { TitleID.isWellFormed(s) }

    private static func isChoice(env: String, value: String) -> Bool { GameOptionsReader.isEnvName(env) && GameOptionsReader.isPlainValue(value) }

    private static func readFile(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxFileBytes else { return nil }
        var data = Data(), chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= maxFileBytes {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 { return nil }
            if n == 0 { break }
            data.append(contentsOf: chunk[0..<n])
        }
        return data.count <= maxFileBytes ? data : nil
    }

    /// Writes `next` (when there is a file) and only then makes it the state: a change that is not saved is not kept.
    private func commit(_ next: [String: [String: String]]) -> Bool {
        if let url, !write(next, to: url) { return false }
        titles = next
        corrupt = false
        return true
    }

    private func write(_ state: [String: [String: String]], to url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path) {
            do { try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { return false }
            chmod(folder.path, 0o700)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(File(version: 1, titles: state)), data.count <= Self.maxFileBytes else { return false }
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        var done = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Foundation.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        done = done && fsync(fd) == 0
        close(fd)
        guard done else { unlink(temporary.path); return false }
        // What was there is kept, not lost: moved aside only for a replacement that is written, and put back if it cannot land.
        let aside = url.appendingPathExtension("corrupt").path
        let moved = corrupt && rename(url.path, aside) == 0
        guard rename(temporary.path, url.path) == 0 else {
            if moved { rename(aside, url.path) }
            unlink(temporary.path)
            return false
        }
        return true
    }
}
#endif
