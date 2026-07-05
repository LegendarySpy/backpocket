import SwiftUI

extension Notification.Name {
    static let openSettingsWindow = Notification.Name("openSettingsWindow")
}

@main
struct BackpocketApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            Text("Double-tap \(AppSettings.shared.trigger.symbol) to open the palette")
            Divider()
            Button("Settings…") { AppDelegate.shared?.showSettings() }
                .keyboardShortcut(",")
            Divider()
            Button("Quit Backpocket") { NSApp.terminate(nil) }
        } label: {
            MenuBarLabel()
        }

        Settings {
            SettingsRootView()
        }
    }
}

/// The menu bar icon doubles as the always-alive view context that can invoke
/// the sanctioned `openSettings` action from anywhere in the app.
private struct MenuBarLabel: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: "rectangle.stack.fill")
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

        OptionDoubleTap.shared.start {
            PaletteController.shared.toggle()
        }

        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
        if !trusted || !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            showSettings()
        }
    }

    func showSettings() {
        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
    }
}
