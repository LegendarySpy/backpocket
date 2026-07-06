import Foundation
import Combine

struct Fact: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var value: String
    var lastUsed: Date?
    var isSensitive: Bool

    init(id: UUID = UUID(), name: String, value: String, lastUsed: Date? = nil, isSensitive: Bool = false) {
        self.id = id
        self.name = name
        self.value = value
        self.lastUsed = lastUsed
        self.isSensitive = isSensitive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(String.self, forKey: .value)
        lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed)
        isSensitive = try container.decodeIfPresent(Bool.self, forKey: .isSensitive) ?? false
    }
}

@MainActor
final class FactStore: ObservableObject {
    static let shared = FactStore()

    @Published var facts: [Fact] {
        didSet { scheduleSave() }
    }

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backpocket", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("facts.json")

        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Fact].self, from: data) {
            facts = saved
        } else {
            facts = [Fact(name: "Email", value: "you@example.com")]
        }
    }

    func add() -> Fact {
        let fact = Fact(name: "", value: "")
        facts.append(fact)
        return fact
    }

    func remove(_ id: UUID) {
        facts.removeAll { $0.id == id }
    }

    func markUsed(_ id: UUID) {
        guard let index = facts.firstIndex(where: { $0.id == id }) else { return }
        facts[index].lastUsed = Date()
    }

    /// Coalesces the per-keystroke edits from the settings fields into one write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(facts) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
