#if os(macOS)
import Foundation
import IOKit.pwr_mgt

public protocol PowerHolding: Sendable {
    func set(_ awake: Bool)
}

/// One `PreventUserIdleSystemSleep` assertion while awake; repeated calls are idempotent.
public struct SystemPowerHold: PowerHolding {
    private final class Assertion: @unchecked Sendable {
        let lock = NSLock()  // guards id
        var id: IOPMAssertionID?
    }

    private let assertion = Assertion()

    public init() {}

    public func set(_ awake: Bool) {
        assertion.lock.lock(); defer { assertion.lock.unlock() }
        if awake, assertion.id == nil {
            var id = IOPMAssertionID(0)
            let rc = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "nxPortal streaming" as CFString, &id)
            if rc == kIOReturnSuccess { assertion.id = id }
        } else if !awake, let id = assertion.id {
            IOPMAssertionRelease(id)
            assertion.id = nil
        }
    }
}
#endif
