import Foundation

/// Tracks whether the screen is locked, from the system's distributed
/// notifications. These are long-standing but undocumented names.
@MainActor
public final class ScreenLockMonitor: ObservableObject {
    public static let lockedNotification = Notification.Name("com.apple.screenIsLocked")
    public static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    @Published public private(set) var isLocked = false

    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    /// Pass a plain `NotificationCenter` in tests.
    public init(center: NotificationCenter = DistributedNotificationCenter.default()) {
        self.center = center
        observers.append(center.addObserver(forName: Self.lockedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(true) }
        })
        observers.append(center.addObserver(forName: Self.unlockedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(false) }
        })
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    private func set(_ locked: Bool) {
        if isLocked != locked { isLocked = locked }
    }
}
