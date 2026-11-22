import Foundation
import XCTest
@testable import PortalKit

final class FileSecretsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("portal-secrets-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testWriteReadDeleteRoundTrip() throws {
        let dir = root.appendingPathComponent("keys")
        let s = FileSecrets(directory: dir)
        XCTAssertNil(try s.read("identity"), "a missing key reads nil, before the directory exists")
        try s.write("identity", Data([1, 2, 3]))
        XCTAssertEqual(try s.read("identity"), Data([1, 2, 3]))
        try s.write("identity", Data([9]))
        XCTAssertEqual(try s.read("identity"), Data([9]), "write replaces")
        try s.write("hosts.v1-a", Data())
        XCTAssertEqual(try s.read("hosts.v1-a"), Data(), "an empty value is a value")
        try s.delete("identity")
        XCTAssertNil(try s.read("identity"))
        XCTAssertNoThrow(try s.delete("identity"), "deleting a missing key is not an error")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["hosts.v1-a"], "no temporary file is left")
    }

    func testAnExistingFolderWithWiderModesIsTightened() throws {
        let dir = root.appendingPathComponent("keys")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let s = FileSecrets(directory: dir)
        try s.write("identity", Data([1]))
        XCTAssertEqual(try mode(dir), 0o755, "write leaves an existing folder as it is")
        s.tightenFolder()
        XCTAssertEqual(try mode(dir), 0o700)
        XCTAssertEqual(try mode(dir.appendingPathComponent("identity")), 0o600)
        FileSecrets(directory: root.appendingPathComponent("missing")).tightenFolder()  // nothing to tighten, nothing made
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
    }

    func testModes() throws {
        let dir = root.appendingPathComponent("keys")
        let s = FileSecrets(directory: dir)
        try s.write("identity", Data([1]))
        XCTAssertEqual(try mode(dir), 0o700)
        XCTAssertEqual(try mode(dir.appendingPathComponent("identity")), 0o600)
        try s.write("identity", Data([2]))
        XCTAssertEqual(try mode(dir.appendingPathComponent("identity")), 0o600, "also after a replace")
    }

    func testBadKeysThrow() throws {
        let s = FileSecrets(directory: root.appendingPathComponent("keys"))
        for key in ["", "/", "a/b", "../x", "..", ".", ".hidden", "a..b", "UPPER", "a b", "a\u{0}b", "é"] {
            let want = SecretStoreError.file("bad key", EINVAL)
            XCTAssertThrowsError(try s.read(key), key) { XCTAssertEqual($0 as? SecretStoreError, want, key) }
            XCTAssertThrowsError(try s.write(key, Data([1])), key) { XCTAssertEqual($0 as? SecretStoreError, want, key) }
            XCTAssertThrowsError(try s.delete(key), key) { XCTAssertEqual($0 as? SecretStoreError, want, key) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "a refused key creates nothing")
    }

    func testAnUnwritableDirectoryThrowsFileError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("file")
        try Data([1]).write(to: blocker)
        let s = FileSecrets(directory: blocker.appendingPathComponent("sub"))
        XCTAssertThrowsError(try s.write("k", Data([1]))) {
            guard case let .file(_, code)? = $0 as? SecretStoreError else { return XCTFail("\($0)") }
            XCTAssertEqual(code, ENOTDIR)
        }
    }
}
