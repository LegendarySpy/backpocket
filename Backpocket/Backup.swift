import AppKit
import UniformTypeIdentifiers

/// Plain JSON backup. An export is the one place a locked value leaves the app
/// in the clear, so it asks for Touch ID first and says so on the panel — a
/// backup you can't read on a Mac that lost its key is not a backup.
@MainActor
enum Backup {
    private static let formatVersion = 1

    private struct Document: Codable {
        var app: String
        var formatVersion: Int
        var exportedAt: Date
        var facts: [Entry]
    }

    private struct Entry: Codable {
        var id: UUID
        var name: String
        var value: String
        var isSensitive: Bool
    }

    // MARK: - Export

    static func export(_ facts: [Fact], onFailure: @escaping (String) -> Void) {
        // Anything still waiting on its key has no plaintext to write, and
        // exporting its ciphertext would look like data while being unreadable.
        let exportable = facts.filter { !$0.isUnopened && !$0.value.isEmpty }
        guard !exportable.isEmpty else {
            return onFailure("There's nothing to export yet.")
        }

        let write = {
            writeExport(exportable, onFailure: onFailure)
        }
        if exportable.contains(where: \.isSensitive) {
            Auth.requireIfNeeded(reason: "export your facts, including locked ones, in the clear", onSuccess: write)
        } else {
            write()
        }
    }

    private static func writeExport(_ facts: [Fact], onFailure: @escaping (String) -> Void) {
        let panel = NSSavePanel()
        panel.title = "Export Facts"
        panel.message = "Values are saved in plain text, including locked ones. Keep this file somewhere safe."
        panel.nameFieldStringValue = "Backpocket Facts.json"
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try documentData(for: facts)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            BPLog.log("exported \(facts.count) facts")
        } catch {
            BPLog.log("export failed: \(error.localizedDescription)")
            onFailure("Couldn't write the export: \(error.localizedDescription)")
        }
    }

    /// The file's contents, split from the panel so the format can be exercised
    /// without a window on screen.
    static func documentData(for facts: [Fact]) throws -> Data {
        let document = Document(
            app: "Backpocket",
            formatVersion: formatVersion,
            exportedAt: Date(),
            facts: facts.map {
                Entry(id: $0.id, name: $0.name, value: $0.value, isSensitive: $0.isSensitive)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    enum RestoreError: LocalizedError {
        case notBackpocket, tooNew, unreadable

        var errorDescription: String? {
            switch self {
            case .notBackpocket: "That doesn't look like a Backpocket export."
            case .tooNew: "That export was made by a newer version of Backpocket."
            case .unreadable: "Couldn't read that file."
            }
        }
    }

    static func facts(fromDocument data: Data) throws -> [Fact] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(Document.self, from: data) else {
            throw RestoreError.unreadable
        }
        guard document.app == "Backpocket" else { throw RestoreError.notBackpocket }
        guard document.formatVersion <= formatVersion else { throw RestoreError.tooNew }
        return document.facts.map {
            Fact(id: $0.id, name: $0.name, value: $0.value, isSensitive: $0.isSensitive)
        }
    }

    // MARK: - Import

    /// Merges by id: a fact that came from this backup is updated in place,
    /// anything new is appended, and nothing already here is deleted.
    static func restore(into store: FactStore, onFailure: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Import Facts"
        panel.message = "Choose a Backpocket export. Existing facts are updated, none are removed."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let imported = try facts(fromDocument: try Data(contentsOf: url))
            let result = store.merge(imported, unlimited: LicenseManager.shared.state.isLicensed)
            BPLog.log("imported \(imported.count) facts, \(result.added) new, \(result.skipped) over plan limit")
            if result.skipped > 0 {
                onFailure("Imported what fits on the free plan. Unlock unlimited facts to add the remaining \(result.skipped).")
            }
        } catch {
            onFailure(error.localizedDescription)
        }
    }
}
