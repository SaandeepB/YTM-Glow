import AppKit
import SwiftUI
import YTMGlowCore

/// Menu bar icon and the settings popover.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?

    init(settings: AppSettings, engine: PlayerEngine, extensionSetup: ExtensionSetup) {
        super.init()
        let view = SettingsView(settings: settings, engine: engine, extensionSetup: extensionSetup) {
            NSApp.terminate(nil)
        }
        popover.contentViewController = NSHostingController(rootView: view)
        // Closed manually so the color panel can be used without dismissing it.
        popover.behavior = .applicationDefined
        popover.animates = true

        if let button = statusItem.button {
            button.image = MenuBarIcon.make()
            button.image?.accessibilityDescription = "YTM Glow"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        popover.isShown ? closePopover() : openPopover()
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)

        // Clicks in other apps close the popover (no permission needed for mouse monitors).
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                MainActor.assumeIsolated { self?.closePopover() }
                return nil
            }
            return event
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = escapeMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
        escapeMonitor = nil
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
    }
}

/// Template image for the menu bar: a screen outline with a lit edge and two lyric lines.
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let frame = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 3.25, width: 14.5, height: 11.5), xRadius: 3, yRadius: 3)
            frame.lineWidth = 1.5
            frame.stroke()

            // Lyric lines: one long, one short.
            NSBezierPath(roundedRect: NSRect(x: 4.5, y: 9.2, width: 9, height: 1.8), xRadius: 0.9, yRadius: 0.9).fill()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 6.2, width: 6, height: 1.8), xRadius: 0.9, yRadius: 0.9).fill()

            // Glow ticks outside the top edge.
            for x in [5.0, 9.0, 13.0] {
                NSBezierPath(roundedRect: NSRect(x: x - 0.6, y: 15.6, width: 1.2, height: 1.9), xRadius: 0.6, yRadius: 0.6).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
