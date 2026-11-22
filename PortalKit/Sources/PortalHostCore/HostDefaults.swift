#if os(macOS)
import Foundation

public enum HostDefaults {
    /// Default video bitrate in bit/s; the one place it is set.
    public static let bitrate: UInt32 = 20_000_000
    /// Default for `HostConfig.maxBitrate`: the highest bitrate a client may ask for.
    public static let maxBitrate: UInt32 = 200_000_000
    /// Lowest bitrate handed to the tap.
    public static let minBitrate: UInt32 = 1_000_000

    /// Smallest size cap handed to the tap; a client asking for less (or 0) gets this.
    public static let minWidth: UInt16 = 320
    public static let minHeight: UInt16 = 180

    /// The Host's tap socket folder: `nxportal` inside the user's own temporary folder (`confstr`, not shared with other users).
    public static func socketDirectory() -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let base = n > 0 ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : NSTemporaryDirectory()
        return (base as NSString).appendingPathComponent("nxportal")
    }

    /// `<socketDirectory()>/tap-<pid>-<instance>.sock`: one per `HostService` in a process. Throws
    /// `TapServerError.pathTooLong` past 103 bytes (`sun_path`).
    public static func socketPath(instance: Int = 0) throws -> String {
        try socketPath(in: socketDirectory(), instance: instance)
    }

    static func socketPath(in directory: String, instance: Int) throws -> String {
        let path = (directory as NSString).appendingPathComponent("tap-\(getpid())-\(instance).sock")
        guard path.utf8.count <= 103 else { throw TapServerError.pathTooLong }
        return path
    }
}
#endif
