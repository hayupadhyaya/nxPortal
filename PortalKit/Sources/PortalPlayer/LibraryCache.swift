import CryptoKit
import Foundation
import PortalKit

/// The last known games of each Mac and the title last played there, one JSON file per Mac in `directory`
/// (named by the first 16 hex characters of the SHA-256 of the Mac's key). A damaged file, or one above `maxFileBytes`,
/// reads as empty and is replaced by the next save. -> .claude/client.md § model
public struct LibraryCache: Sendable {
    struct File: Codable { var games: [GameEntry] = [], lastPlayed: String? }

    /// A file above this many bytes is not read (it reads as empty); a Mac's list is a few tens of KiB.
    static let maxFileBytes = 1_048_576

    let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func games(for hostKey: Data) -> [GameEntry] { read(hostKey).games }
    public func lastPlayed(for hostKey: Data) -> String? { read(hostKey).lastPlayed }

    public func save(_ games: [GameEntry], for hostKey: Data) {
        var file = read(hostKey)
        file.games = games
        write(file, hostKey)
    }

    public func setLastPlayed(_ titleID: String, for hostKey: Data) {
        var file = read(hostKey)
        file.lastPlayed = titleID
        write(file, hostKey)
    }

    private func url(_ key: Data) -> URL {
        let name = SHA256.hash(data: key).prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }

    private func read(_ key: Data) -> File {
        let size = (try? url(key).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxFileBytes, let data = try? Data(contentsOf: url(key)), let file = try? JSONDecoder().decode(File.self, from: data) else { return File() }
        return file
    }

    /// Best effort: a cache that cannot be written is just empty next time.
    private func write(_ file: File, _ key: Data) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(file) { try? data.write(to: url(key), options: .atomic) }
    }
}
