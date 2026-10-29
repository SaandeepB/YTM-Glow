import AppKit

// Menu bar only: no Dock icon even when run outside the .app bundle.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
