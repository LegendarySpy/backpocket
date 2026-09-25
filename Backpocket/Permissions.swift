import ApplicationServices
import AppKit

/// Accessibility trust, watched live. Global event monitors registered while
/// untrusted never deliver, so the trigger has to be re-armed the moment the
/// user grants access instead of waiting for a relaunch.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var isTrusted = AXIsProcessTrusted()

    /// Called on every false -> true flip.
    var onTrustGained: (() -> Void)?

    private var timer: Timer?

    func startWatching() {
        refresh()
        guard !isTrusted, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        BPLog.log("accessibility trust -> \(trusted)")
        if trusted {
            timer?.invalidate()
            timer = nil
            onTrustGained?()
        } else {
            startWatching()
        }
    }

    func promptIfNeeded() {
        guard !isTrusted else { return }
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }
}
