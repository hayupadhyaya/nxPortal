import XCTest
import PortalKit
@testable import PortalPlayer

final class PadMappingTests: XCTestCase {
    private func snap(_ f: (inout PadSnapshot) -> Void) -> PadSnapshot {
        var s = PadSnapshot(); f(&s); return s
    }

    func testFaceByPosition() {
        XCTAssertEqual(PadMapping.buttons(snap { $0.buttonA = true }, layout: .auto), [.b])
        XCTAssertEqual(PadMapping.buttons(snap { $0.buttonB = true }, layout: .auto), [.a])
        XCTAssertEqual(PadMapping.buttons(snap { $0.buttonX = true }, layout: .auto), [.y])
        XCTAssertEqual(PadMapping.buttons(snap { $0.buttonY = true }, layout: .auto), [.x])
    }

    func testFaceByLabel() {
        XCTAssertEqual(PadMapping.buttons(snap { $0.usesPrintedLabels = true; $0.buttonA = true }, layout: .auto), [.a])
        XCTAssertEqual(PadMapping.buttons(snap { $0.usesPrintedLabels = true; $0.buttonX = true }, layout: .auto), [.x])
        XCTAssertEqual(PadMapping.buttons(snap { $0.usesPrintedLabels = true; $0.buttonA = true }, layout: .byPosition), [.b])
        XCTAssertEqual(PadMapping.buttons(snap { $0.buttonA = true }, layout: .byLabel), [.a])
    }

    func testOtherButtons() {
        let cases: [(WritableKeyPath<PadSnapshot, Bool>, PadButtons)] = [
            (\.leftShoulder, .l), (\.rightShoulder, .r), (\.menu, .plus), (\.options, .minus),
            (\.leftStick, .stickL), (\.rightStick, .stickR),
            (\.left, .left), (\.up, .up), (\.right, .right), (\.down, .down),
        ]
        for (path, button) in cases {
            var s = PadSnapshot(); s[keyPath: path] = true
            XCTAssertEqual(PadMapping.buttons(s, layout: .auto), button, "\(path)")
        }
        XCTAssertEqual(PadMapping.buttons(snap { $0.leftTrigger = 0.25; $0.rightTrigger = 0.25 }, layout: .auto), [])
        XCTAssertEqual(PadMapping.buttons(snap { $0.leftTrigger = 0.26 }, layout: .auto), [.zl])
        XCTAssertEqual(PadMapping.buttons(snap { $0.rightTrigger = 0.26 }, layout: .auto), [.zr])
    }

    func testAxis() {
        XCTAssertEqual(PadMapping.axis(1), 32767)
        XCTAssertEqual(PadMapping.axis(-1), -32767)
        XCTAssertEqual(PadMapping.axis(0.5), 16383)
        XCTAssertEqual(PadMapping.axis(2), 32767)
        XCTAssertEqual(PadMapping.axis(.nan), 0)
    }
}
