import AppKit

/// Helps the user load the bundled Chrome extension.
///
/// The app bundle carries a copy of `extension/`. It is copied to a stable
/// folder in Application Support so Chrome keeps finding it even if the app
/// is moved or rebuilt.
@MainActor
struct ExtensionSetup {
    static var installDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("YTMGlow/ChromeExtension", isDirectory: true)
    }

    var bundledExtension: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("extension", isDirectory: true),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else { return nil }
        return url
    }

    func revealExtension() {
        guard let source = bundledExtension else {
            showInstructions(path: nil)
            return
        }
        let destination = Self.installDirectory
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            showInstructions(path: destination.path)
        } catch {
            showInstructions(path: source.path)
        }
    }

    private func showInstructions(path: String?) {
        let alert = NSAlert()
        alert.messageText = "Load the YTM Glow extension"
        let location = path.map { "Folder: \($0)\n\n" } ?? "Use the extension/ folder from the YTM Glow source checkout.\n\n"
        alert.informativeText = location + """
        1. Open chrome://extensions (or brave://, edge://, arc://extensions).
        2. Turn on Developer mode.
        3. Click "Load unpacked" and choose the folder above.
        4. Reload any open music.youtube.com tabs.
        """
        alert.addButton(withTitle: "Copy chrome://extensions")
        alert.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("chrome://extensions", forType: .string)
        }
    }
}
