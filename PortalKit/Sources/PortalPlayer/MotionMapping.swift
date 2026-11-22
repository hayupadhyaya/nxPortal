import PortalKit

/// Sensor values as the Host takes them -> .claude/client.md § input. Equal to nxnative's `motion_phone_to_switch`.
public enum MotionMapping {
    /// Device sensors turned to the picture's frame. `orientation` is a UIInterfaceOrientation raw value.
    public static func device(orientation: Int, acceleration: SIMD3<Float>, rotation: SIMD3<Float>) -> MotionSample {
        MotionSample(frame: .switchDevice, acc: turn(orientation, acceleration), rot: turn(orientation, rotation))
    }

    public static func controller(acceleration: SIMD3<Float>, rotation: SIMD3<Float>) -> MotionSample {
        MotionSample(frame: .controller, acc: acceleration, rot: rotation)
    }

    private static func turn(_ orientation: Int, _ v: SIMD3<Float>) -> SIMD3<Float> {
        switch orientation {
        case 3: SIMD3(-v.y, v.x, v.z)
        case 4: SIMD3(v.y, -v.x, v.z)
        case 2: SIMD3(-v.x, -v.y, v.z)
        default: v
        }
    }
}
