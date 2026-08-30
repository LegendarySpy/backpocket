import Sparkle
import SwiftUI

/// Sparkle, plus the bit of state the About tab needs to answer "am I running
/// the latest version?" without the user having to start a check and read a modal.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    enum Status: Equatable {
        case unknown
        case checking
        case upToDate(Date)
        case available(String)
        case failed(String)
    }

    @Published private(set) var status = Status.unknown

    private var controller: SPUStandardUpdaterController!

    var canCheck: Bool {
        controller.updater.canCheckForUpdates
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        if let last = controller.updater.lastUpdateCheckDate {
            status = .upToDate(last)
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// A quiet check on launch, so the About tab is already accurate the first
    /// time it's opened rather than after the user prods it.
    func checkQuietly() {
        guard controller.updater.canCheckForUpdates else { return }
        status = .checking
        controller.updater.checkForUpdateInformation()
        // Sparkle drops a check that races an automatic one, and does so without
        // a delegate callback; without this the About tab spins forever.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            if case .checking = status { status = .unknown }
        }
    }

    var summary: String {
        switch status {
        case .unknown: "Not checked yet"
        case .checking: "Checking…"
        case .upToDate(let date): "Up to date · checked \(Self.relative.localizedString(for: date, relativeTo: Date()))"
        case .available(let version): "Version \(version) is available"
        case .failed(let message): message
        }
    }

    var isUpToDate: Bool {
        if case .upToDate = status { return true }
        return false
    }

    var hasUpdate: Bool {
        if case .available = status { return true }
        return false
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in status = .available(item.displayVersionString) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        Task { @MainActor in status = .upToDate(Date()) }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        guard let error = error as? NSError else { return }
        // "No update found" arrives here as an error too; it is good news.
        guard error.code != Int(Sparkle.SUError.noUpdateError.rawValue) else {
            Task { @MainActor in status = .upToDate(Date()) }
            return
        }
        Task { @MainActor in
            // Declining or cancelling the install ends the cycle with an error,
            // but the check itself succeeded and the update is still there.
            guard !hasUpdate, !Self.isCancellation(error) else { return }
            status = .failed("Could not check for updates")
        }
    }

    private static func isCancellation(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSUserCancelledError { return true }
        return error.code == Int(SUError.installationCanceledError.rawValue)
    }
}
