import SwiftUI

extension Notification.Name {
    static let openSettingsWindow = Notification.Name("openSettingsWindow")
}

@main
struct BackpocketApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }

        Settings {
            SettingsRootView()
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        if permissions.isTrusted {
            Text("Double-tap \(AppSettings.shared.trigger.symbol) to open the palette")
        } else {
            Text("Backpocket can't see your cursor yet")
            Button("Enable Accessibility Access…") { AppDelegate.shared?.showSettings() }
        }
        Divider()
        Button("Settings…") { AppDelegate.shared?.showSettings() }
            .keyboardShortcut(",")
        Button("Check for Updates…") { AppDelegate.shared?.checkForUpdates() }
        Divider()
        Button("Quit Backpocket") { NSApp.terminate(nil) }
    }
}

/// The menu bar icon doubles as the always-alive view context that can invoke
/// the sanctioned `openSettings` action from anywhere in the app.
private struct MenuBarLabel: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        Image("MenuBarIcon")
            .overlay(alignment: .bottomTrailing) {
                if !permissions.isTrusted {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .offset(x: 2, y: 2)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow)) { _ in
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.windows
                        .first { $0.identifier?.rawValue.contains("Settings") == true }?
                        .makeKeyAndOrderFront(nil)
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        CaretLocator.installMessagingTimeout()

        DoubleTapMonitor.shared.start {
            PaletteController.shared.toggle()
        }
        DoubleTapMonitor.shared.onFirstTap = {
            PaletteController.shared.prefetchAnchor()
        }
        // Its init registers the observer that warms Chromium accessibility trees.
        _ = PaletteController.shared
        _ = FactStore.shared

        NSApp.servicesProvider = CaptureService()
        NSUpdateDynamicServices()

        // Monitors registered before trust exists deliver nothing; re-arm on grant
        // so the trigger starts working without a relaunch.
        Permissions.shared.onTrustGained = { DoubleTapMonitor.shared.restart() }
        Permissions.shared.startWatching()
        Permissions.shared.promptIfNeeded()

        if !Permissions.shared.isTrusted || !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            showSettings()
        }
        LicenseManager.shared.refresh()
        Updater.shared.checkQuietly()
    }

    func showSettings() {
        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
    }

    func showLicenseSettings() {
        showSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .licenseRequired, object: nil)
        }
    }

    @MainActor
    func checkForUpdates() {
        Updater.shared.checkForUpdates()
    }
}
