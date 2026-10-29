import Foundation

/// A private WindowServer "space" that sits above the lock screen.
///
/// **Private API, experimental.** macOS has no public way to draw over the
/// lock screen. This uses five undocumented SkyLight functions, the same
/// approach as the MIT-licensed SkyLightWindow package by Lakr233
/// (https://github.com/Lakr233/SkyLightWindow):
///
/// 1. `SLSMainConnectionID()` — this process's WindowServer connection.
/// 2. `SLSSpaceCreate(cid, 1, 0)` — a new space.
/// 3. `SLSSpaceSetAbsoluteLevel(cid, space, 400)` — 400 sits above the
///    screen-lock level (300); it's the level Notification Center uses there.
/// 4. `SLSShowSpaces(cid, [space])` — make it visible.
/// 5. `SLSSpaceAddWindowsAndRemoveFromSpaces(cid, space, [windowNumber], 7)`
///    — move a window into it.
///
/// Unlike a straight port, every symbol is looked up and checked, so if a
/// future macOS removes one this returns nil instead of crashing. Space IDs
/// are 64-bit (`uint64_t` in WindowServer); declaring them as 32-bit leaves
/// the upper half of the argument register undefined on arm64, which made
/// space creation fail intermittently in testing.
/// Windows moved here stay above everything until closed; callers should use
/// dedicated windows and close them when the screen unlocks.
public final class SkyLightSpace: @unchecked Sendable {
    public static let lockScreenLevel: Int32 = 400

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsAndRemoveFromSpaces = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    private struct Symbols {
        let mainConnectionID: MainConnectionID
        let spaceCreate: SpaceCreate
        let spaceSetAbsoluteLevel: SpaceSetAbsoluteLevel
        let showSpaces: ShowSpaces
        let addWindows: AddWindowsAndRemoveFromSpaces
    }

    static let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
    static let requiredSymbols = [
        "SLSMainConnectionID", "SLSSpaceCreate", "SLSSpaceSetAbsoluteLevel",
        "SLSShowSpaces", "SLSSpaceAddWindowsAndRemoveFromSpaces",
    ]

    private let symbols: Symbols
    private let connection: Int32
    public let spaceID: UInt64

    /// Whether every private symbol this needs exists on this macOS.
    public static var isSupported: Bool { loadSymbols() != nil }

    /// Names of required symbols missing on this system (empty when supported).
    public static var missingSymbols: [String] {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else { return requiredSymbols }
        return requiredSymbols.filter { dlsym(handle, $0) == nil }
    }

    /// Creates and shows the space. Returns nil if SkyLight isn't usable.
    public init?(level: Int32 = SkyLightSpace.lockScreenLevel) {
        guard let symbols = Self.loadSymbols() else { return nil }
        let connection = symbols.mainConnectionID()
        guard connection != 0 else { return nil }
        let space = symbols.spaceCreate(connection, 1, 0)
        guard space != 0 else { return nil }
        guard symbols.spaceSetAbsoluteLevel(connection, space, level) == 0,
              symbols.showSpaces(connection, [NSNumber(value: space)] as CFArray) == 0 else { return nil }
        self.symbols = symbols
        self.connection = connection
        spaceID = space
    }

    /// Moves a window (by `NSWindow.windowNumber`) into this space.
    @discardableResult
    public func adopt(windowNumber: Int) -> Bool {
        guard windowNumber > 0 else { return false }
        return symbols.addWindows(connection, spaceID, [NSNumber(value: windowNumber)] as CFArray, 7) == 0
    }

    private static func loadSymbols() -> Symbols? {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY),
              let main = dlsym(handle, "SLSMainConnectionID"),
              let create = dlsym(handle, "SLSSpaceCreate"),
              let level = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let show = dlsym(handle, "SLSShowSpaces"),
              let add = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces") else { return nil }
        return Symbols(
            mainConnectionID: unsafeBitCast(main, to: MainConnectionID.self),
            spaceCreate: unsafeBitCast(create, to: SpaceCreate.self),
            spaceSetAbsoluteLevel: unsafeBitCast(level, to: SpaceSetAbsoluteLevel.self),
            showSpaces: unsafeBitCast(show, to: ShowSpaces.self),
            addWindows: unsafeBitCast(add, to: AddWindowsAndRemoveFromSpaces.self)
        )
    }
}
