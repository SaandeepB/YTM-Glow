import Foundation
import IOKit.pwr_mgt
import Testing
@testable import YTMGlowCore

final class FakeAssertion: DisplaySleepPreventing {
    private(set) var isHeld = false
    private(set) var holds = 0
    private(set) var releases = 0
    var failNextHold = false

    func hold(reason: String) -> Bool {
        if failNextHold { failNextHold = false; return false }
        if !isHeld { holds += 1 }
        isHeld = true
        return true
    }

    func release() {
        if isHeld { releases += 1 }
        isHeld = false
    }
}

@MainActor
@Suite struct DisplayAwakeTests {
    @Test func holdsOnlyWhileEnabledAndPlaying() {
        let fake = FakeAssertion()
        let controller = DisplayAwakeController(assertion: fake)
        controller.update(enabled: false, playing: true)
        #expect(!fake.isHeld)
        controller.update(enabled: true, playing: false)
        #expect(!fake.isHeld)
        controller.update(enabled: true, playing: true)
        #expect(fake.isHeld)
        // Repeated 2 Hz updates don't stack assertions.
        for _ in 0..<10 { controller.update(enabled: true, playing: true) }
        #expect(fake.holds == 1)
        controller.update(enabled: true, playing: false)
        #expect(!fake.isHeld)
        controller.update(enabled: true, playing: true)
        controller.update(enabled: false, playing: true)
        #expect(!fake.isHeld)
        #expect(fake.holds == 2 && fake.releases == 2)
    }

    @Test func realPowerAssertionIsVisibleToTheSystem() throws {
        let assertion = PowerAssertionDisplayAwake()
        #expect(assertion.hold(reason: "YTM Glow test assertion"))
        #expect(assertion.isHeld)
        #expect(assertion.hold(reason: "again"), "holding twice is a no-op")

        var byProcess: Unmanaged<CFDictionary>?
        #expect(IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess)
        let dictionary = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] ?? [:]
        let ours = dictionary[NSNumber(value: getpid())] ?? []
        #expect(ours.contains { ($0[kIOPMAssertionNameKey] as? String) == "YTM Glow test assertion" })
        #expect(ours.contains { ($0[kIOPMAssertionTypeKey] as? String) == kIOPMAssertionTypePreventUserIdleDisplaySleep })

        assertion.release()
        #expect(!assertion.isHeld)
        var after: Unmanaged<CFDictionary>?
        _ = IOPMCopyAssertionsByProcess(&after)
        let remaining = (after?.takeRetainedValue() as? [NSNumber: [[String: Any]]])?[NSNumber(value: getpid())] ?? []
        #expect(!remaining.contains { ($0[kIOPMAssertionNameKey] as? String) == "YTM Glow test assertion" })
    }
}

@MainActor
@Suite struct ScreenLockMonitorTests {
    @Test func followsLockAndUnlockNotifications() async {
        let center = NotificationCenter()
        let monitor = ScreenLockMonitor(center: center)
        #expect(!monitor.isLocked)
        center.post(name: ScreenLockMonitor.lockedNotification, object: nil)
        #expect(await waitUntil { monitor.isLocked })
        center.post(name: ScreenLockMonitor.lockedNotification, object: nil)
        #expect(monitor.isLocked)
        center.post(name: ScreenLockMonitor.unlockedNotification, object: nil)
        #expect(await waitUntil { !monitor.isLocked })
    }
}

@Suite struct SkyLightSpaceTests {
    /// Proves the private API surface still exists on the OS running the tests
    /// (CI: macOS 15; locally: macOS 26). Doesn't create a space.
    @Test func requiredPrivateSymbolsExist() {
        #expect(SkyLightSpace.missingSymbols == [])
        #expect(SkyLightSpace.isSupported)
    }

    /// Creates a real above-lock-screen space. Opt-in, needs a GUI session:
    /// `YTMGLOW_SKYLIGHT_SMOKE=1 swift test --filter SkyLightSpaceTests`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YTMGLOW_SKYLIGHT_SMOKE"] == "1"))
    func createsASpace() throws {
        let space = try #require(SkyLightSpace())
        #expect(space.spaceID != 0)
        #expect(!space.adopt(windowNumber: 0), "invalid window numbers are refused")
    }
}
