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
    @Published private(set) var iCloudStatus = "Syncing with iCloud"

    private let fileURL: URL
    private let cloudStore = NSUbiquitousKeyValueStore.default
    private var saveTask: Task<Void, Never>?
    private var cloudObserver: NSObjectProtocol?
    private var isApplyingRemoteChange = false
    private var localRevision: Date

    private static let cloudPayloadKey = "factsPayload"
    private static let localRevisionKey = "factsRevision"
    private static let deviceIDKey = "deviceID"

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backpocket", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("facts.json")
        localRevision = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: Self.localRevisionKey))

        let loadedFromDisk: Bool
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Fact].self, from: data) {
            facts = saved
            loadedFromDisk = true
        } else {
            facts = [Fact(name: "Email", value: "you@example.com")]
            loadedFromDisk = false
        }

        startICloudSync(loadedFromDisk: loadedFromDisk)
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
        let syncToCloud = !isApplyingRemoteChange
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            save(syncToCloud: syncToCloud)
        }
    }

    private func save(syncToCloud: Bool) {
        if syncToCloud {
            localRevision = Date()
            UserDefaults.standard.set(localRevision.timeIntervalSince1970, forKey: Self.localRevisionKey)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(facts) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        if syncToCloud {
            pushToICloud()
        }
    }

    private func startICloudSync(loadedFromDisk: Bool) {
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleICloudChange(notification)
            }
        }

        cloudStore.synchronize()

        guard let remote = loadRemotePayload() else {
            pushToICloud()
            return
        }

        if !loadedFromDisk || remote.revision > localRevision {
            applyRemotePayload(remote)
        } else {
            pushToICloud()
        }
    }

    private func handleICloudChange(_ notification: Notification) {
        guard changedCloudKeys(from: notification).contains(Self.cloudPayloadKey),
              let remote = loadRemotePayload(),
              remote.revision > localRevision
        else { return }

        applyRemotePayload(remote)
    }

    private func changedCloudKeys(from notification: Notification) -> Set<String> {
        let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        return Set(keys ?? [Self.cloudPayloadKey])
    }

    private func loadRemotePayload() -> SyncedFacts? {
        guard let data = cloudStore.data(forKey: Self.cloudPayloadKey),
              let payload = try? JSONDecoder().decode(SyncedFacts.self, from: data)
        else {
            iCloudStatus = "Not available"
            return nil
        }

        iCloudStatus = "On"
        return payload
    }

    private func applyRemotePayload(_ payload: SyncedFacts) {
        isApplyingRemoteChange = true
        facts = payload.facts
        isApplyingRemoteChange = false

        localRevision = payload.revision
        UserDefaults.standard.set(localRevision.timeIntervalSince1970, forKey: Self.localRevisionKey)
        save(syncToCloud: false)
        iCloudStatus = "On"
    }

    private func pushToICloud() {
        if localRevision.timeIntervalSince1970 == 0 {
            localRevision = Date()
            UserDefaults.standard.set(localRevision.timeIntervalSince1970, forKey: Self.localRevisionKey)
        }

        let payload = SyncedFacts(facts: facts, revision: localRevision, deviceID: deviceID)
        guard let data = try? JSONEncoder().encode(payload) else {
            iCloudStatus = "Could not sync"
            return
        }

        cloudStore.set(data, forKey: Self.cloudPayloadKey)
        cloudStore.synchronize()
        iCloudStatus = "On"
    }

    private var deviceID: String {
        if let saved = UserDefaults.standard.string(forKey: Self.deviceIDKey) {
            return saved
        }

        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: Self.deviceIDKey)
        return id
    }
}

private struct SyncedFacts: Codable {
    var facts: [Fact]
    var revision: Date
    var deviceID: String
}
