import Foundation
import Security

/// A secret store failed: a keychain status, or a file operation and its errno -> .claude/portalkit.md § secrets
public enum SecretStoreError: Error, Equatable { case keychain(Int32), file(String, Int32) }

/// Small secrets by key -> .claude/portalkit.md § secrets
public protocol SecretStoring: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ key: String, _ data: Data) throws
    func delete(_ key: String) throws
}

/// Generic passwords in the keychain: this device only, readable after the first unlock.
/// Errors throw `SecretStoreError.keychain(status)`.
public struct KeychainSecrets: SecretStoring {
    private let service: String

    public init(service: String = "nxportal") { self.service = service }

    private func query(_ key: String) -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
#if os(iOS) || os(tvOS)
        q[kSecUseDataProtectionKeychain] = true  // macOS: an unsigned test process has none -> .claude/client.md § store
#endif
        return q
    }

    public func read(_ key: String) throws -> Data? {
        var q = query(key)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
        return out as? Data
    }

    public func write(_ key: String, _ data: Data) throws {
        let attrs: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(key) as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
        let added = SecItemAdd(query(key).merging(attrs) { $1 } as CFDictionary, nil)
        guard added == errSecSuccess else { throw SecretStoreError.keychain(added) }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }
}

/// In memory, for tests and previews.
public final class MemorySecrets: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()  // guards values
    private var values: [String: Data] = [:]

    public init() {}

    public func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    public func write(_ key: String, _ data: Data) throws { lock.withLock { values[key] = data } }
    public func delete(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

/// One file per key in `directory` (created 0700), each written atomically with mode 0600, for a process that has no keychain
/// (the Host). A key is `[a-z0-9.-]+`, not starting with a dot and without `..`; anything else throws `.file("bad key", EINVAL)`.
public struct FileSecrets: SecretStoring {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    private func path(_ key: String) throws -> String {
        let ok = !key.isEmpty && !key.hasPrefix(".") && !key.contains("..")
            && key.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x2D }
        guard ok else { throw SecretStoreError.file("bad key", EINVAL) }
        return directory.appendingPathComponent(key).path
    }

    public func read(_ key: String) throws -> Data? {
        let file = try path(key)
        let fd = open(file, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw SecretStoreError.file("open", errno)
        }
        defer { close(fd) }
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; throw SecretStoreError.file("read", errno) }
            if n == 0 { return out }
            out.append(contentsOf: chunk[0..<n])
        }
    }

    public func write(_ key: String, _ data: Data) throws {
        let file = try path(key)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            let code = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError).map { Int32($0.code) } ?? EIO
            throw SecretStoreError.file("mkdir", code)
        }
        // Written under a hidden name no key can have, then renamed over the key: a reader sees the old or the new value.
        let temp = directory.appendingPathComponent(".tmp-" + UUID().uuidString).path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SecretStoreError.file("create", errno) }
        var failure: SecretStoreError?
        var offset = 0
        while offset < data.count, failure == nil {
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, data.count - offset) }
            if n < 0 { if errno != EINTR { failure = .file("write", errno) } } else { offset += n }
        }
        if failure == nil, fsync(fd) != 0 { failure = .file("fsync", errno) }
        if close(fd) != 0, failure == nil { failure = .file("close", errno) }
        if failure == nil, rename(temp, file) != 0 { failure = .file("rename", errno) }
        if let failure { unlink(temp); throw failure }
    }

    /// An existing folder with wider modes is set to 0700 (one that does not exist yet is made so by the first write).
    public func tightenFolder() {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isFolder), isFolder.boolValue else { return }
        chmod(directory.path, 0o700)
    }

    public func delete(_ key: String) throws {
        let file = try path(key)
        if unlink(file) != 0, errno != ENOENT, errno != ENOTDIR { throw SecretStoreError.file("unlink", errno) }
    }
}
