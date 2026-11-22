import XCTest
import CoreGraphics
@testable import PortalPlayer

final class AmbientImageTests: XCTestCase {
    func testBitmapBlur() {
        XCTAssertEqual(AmbientImage.bitmapBlur(points: 120, iconSide: 900), 17.1, accuracy: 0.1)
        XCTAssertEqual(AmbientImage.bitmapBlur(points: 140, iconSide: 1300), 13.8, accuracy: 0.1)
    }

    func testMakeIsSquareAndEdgesStayOpaque() throws {
        let image = try XCTUnwrap(AmbientImage.make(png: ImageFixtures.gradient(), blurRadius: 17))
        XCTAssertEqual(image.width, 128)
        XCTAssertEqual(image.height, 128)
        var px = [UInt8](repeating: 0, count: 4)
        for (x, y) in [(0, 0), (127, 0), (0, 127), (127, 127)] {
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: -x, y: -(127 - y), width: 128, height: 128))
            XCTAssertEqual(px[3], 255, "corner \(x),\(y)")
        }
    }

    func testBadData() {
        XCTAssertNil(AmbientImage.make(png: Data([1, 2, 3]), blurRadius: 17))
    }
}

final class BoundedDecodeTests: XCTestCase {
    /// Flat, so the file is small while the declared size is large.
    private func huge() -> Data { ImageFixtures.fill(RGBA(0x3366FF), side: 5000) }

    func testOversizedDimensionsAreRefusedBeforeDecoding() {
        let data = huge()
        XCTAssertLessThan(data.count, AmbientImage.maxBytes)
        let start = Date()
        XCTAssertNil(AmbientImage.make(png: data, blurRadius: 17))
        XCTAssertNil(ArtPalette.from(png: data))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testOverTheByteCapIsRefused() {
        let ok = ImageFixtures.gradient()
        XCTAssertNotNil(AmbientImage.make(png: ok, blurRadius: 17))
        let padded = ok + Data(count: AmbientImage.maxBytes)  // trailing bytes: still a decodable PNG
        XCTAssertNil(AmbientImage.make(png: padded, blurRadius: 17))
        XCTAssertNil(ArtPalette.from(png: padded))
    }

    func testTheCapsAreExactly4096PixelsAnd8MiB() {
        XCTAssertEqual(AmbientImage.maxSide, 4096)
        XCTAssertEqual(AmbientImage.maxBytes, 8 * 1024 * 1024)
        XCTAssertNotNil(ArtPalette.from(png: ImageFixtures.flat(width: 4096, height: 8)), "a side of exactly 4096 passes")
        XCTAssertNotNil(ArtPalette.from(png: ImageFixtures.flat(width: 8, height: 4096)))
        XCTAssertNil(ArtPalette.from(png: ImageFixtures.flat(width: 4097, height: 8)), "4097 does not")
        XCTAssertNil(ArtPalette.from(png: ImageFixtures.flat(width: 8, height: 4097)))
        let ok = ImageFixtures.gradient()
        let atCap = ok + Data(count: AmbientImage.maxBytes - ok.count)
        XCTAssertNotNil(AmbientImage.make(png: atCap, blurRadius: 17), "exactly the byte cap passes")
        XCTAssertNil(AmbientImage.make(png: atCap + Data([0]), blurRadius: 17), "one byte more does not")
    }

    func testLargestAllowedSideStillWorks() {
        XCTAssertNotNil(ArtPalette.from(png: ImageFixtures.gradient(side: 1024)))
    }
}
