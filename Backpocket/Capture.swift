import AppKit

extension Notification.Name {
    static let factCaptured = Notification.Name("factCaptured")
}

/// Backs the "Save to Backpocket" entry in the right-click Services menu.
/// macOS hands over the selected text on a service pasteboard; we stash it as a
/// fact and open Settings so it can be named.
final class CaptureService: NSObject {
    /// Which fact the Facts tab should focus once it's on screen. Set before the
    /// Settings window exists, consumed after it appears.
    @MainActor private(set) static var pendingFocusID: UUID?

    @MainActor static func takePendingFocus() -> UUID? {
        defer { pendingFocusID = nil }
        return pendingFocusID
    }

    @objc func saveToBackpocket(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            error.pointee = "No text was selected."
            return
        }

        Task { @MainActor in
            guard let fact = FactStore.shared.captured(
                text,
                unlimited: LicenseManager.shared.state.isLicensed
            ) else {
                AppDelegate.shared?.showLicenseSettings()
                return
            }
            CaptureService.pendingFocusID = fact.id
            NotificationCenter.default.post(name: .factCaptured, object: nil)
            AppDelegate.shared?.showSettings()
        }
    }
}
