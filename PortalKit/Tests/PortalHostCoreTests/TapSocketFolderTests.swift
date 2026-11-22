#if os(macOS)
import XCTest
import Foundation
import PortalKit
@testable import PortalHostCore

/// The tap socket's folder: private to the user, stale sockets of dead Hosts removed -> .claude/host.md § tap-server
final class TapSocketFolderTests: XCTestCase {
    private var base: URL!
    private var servers: [TapServer] = []

    override func setUp() async throws {
        continueAfterFailure = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-f-" + String(format: "%08x", UInt32.random(in: 0...UInt32.max)))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for s in servers { await s.stop() }
        try? FileManager.default.removeItem(at: base)
    }

    private func mode(_ path: String) -> mode_t? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_mode & 0o7777 : nil
    }

    private func server(_ path: String) -> TapServer {
        let s = TapServer(socketPath: path, requirePrivateFolder: true)
        servers.append(s)
        return s
    }

    /// A socket file nobody listens on (what a crashed Host leaves).
    private func leftSocket(_ path: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
    }

    /// The pid of a process that has exited.
    private func deadPID() throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }

    func testDefaultFolderIsInTheUsersTemporaryFolder() throws {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        XCTAssertGreaterThan(confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count), 0)
        let userTemp = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let dir = HostDefaults.socketDirectory()
        XCTAssertTrue(dir.hasPrefix(userTemp), dir)
        XCTAssertTrue(dir.hasSuffix("/nxportal"), dir)
        let path = try HostDefaults.socketPath(instance: 3)
        XCTAssertEqual(path, dir + "/tap-\(getpid())-3.sock")
        XCTAssertLessThanOrEqual(path.utf8.count, 103)
        XCTAssertThrowsError(try HostDefaults.socketPath(in: String(repeating: "a", count: 100), instance: 0)) {
            XCTAssertEqual($0 as? TapServerError, .pathTooLong)
        }
    }

    func testSocketFolderIsPrivate() async throws {
        // Missing: made, the user's own, 0700.
        let dir = base.appendingPathComponent("nxportal").path
        let s = server(dir + "/tap-1-0.sock")
        try await s.start()
        var st = stat()
        XCTAssertEqual(lstat(dir, &st), 0)
        XCTAssertEqual(st.st_uid, getuid())
        XCTAssertEqual(st.st_mode & 0o7777, 0o700)
        XCTAssertNotNil(mode(dir + "/tap-1-0.sock"))
    }

    func testFolderOpenToOthersIsRefused() async throws {
        let dir = base.appendingPathComponent("open").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod(dir, 0o755)
        let s = server(dir + "/tap-1-0.sock")
        do { try await s.start(); XCTFail("started in a folder with mode 0755") } catch {
            XCTAssertEqual(error as? TapServerError, .unsafeFolder)
        }
        XCTAssertNil(mode(dir + "/tap-1-0.sock"), "a socket was created")
    }

    func testFolderThatIsALinkIsRefused() async throws {
        let real = base.appendingPathComponent("real").path
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let link = base.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let s = server(link + "/tap-1-0.sock")
        do { try await s.start(); XCTFail("started in a linked folder") } catch {
            XCTAssertEqual(error as? TapServerError, .unsafeFolder)
        }
        XCTAssertNil(mode(real + "/tap-1-0.sock"), "a socket was created")
    }

    func testStaleSocketsRemoved() async throws {
        let dir = base.appendingPathComponent("nxportal").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dead = "\(dir)/tap-\(try deadPID())-0.sock"
        let mine = "\(dir)/tap-\(getpid())-7.sock"
        let launchd = "\(dir)/tap-1-0.sock"  // a running process of another user: kill(1, 0) says EPERM, not ESRCH
        let other = "\(dir)/other.sock"
        for p in [dead, mine, launchd, other] { leftSocket(p) }
        let s = server("\(dir)/tap-\(getpid())-0.sock")
        try await s.start()
        XCTAssertNil(mode(dead), "the socket of a pid that is not running is still there")
        XCTAssertNotNil(mode(mine), "the socket of a running pid was removed")
        XCTAssertNotNil(mode(launchd), "the socket of a running pid (not ours) was removed")
        XCTAssertNotNil(mode(other), "a file that is not a tap socket's name was removed")
    }
}
#endif
