import XCTest
import PortalKit
@testable import PortalPlayer

final class MotionMappingTests: XCTestCase {
    func testDeviceOrientations() {
        let v = SIMD3<Float>(1, 2, 3)
        let expected: [Int: SIMD3<Float>] = [
            1: [1, 2, 3], 2: [-1, -2, 3], 3: [-2, 1, 3], 4: [2, -1, 3], 0: [1, 2, 3], 9: [1, 2, 3],
        ]
        for (o, e) in expected {
            let m = MotionMapping.device(orientation: o, acceleration: v, rotation: v * 2)
            XCTAssertEqual(m.frame, .switchDevice)
            XCTAssertEqual(m.acc, e, "acc orientation \(o)")
            XCTAssertEqual(m.rot, MotionMapping.device(orientation: o, acceleration: v * 2, rotation: v).acc, "rot orientation \(o)")
            XCTAssertEqual(m.rot, e * 2, "rot orientation \(o)")
        }
    }

    func testControllerMotionUnchanged() {
        let m = MotionMapping.controller(acceleration: [1, 2, 3], rotation: [4, 5, 6])
        XCTAssertEqual(m.frame, .controller)
        XCTAssertEqual(m.acc, [1, 2, 3])
        XCTAssertEqual(m.rot, [4, 5, 6])
    }
}
