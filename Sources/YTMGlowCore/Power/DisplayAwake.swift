import Foundation
import IOKit.pwr_mgt

/// Something that can hold "don't let the display sleep".
public protocol DisplaySleepPreventing: AnyObject {
    var isHeld: Bool { get }
    func hold(reason: String) -> Bool
    func release()
}

/// IOKit power assertion (`kIOPMAssertionTypePreventUserIdleDisplaySleep`),
/// the same mechanism as `caffeinate -d`. Shows up in `pmset -g assertions`.
public final class PowerAssertionDisplayAwake: DisplaySleepPreventing {
    private var assertionID: IOPMAssertionID = 0

    public init() {}

    deinit { release() }

    public var isHeld: Bool { assertionID != 0 }

    public func hold(reason: String) -> Bool {
        guard assertionID == 0 else { return true }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        guard result == kIOReturnSuccess else { return false }
        assertionID = id
        return true
    }

    public func release() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }
}

/// Holds the display awake only while music is actually playing and the
/// option is on. Pausing, stopping, or a stale browser releases it.
@MainActor
public final class DisplayAwakeController {
    public static let reason = "YTM Glow: music is playing"

    private let assertion: DisplaySleepPreventing
    public private(set) var enabled = false
    public private(set) var playing = false

    public init(assertion: DisplaySleepPreventing = PowerAssertionDisplayAwake()) {
        self.assertion = assertion
    }

    public var isHolding: Bool { assertion.isHeld }

    public func update(enabled: Bool, playing: Bool) {
        self.enabled = enabled
        self.playing = playing
        if enabled && playing {
            _ = assertion.hold(reason: Self.reason)
        } else {
            assertion.release()
        }
    }
}
