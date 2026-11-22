#if os(macOS)
import Foundation
import PortalHostCore

/// What the person set for the Host -> .claude/host.md § model
public struct HostSettings: Codable, Equatable, Sendable {
    /// nil = the computer's name.
    public var name: String?
    /// Added by the person, on top of the standard application folders.
    public var folders: [URL]
    /// The highest video bitrate (bit/s) a device may ask for; `HostConfig.maxBitrate`.
    public var maxBitrate: UInt32

    private enum CodingKeys: String, CodingKey { case name, folders, maxBitrate }

    /// A stored value that lacks a field (one added later) keeps the others.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        folders = try c.decodeIfPresent([URL].self, forKey: .folders) ?? []
        maxBitrate = try c.decodeIfPresent(UInt32.self, forKey: .maxBitrate) ?? HostDefaults.maxBitrate
    }

    public init(name: String? = nil, folders: [URL] = [], maxBitrate: UInt32 = HostDefaults.maxBitrate) {
        self.name = name; self.folders = folders; self.maxBitrate = maxBitrate
    }
}

/// `HostSettings` as JSON under `hostSettings`; data that cannot be read gives the defaults.
public struct HostSettingsStore: @unchecked Sendable {  // UserDefaults is documented as thread-safe
    static let key = "hostSettings"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func load() -> HostSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(HostSettings.self, from: data) else { return HostSettings() }
        return settings
    }

    public func save(_ settings: HostSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
#endif
