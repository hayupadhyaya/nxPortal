#if os(macOS)
import Foundation

/// The optional `environment.json` next to the Host's secrets: variables every game is started with (a game's saves and prepared
/// graphics live under the `HOME` it is started with) -> .claude/host.md § app
public enum EnvironmentFile {
    public enum Outcome: Equatable, Sendable {
        /// Absent file: nothing to add, nothing wrong.
        case absent
        case variables([String: String])
        /// Unreadable, not JSON, not an object, or a value that is not a string: the whole file is ignored.
        case ignored
    }

    public static func read(_ url: URL) -> Outcome {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .ignored }
        var out: [String: String] = [:]
        for (key, value) in object {
            guard let text = value as? String else { return .ignored }
            out[key] = text
        }
        return .variables(out)
    }
}
#endif
