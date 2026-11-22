#if os(macOS)
import Foundation

public struct GameApp: Equatable, Sendable {
    public var titleID: String, name: String, url: URL, streamable: Bool
    /// `CFBundleIdentifier`: the preferences domain of the app's own saved choices (`launcher.<variable>`); nil when it has none.
    public var bundleID: String?
    public init(titleID: String, name: String, url: URL, streamable: Bool, bundleID: String? = nil) {
        self.titleID = titleID; self.name = name; self.url = url; self.streamable = streamable; self.bundleID = bundleID
    }
}

/// Game apps under the roots -> .claude/host.md § library
public struct GameLibrary: Sendable {
    private let roots: [URL]

    public init(roots: [URL]) { self.roots = roots }

    /// `root/*.app` and `root/*/*.app` whose Info.plist has `DMTitleID`; one entry per title (the first copy that can
    /// stream, else the first found, in the roots' order); sorted by name -> .claude/host.md § library
    public func scan() -> [GameApp] {
        var apps: [GameApp] = []
        for root in roots {
            for item in Self.children(root) {
                if item.pathExtension == "app" {
                    if let app = Self.read(item) { apps.append(app) }
                } else {
                    apps += Self.children(item).filter { $0.pathExtension == "app" }.compactMap(Self.read)
                }
            }
        }
        // A launch names a title, so two rows of one title cannot be told apart: an ordinary install must not hide the
        // build that streams.
        var index: [String: Int] = [:], games: [GameApp] = []
        for app in apps {
            if let i = index[app.titleID] {
                if app.streamable, !games[i].streamable { games[i] = app }
            } else {
                index[app.titleID] = games.count
                games.append(app)
            }
        }
        return games.sorted { $0.name < $1.name }
    }

    private static func children(_ dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }

    /// Nil for an unreadable bundle or one without `DMTitleID`.
    private static func read(_ app: URL) -> GameApp? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let titleID = plist["DMTitleID"] as? String else { return nil }
        let name = plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String
            ?? app.deletingPathExtension().lastPathComponent
        return GameApp(titleID: titleID, name: name, url: app, streamable: plist["DMStream"] as? Bool ?? false,
                       bundleID: plist["CFBundleIdentifier"] as? String)
    }
}
#endif
