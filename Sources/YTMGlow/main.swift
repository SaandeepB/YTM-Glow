import AppKit

let app = NSApplication.shared
// Menu bar only: no Dock icon even when run outside the .app bundle.
app.setActivationPolicy(.accessory)

if let flag = CommandLine.arguments.firstIndex(of: "--render-previews") {
    let directory = CommandLine.arguments.indices.contains(flag + 1) ? CommandLine.arguments[flag + 1] : "previews"
    Task { @MainActor in
        let failures = await PreviewRenderer.run(outputDirectory: URL(fileURLWithPath: directory))
        exit(failures)
    }
    app.run()
} else {
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    app.run()
}
