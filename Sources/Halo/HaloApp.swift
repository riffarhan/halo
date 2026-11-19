import AppKit
import SwiftUI

@main
struct HaloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var lights = LightController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(lights)
        } label: {
            Image(systemName: lights.settings.isOn && lights.connected ? "lightspectrum.horizontal" : "lightbulb.slash")
        }
        .menuBarExtraStyle(.window)
    }
}

extension LightController {
    static let shared = LightController()
}

/// AppKit-managed so it can be opened from anywhere: the menu, a halo://settings link,
/// or opening Halo again from Finder/Spotlight while it's already running.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(LightController.shared))
            let w = NSWindow(contentViewController: host)
            w.title = "Halo"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.setContentSize(NSSize(width: 500, height: 700))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }
        MainActor.assumeIsolated { LightController.shared.handle(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { SettingsWindow.shared.show() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { LightController.shared.shutdown() }
    }
}
