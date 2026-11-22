#if os(macOS)
import XCTest
import Foundation
import PortalTestSupport
@testable import PortalHostCore

/// The Host answers from the address a device sent to -> .claude/host.md § service
///
/// A device's media link is a connected UDP flow: it drops an answer from any other address of the Mac. Each test sends
/// from one local address to ANOTHER local address of this machine, so the kernel's own choice of source for the
/// answer (the sender's address) is the wrong one.
final class MediaSocketSourceTests: XCTestCase {
    private var media: MediaSocket!
    private var port: UInt16 = 0
    private var client: Int32 = -1

    override func setUp() async throws {
        media = MediaSocket()
        port = try media.start()
    }

    override func tearDown() async throws {
        if client >= 0 { close(client) }
        media.stop()
    }

    /// From a non-loopback IPv4 address to 127.0.0.1: the answer comes from 127.0.0.1.
    func testAnIPv4AnswerLeavesFromTheAddressTheDeviceSentTo() async throws {
        guard let other = LocalAddresses.nonLoopbackIPv4() else {
            throw XCTSkip("this machine has no IPv4 address besides loopback: nothing to send from")
        }
        client = try udpClient(family: AF_INET, bindTo: other, connectTo: "127.0.0.1")
        try await assertAnswerArrives()
    }

    /// From fe80::1%lo0 (link-local, with its scope) to ::1: the answer comes from ::1. (`::1` cannot answer a
    /// non-loopback IPv6 address at all: macOS refuses that source for any other destination.)
    func testAnIPv6AnswerLeavesFromTheAddressTheDeviceSentTo() async throws {
        do { client = try udpClient(family: AF_INET6, bindTo: "fe80::1%lo0", connectTo: "::1") } catch {
            throw XCTSkip("this machine has no link-local address on loopback (fe80::1%lo0) to send from: \(error)")
        }
        try await assertAnswerArrives()
    }

    // MARK: helpers

    private struct SocketError: Error { let call: String; let code: Int32 }

    private func assertAnswerArrives(file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertEqual(Darwin.send(client, "ping", 4, 0), 4, file: file, line: line)
        var inbound: InboundDatagram?
        // A lost datagram fails the test after 2 s instead of hanging the suite.
        let guardTask = Task { [media] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }  // cancelled: stops nothing
            media?.stop()  // finishes the stream
        }
        for await d in media.datagrams { inbound = d; break }
        guardTask.cancel()
        await guardTask.value  // a cancelled guard has finished by here; the socket must still be open
        let d = try XCTUnwrap(inbound, "the Host received nothing", file: file, line: line)
        XCTAssertEqual(media.transmit(Data("pong".utf8), to: d.from), .sent, "a cancelled guard closed the socket", file: file, line: line)
        var p = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&p, 1, 1000), 1, "no answer reached the device: it left from another address", file: file, line: line)
    }

    /// A UDP socket bound to `local` (port any), connected to `remote` at the media port: it accepts datagrams only from there.
    private func udpClient(family: Int32, bindTo local: String, connectTo remote: String) throws -> Int32 {
        let s = socket(family, SOCK_DGRAM, 0)
        guard s >= 0 else { throw SocketError(call: "socket", code: errno) }
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: family, ai_socktype: SOCK_DGRAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        func resolve(_ host: String, _ port: UInt16) throws -> [UInt8] {
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &res) == 0, let r = res else { throw SocketError(call: "getaddrinfo", code: 0) }
            defer { freeaddrinfo(res) }
            return Array(UnsafeRawBufferPointer(start: r.pointee.ai_addr, count: Int(r.pointee.ai_addrlen)))
        }
        do {
            let from = try resolve(local, 0), to = try resolve(remote, port)
            guard from.withUnsafeBytes({ Darwin.bind(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(from.count)) }) == 0 else {
                throw SocketError(call: "bind", code: errno)
            }
            guard to.withUnsafeBytes({ Darwin.connect(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(to.count)) }) == 0 else {
                throw SocketError(call: "connect", code: errno)
            }
        } catch { close(s); throw error }
        return s
    }
}
#endif
