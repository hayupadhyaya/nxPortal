import CryptoKit
import Foundation
import PortalKit
import PortalClientCore

/// Game icons from the Macs, one PNG per title in `directory` (`<titleID>-<hash>.png`, its palette beside it as
/// `<titleID>-<hash>.palette.json`). A file whose SHA-256 is not its hash is deleted and reads as absent; a title or
/// hash that is not a plain name is never a file. Best effort: a cache that cannot be written is empty next time.
/// The icons are the games' publishers' material: they live only here -> .claude/client.md § model
public struct ArtCache: Sendable {
    let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// The stored icon, after checking its hash.
    public func data(titleID: String, hash: String) -> Data? {
        guard let url = file(titleID, hash, "png"),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= ArtChunking.maxBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        guard Self.hash(data) == hash else {
            remove(titleID, hash)
            return nil
        }
        return data
    }

    /// Keeps `data` when it hashes to `hash`; the title's other files go.
    public func store(_ data: Data, titleID: String, hash: String) {
        guard data.count <= ArtChunking.maxBytes, Self.hash(data) == hash, let url = file(titleID, hash, "png") else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix(titleID + "-") && !name.hasPrefix("\(titleID)-\(hash).") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        try? data.write(to: url, options: .atomic)
    }

    /// The icon's palette: read from its JSON, else `ArtPalette.from(png:)` of the stored file, written beside it.
    /// Decodes the image: call it off the main actor. Nil without a stored icon.
    public func palette(titleID: String, hash: String) -> ArtPalette? {
        guard let url = file(titleID, hash, "palette.json") else { return nil }
        if let json = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(ArtPalette.self, from: json),
           FileManager.default.fileExists(atPath: file(titleID, hash, "png")!.path) { return p }
        guard let png = data(titleID: titleID, hash: hash) else { return nil }
        let p = ArtPalette.from(png: png) ?? .slate
        if let json = try? JSONEncoder().encode(p) { try? json.write(to: url, options: .atomic) }
        return p
    }

    /// SHA-256, 64 lowercase hex.
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// A title ID of 1 to 32 letters and digits; a hash of 64 lowercase hex.
    static func safe(titleID: String, hash: String) -> Bool {
        TitleID.isWellFormed(titleID)
            && hash.utf8.count == 64 && hash.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    private func file(_ titleID: String, _ hash: String, _ ext: String) -> URL? {
        Self.safe(titleID: titleID, hash: hash) ? directory.appendingPathComponent("\(titleID)-\(hash).\(ext)") : nil
    }

    private func remove(_ titleID: String, _ hash: String) {
        for ext in ["png", "palette.json"] { if let url = file(titleID, hash, ext) { try? FileManager.default.removeItem(at: url) } }
    }
}

/// One icon on its way from the Host: chunks `0..<count` in order, `count` = ceil(bytes / chunk), the whole hashing to
/// the listed hash. Anything else is discarded -> .claude/client.md § model
struct ArtTransfer {
    enum Step: Equatable { case more, done(Data), none, discard }

    let titleID: String
    let ref: ArtRef
    private var next: UInt16 = 0
    private var data = Data()

    /// Nil for a listing the device does not ask for: no bytes, over `ArtChunking.maxBytes`, or not a plain name.
    init?(titleID: String, ref: ArtRef) {
        guard ref.bytes > 0, Int(ref.bytes) <= ArtChunking.maxBytes, ArtCache.safe(titleID: titleID, hash: ref.hash) else { return nil }
        self.titleID = titleID
        self.ref = ref
    }

    var count: Int { ArtChunking.count(bytes: Int(ref.bytes)) }

    mutating func accept(_ c: ArtChunk) -> Step {
        guard c.titleID == titleID, c.hash == ref.hash else { return .discard }
        if c.count == 0 { return .none }
        guard Int(c.count) == count, c.index == next, c.bytes.count <= ArtChunking.chunkBytes,
              data.count + c.bytes.count <= Int(ref.bytes) else { return .discard }
        data.append(c.bytes)
        next += 1
        guard Int(next) == count else { return .more }
        return data.count == Int(ref.bytes) && ArtCache.hash(data) == ref.hash ? .done(data) : .discard
    }
}
