import Foundation
import Combine

struct Fact: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var value: String {
        didSet { unopened = nil } // a typed-over value replaces what couldn't be read
    }
    var lastUsed: Date?
    var useCount: Int
    var appUsage: [String: FactUsage]
    var isSensitive: Bool

    /// Set when a locked value arrived encrypted and the key hasn't reached this
    /// Mac yet. Held verbatim so saving here can't destroy what another Mac wrote.
    private(set) var unopened: String?

    var isUnopened: Bool { unopened != nil }

    var isStored: Bool {
        isUnopened
            || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, value, lastUsed, useCount, appUsage, isSensitive
    }

    init(
        id: UUID = UUID(),
        name: String,
        value: String,
        lastUsed: Date? = nil,
        useCount: Int = 0,
        appUsage: [String: FactUsage] = [:],
        isSensitive: Bool = false
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.lastUsed = lastUsed
        self.useCount = useCount
        self.appUsage = appUsage
        self.isSensitive = isSensitive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed)
        useCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? (lastUsed == nil ? 0 : 1)
        appUsage = try container.decodeIfPresent([String: FactUsage].self, forKey: .appUsage) ?? [:]
        isSensitive = try container.decodeIfPresent(Bool.self, forKey: .isSensitive) ?? false

        let stored = try container.decode(String.self, forKey: .value)
        if Vault.isSealed(stored) {
            value = Vault.open(stored) ?? ""
            unopened = value.isEmpty ? stored : nil
        } else {
            value = stored
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(lastUsed, forKey: .lastUsed)
        try container.encode(useCount, forKey: .useCount)
        try container.encode(appUsage, forKey: .appUsage)
        try container.encode(isSensitive, forKey: .isSensitive)

        if let unopened {
            try container.encode(unopened, forKey: .value)
        } else if isSensitive, !value.isEmpty {
            // The same bytes go to disk and to iCloud, so falling back to
            // plaintext would publish the secret. Failing the encode instead
            // aborts the whole write, leaving the last good copy in place.
            guard let sealed = Vault.seal(value) else {
                BPLog.log("could not seal a locked fact; skipping this save")
                throw VaultError.couldNotSeal
            }
            try container.encode(sealed, forKey: .value)
        } else {
            try container.encode(value, forKey: .value)
        }
    }
}

enum VaultError: Error {
    case couldNotSeal
}

struct FactUsage: Codable, Equatable {
    var count: Int
    var lastUsed: Date
}

/// Stable per-install ID, used in iCloud sync payloads and license activations.
enum DeviceIdentifier {
    private static let key = "deviceID"

    static var current: String {
        if let saved = UserDefaults.standard.string(forKey: key) {
            return saved
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}

@MainActor
final class FactStore: ObservableObject {
    static let shared = FactStore()

    @Published var facts: [Fact] {
        didSet { scheduleSave() }
    }
    @Published private(set) var iCloudSyncEnabled: Bool
    @Published private(set) var iCloudStatus = "Syncing with iCloud"

    /// Set when a save was refused. The last good file is still on disk, but new
    /// edits aren't being saved, so the Facts tab shows a banner until it clears.
    @Published private(set) var saveFailure: String?

    private let fileURL: URL
    private let cloudStore = NSUbiquitousKeyValueStore.default
    private var saveTask: Task<Void, Never>?
    private var cloudObserver: NSObjectProtocol?
    private var isApplyingRemoteChange = false
    private var localRevision: Date

    private static let cloudPayloadKey = "factsPayload"
    private static let iCloudSyncEnabledKey = "iCloudSyncEnabled"
    private static let localRevisionKey = "factsRevision"

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backpocket", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("facts.json")
        localRevision = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: Self.localRevisionKey))
        iCloudSyncEnabled = UserDefaults.standard.object(forKey: Self.iCloudSyncEnabledKey) as? Bool ?? true

        let loadedFromDisk: Bool
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Fact].self, from: data) {
            facts = saved
            loadedFromDisk = true
        } else {
            facts = [Fact(name: "Email", value: "you@example.com")]
            loadedFromDisk = false
        }

        if iCloudSyncEnabled {
            startICloudSync(loadedFromDisk: loadedFromDisk)
        } else {
            iCloudStatus = "Off"
        }
    }

    var storedFactCount: Int {
        facts.lazy.filter(\.isStored).count
    }

    func isAvailable(_ fact: Fact, unlimited: Bool) -> Bool {
        guard !unlimited, fact.isStored else { return true }
        return facts.lazy.filter(\.isStored).prefix(LicenseManager.freeFactLimit).contains { $0.id == fact.id }
    }

    func availableFacts(unlimited: Bool) -> [Fact] {
        unlimited ? facts : Array(facts.lazy.filter(\.isStored).prefix(LicenseManager.freeFactLimit))
    }

    func add(unlimited: Bool) -> Fact? {
        guard unlimited || storedFactCount < LicenseManager.freeFactLimit else { return nil }
        let fact = Fact(name: "", value: "")
        facts.append(fact)
        return fact
    }

    func remove(_ id: UUID) {
        facts.removeAll { $0.id == id }
    }

    /// Stores text captured from the Services menu. Returns the existing fact
    /// when the value is already saved, and fills an untouched empty row before
    /// appending a new one.
    func captured(_ value: String, unlimited: Bool) -> Fact? {
        if let existing = facts.first(where: { $0.value == value }) {
            return existing
        }
        // An unopened fact also reads as empty, but its value is another Mac's
        // ciphertext waiting for a key, not a free row.
        if let index = facts.firstIndex(where: {
            !$0.isUnopened &&
            $0.name.trimmingCharacters(in: .whitespaces).isEmpty &&
            $0.value.trimmingCharacters(in: .whitespaces).isEmpty
        }) {
            facts[index].value = value
            return facts[index]
        }
        guard unlimited || storedFactCount < LicenseManager.freeFactLimit else { return nil }
        let fact = Fact(name: "", value: value)
        facts.append(fact)
        return fact
    }

    /// Applies an imported set: matching ids are updated in place, the rest are
    /// appended. Nothing already here is removed. Returns how many were new.
    struct MergeResult {
        var added = 0
        var skipped = 0
    }

    @discardableResult
    func merge(_ incoming: [Fact], unlimited: Bool) -> MergeResult {
        var result = MergeResult()
        for fact in incoming {
            guard !fact.name.isEmpty || !fact.value.isEmpty else { continue }
            if let index = facts.firstIndex(where: { $0.id == fact.id }) {
                facts[index].name = fact.name
                facts[index].value = fact.value
                facts[index].isSensitive = fact.isSensitive
            } else if unlimited || storedFactCount < LicenseManager.freeFactLimit {
                facts.append(fact)
                result.added += 1
            } else {
                result.skipped += 1
            }
        }
        return result
    }

    func markUsed(_ id: UUID, appIdentifier: String?) {
        guard let index = facts.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        facts[index].lastUsed = now
        facts[index].useCount += 1

        if let appIdentifier {
            var usage = facts[index].appUsage[appIdentifier] ?? FactUsage(count: 0, lastUsed: now)
            usage.count += 1
            usage.lastUsed = now
            facts[index].appUsage[appIdentifier] = usage
            pruneAppUsage(for: index)
        }
    }

    private func pruneAppUsage(for index: Int) {
        let maxTrackedApps = 24
        guard facts[index].appUsage.count > maxTrackedApps else { return }

        facts[index].appUsage = facts[index].appUsage
            .sorted { $0.value.lastUsed > $1.value.lastUsed }
            .prefix(maxTrackedApps)
            .reduce(into: [:]) { partial, entry in
                partial[entry.key] = entry.value
            }
    }

    func setICloudSyncEnabled(_ enabled: Bool) {
        guard iCloudSyncEnabled != enabled else { return }

        iCloudSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.iCloudSyncEnabledKey)

        if enabled {
            startICloudSync(loadedFromDisk: true)
        } else {
            stopICloudSync()
        }
    }

    /// Coalesces the per-keystroke edits from the settings fields into one write.
    private func scheduleSave() {
        let updateRevision = !isApplyingRemoteChange
        let syncToCloud = iCloudSyncEnabled && updateRevision
        // The revision moves at edit time, not at write time: during the debounce
        // the local copy is already newer than anything remote, and a payload
        // landing mid-typing must not be allowed to outrank it.
        if updateRevision { bumpRevision() }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            save(updateRevision: false, syncToCloud: syncToCloud)
        }
    }

    private func bumpRevision() {
        localRevision = Date()
        UserDefaults.standard.set(localRevision.timeIntervalSince1970, forKey: Self.localRevisionKey)
    }

    private func save(updateRevision: Bool, syncToCloud: Bool) {
        if updateRevision { bumpRevision() }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // A fact that cannot be sealed fails the whole encode; writing a partial
        // or plaintext file would be worse than keeping the last good one.
        guard let data = try? encoder.encode(facts) else {
            BPLog.log("skipped save: facts could not be encoded")
            saveFailure = "A locked fact couldn't be encrypted, so recent changes aren't being saved. Unlock this Mac's Keychain, or unlock the fact to store it as ordinary text."
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            saveFailure = nil
        } catch {
            BPLog.log("save failed: \(error.localizedDescription)")
            saveFailure = "Couldn't write to \(fileURL.path): \(error.localizedDescription)"
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        if syncToCloud {
            pushToICloud()
        }
    }

    private func startICloudSync(loadedFromDisk: Bool) {
        guard iCloudSyncEnabled else {
            iCloudStatus = "Off"
            return
        }

        iCloudStatus = "Syncing with iCloud"
        if cloudObserver != nil {
            cloudStore.synchronize()
            return
        }

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

    private func stopICloudSync() {
        if let cloudObserver {
            NotificationCenter.default.removeObserver(cloudObserver)
            self.cloudObserver = nil
        }

        iCloudStatus = "Off"
    }

    private func handleICloudChange(_ notification: Notification) {
        guard iCloudSyncEnabled,
              changedCloudKeys(from: notification).contains(Self.cloudPayloadKey),
              let remote = loadRemotePayload(),
              remote.revision > localRevision
        else { return }

        applyRemotePayload(remote)
    }

    private func changedCloudKeys(from notification: Notification) -> Set<String> {
        // An account change carries no key list; treating it as "our payload
        // changed" would let a different Apple Account's facts replace these.
        let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        guard reason == NSUbiquitousKeyValueStoreServerChange
            || reason == NSUbiquitousKeyValueStoreInitialSyncChange
        else { return [] }

        let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        return Set(keys ?? [Self.cloudPayloadKey])
    }

    private func loadRemotePayload() -> SyncedFacts? {
        guard iCloudSyncEnabled else { return nil }

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
        save(updateRevision: false, syncToCloud: false)
        iCloudStatus = "On"
    }

    private func pushToICloud() {
        guard iCloudSyncEnabled else { return }

        if localRevision.timeIntervalSince1970 == 0 {
            localRevision = Date()
            UserDefaults.standard.set(localRevision.timeIntervalSince1970, forKey: Self.localRevisionKey)
        }

        let payload = SyncedFacts(facts: facts, revision: localRevision, deviceID: DeviceIdentifier.current)
        guard let data = try? JSONEncoder().encode(payload) else {
            iCloudStatus = "Could not sync"
            return
        }

        cloudStore.set(data, forKey: Self.cloudPayloadKey)
        cloudStore.synchronize()
        iCloudStatus = "On"
    }
}

private struct SyncedFacts: Codable {
    var facts: [Fact]
    var revision: Date
    var deviceID: String
}
