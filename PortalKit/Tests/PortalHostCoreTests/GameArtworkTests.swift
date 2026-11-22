#if os(macOS)
import XCTest
import ImageIO
import PortalTestSupport
@testable import PortalHostCore

/// Icons drawn in the test (`FakeArt`); no artwork from anywhere else.
final class GameArtworkTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-art-" + UUID().uuidString)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func side(_ png: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    func testAFlatIconComesBackAt512UnderTheCap() throws {
        let app = try FakeArt.makeApp(in: dir, titleID: "FAKE000000000001", name: "Flat", paint: .flat(0x3366FF))
        let png = try XCTUnwrap(GameArtwork.png(forBundle: app))
        let (w, h) = try XCTUnwrap(side(png))
        XCTAssertEqual(w, 512)
        XCTAssertEqual(h, 512)
        XCTAssertLessThan(png.count, 512 * 1024)
        XCTAssertEqual(png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]), "a PNG")
    }

    func testNoIconFileKeyIsNil() throws {
        let app = try FakeArt.makeApp(in: dir, titleID: "FAKE000000000002", name: "Plain", paint: nil)
        XCTAssertNil(GameArtwork.png(forBundle: app))
    }

    func testTheExtensionIsAddedWhenMissing() throws {
        let app = try FakeArt.makeApp(in: dir, titleID: "FAKE000000000003", name: "Named", paint: .flat(0xFF3300))
        XCTAssertEqual(GameArtwork.iconURL(forBundle: app)?.lastPathComponent, "AppIcon.icns")
    }

    func testANoisyIconOverTheCapComesBackAt256() throws {
        let app = try FakeArt.makeApp(in: dir, titleID: "FAKE000000000004", name: "Noise", paint: .noise(seed: 7))
        let png = try XCTUnwrap(GameArtwork.png(forBundle: app))
        let (w, h) = try XCTUnwrap(side(png))
        XCTAssertEqual(w, 256)
        XCTAssertEqual(h, 256)
        XCTAssertLessThanOrEqual(png.count, 512 * 1024)
    }

    func testHashIsStableHex() throws {
        let app = try FakeArt.makeApp(in: dir, titleID: "FAKE000000000005", name: "Hash", paint: .gradient(0xFF0000, 0x0000FF))
        let png = try XCTUnwrap(GameArtwork.png(forBundle: app))
        let a = GameArtwork.hash(png), b = GameArtwork.hash(png)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
        XCTAssertTrue(a.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertNotEqual(GameArtwork.hash(png + Data([0])), a)
    }
}
#endif
