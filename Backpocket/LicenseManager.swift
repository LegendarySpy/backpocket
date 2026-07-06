import Foundation
import Security

enum LicenseState: Equatable {
    case missing
    case validating
    case active(LicenseSnapshot)
    case inactive(String)
    case misconfigured

    var isLicensed: Bool {
        if case .active = self { true } else { false }
    }

    var summary: String {
        switch self {
        case .missing:
            "Free"
        case .validating:
            "Checking license"
        case .active:
            "Unlimited"
        case .inactive(let reason):
            reason
        case .misconfigured:
            "Free"
        }
    }
}

struct LicenseSnapshot: Codable, Equatable {
    var displayKey: String
    var status: String
    var activationID: String?
    var customerEmail: String?
    var expiresAt: Date?
    var lastValidatedAt: Date

    var isUsable: Bool {
        status == "granted" && expiresAt.map { $0 > Date() } != false
    }
}

@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()
    static let freeFactLimit = 5

    @Published private(set) var state: LicenseState
    @Published private(set) var isWorking = false

    private let client: PolarLicenseClient
    private var keychain: LicenseKeychain
    private let defaults = UserDefaults.standard
    private let offlineGrace: TimeInterval = 7 * 24 * 60 * 60

    private static let snapshotKey = "polarLicenseSnapshot"
    private static let deviceIDKey = "polarLicenseDeviceID"

    init(
        client: PolarLicenseClient = PolarLicenseClient(),
        keychain: LicenseKeychain = LicenseKeychain()
    ) {
        self.client = client
        self.keychain = keychain

        // A cached snapshot only grants access alongside the key in the Keychain,
        // so an edited or forged UserDefaults snapshot can't unlock the app on its own.
        let hasStoredKey = keychain.licenseKey != nil
        if client.isConfigured, hasStoredKey, let snapshot = Self.loadSnapshot(from: defaults), Self.snapshotIsFresh(snapshot) {
            state = snapshot.isUsable ? .active(snapshot) : .inactive(Self.inactiveReason(for: snapshot))
        } else if client.isConfigured, !hasStoredKey {
            state = .missing
        } else if client.isConfigured {
            state = .inactive("Needs license check")
        } else {
            state = .misconfigured
        }
    }

    func refresh() {
        guard !isWorking else { return }
        guard client.isConfigured else {
            state = .misconfigured
            return
        }
        guard let key = keychain.licenseKey else {
            // Being licensed requires the key in the Keychain. If it's genuinely
            // gone the user is unlicensed — but never wipe the cached snapshot on a
            // mere read failure; only an explicit "Remove" clears stored data.
            state = currentSnapshot == nil ? .missing : .inactive("License key not found on this Mac")
            return
        }

        isWorking = true
        state = .validating

        Task {
            do {
                let response = try await client.validate(key: key, activationID: currentSnapshot?.activationID)
                applyValidatedLicense(response)
            } catch {
                applyValidationFailure(error)
            }
            isWorking = false
        }
    }

    func activate(key rawKey: String) {
        guard !isWorking else { return }
        guard client.isConfigured else {
            state = .misconfigured
            return
        }

        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            state = .inactive("Enter a license key")
            return
        }

        isWorking = true
        state = .validating

        Task {
            do {
                let response = try await client.validate(key: key, activationID: nil)
                if response.requiresActivation {
                    let activation = try await client.activate(key: key, label: activationLabel, meta: activationMeta)
                    keychain.licenseKey = key
                    applyActivatedLicense(activation)
                } else {
                    keychain.licenseKey = key
                    applyValidatedLicense(response)
                }
            } catch {
                applyValidationFailure(error)
            }
            isWorking = false
        }
    }

    func deactivate() {
        guard !isWorking else { return }
        guard let key = keychain.licenseKey else {
            clearStoredLicense()
            return
        }

        let activationID = currentSnapshot?.activationID
        guard client.isConfigured, let activationID else {
            clearStoredLicense()
            return
        }

        isWorking = true
        Task {
            do {
                try await client.deactivate(key: key, activationID: activationID)
            } catch {
                BPLog.log("Polar deactivate failed: \(error.localizedDescription)")
            }
            clearStoredLicense()
            isWorking = false
        }
    }

    var currentSnapshot: LicenseSnapshot? {
        Self.loadSnapshot(from: defaults)
    }

    private var activationLabel: String {
        Host.current().localizedName ?? "Mac"
    }

    private var activationMeta: [String: String] {
        [
            "bundle_id": Bundle.main.bundleIdentifier ?? "com.backpocket.mac",
            "device_id": deviceID,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        ]
    }

    private var deviceID: String {
        if let existing = defaults.string(forKey: Self.deviceIDKey) {
            return existing
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.deviceIDKey)
        return id
    }

    private func applyActivatedLicense(_ activation: PolarActivationResponse) {
        let license = activation.licenseKey
        let snapshot = LicenseSnapshot(
            displayKey: license.displayKey ?? license.key,
            status: license.status ?? "granted",
            activationID: activation.id,
            customerEmail: license.customer?.email,
            expiresAt: license.expiresAt,
            lastValidatedAt: Date()
        )
        save(snapshot)
    }

    private func applyValidatedLicense(_ license: PolarLicenseResponse) {
        let snapshot = LicenseSnapshot(
            displayKey: license.displayKey ?? license.key,
            status: license.status,
            activationID: license.activation?.id ?? currentSnapshot?.activationID,
            customerEmail: license.customer?.email,
            expiresAt: license.expiresAt,
            lastValidatedAt: Date()
        )
        save(snapshot)
    }

    private func applyValidationFailure(_ error: Error) {
        if let snapshot = currentSnapshot, snapshot.isUsable, Self.snapshotIsFresh(snapshot, grace: offlineGrace) {
            state = .active(snapshot)
            BPLog.log("Polar validation failed; using cached license: \(error.localizedDescription)")
            return
        }

        state = .inactive(error.userMessage)
        BPLog.log("Polar license check failed: \(error.localizedDescription)")
    }

    private func save(_ snapshot: LicenseSnapshot) {
        if let data = try? JSONEncoder.license.encode(snapshot) {
            defaults.set(data, forKey: Self.snapshotKey)
        }
        state = snapshot.isUsable ? .active(snapshot) : .inactive(Self.inactiveReason(for: snapshot))
    }

    private func clearStoredLicense() {
        keychain.licenseKey = nil
        defaults.removeObject(forKey: Self.snapshotKey)
        state = client.isConfigured ? .missing : .misconfigured
    }

    private static func loadSnapshot(from defaults: UserDefaults) -> LicenseSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder.license.decode(LicenseSnapshot.self, from: data)
    }

    private static func snapshotIsFresh(_ snapshot: LicenseSnapshot, grace: TimeInterval = 7 * 24 * 60 * 60) -> Bool {
        Date().timeIntervalSince(snapshot.lastValidatedAt) < grace
    }

    private static func inactiveReason(for snapshot: LicenseSnapshot) -> String {
        if snapshot.expiresAt.map({ $0 <= Date() }) == true {
            return "License expired"
        }
        return "License \(snapshot.status)"
    }
}

struct PolarLicenseClient {
    private let session: URLSession
    private let decoder = JSONDecoder.license

    init(session: URLSession = .shared) {
        self.session = session
    }

    var isConfigured: Bool {
        !organizationID.isEmpty && !organizationID.hasPrefix("$(")
            && !licenseBenefitID.isEmpty && !licenseBenefitID.hasPrefix("$(")
    }

    var checkoutURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BackpocketPolarCheckoutURL") as? String,
              !value.isEmpty,
              !value.hasPrefix("$(")
        else { return nil }
        return URL(string: value)
    }

    var portalURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BackpocketPolarPortalURL") as? String,
              !value.isEmpty,
              !value.hasPrefix("$(")
        else { return nil }
        return URL(string: value)
    }

    func validate(key: String, activationID: String?) async throws -> PolarLicenseResponse {
        var body: [String: Any] = [
            "key": key,
            "organization_id": organizationID,
            "benefit_id": licenseBenefitID
        ]
        if let activationID {
            body["activation_id"] = activationID
        }
        return try await post("validate", body: body, expectedStatus: 200)
    }

    func activate(key: String, label: String, meta: [String: String]) async throws -> PolarActivationResponse {
        try await post("activate", body: [
            "key": key,
            "organization_id": organizationID,
            "benefit_id": licenseBenefitID,
            "label": label,
            "meta": meta
        ], expectedStatus: 200)
    }

    func deactivate(key: String, activationID: String) async throws {
        let _: EmptyResponse = try await post("deactivate", body: [
            "key": key,
            "organization_id": organizationID,
            "benefit_id": licenseBenefitID,
            "activation_id": activationID
        ], expectedStatus: 204)
    }

    private var organizationID: String {
        (Bundle.main.object(forInfoDictionaryKey: "BackpocketPolarOrganizationID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var licenseBenefitID: String {
        (Bundle.main.object(forInfoDictionaryKey: "BackpocketPolarLicenseBenefitID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var baseURL: URL {
        let configured = Bundle.main.object(forInfoDictionaryKey: "BackpocketPolarAPIBaseURL") as? String
        let value = configured?.isEmpty == false && configured?.hasPrefix("$(") == false
            ? configured!
            : "https://api.polar.sh/v1"
        return URL(string: value)!
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], expectedStatus: Int) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent("customer-portal/license-keys/\(path)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PolarLicenseError.invalidResponse
        }
        guard http.statusCode == expectedStatus else {
            if http.statusCode == 403 { throw PolarLicenseError.notPermitted }
            if let apiError = try? decoder.decode(PolarAPIError.self, from: data) {
                throw PolarLicenseError.api(apiError.detail ?? apiError.error ?? "Polar returned \(http.statusCode)")
            }
            throw PolarLicenseError.api("Polar returned \(http.statusCode)")
        }
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        return try decoder.decode(T.self, from: data)
    }
}

struct PolarLicenseResponse: Decodable {
    var key: String
    var displayKey: String?
    var status: String
    var limitActivations: Int?
    var customer: PolarCustomer?
    var expiresAt: Date?
    var activation: PolarActivationBase?

    var requiresActivation: Bool {
        limitActivations != nil
    }

    enum CodingKeys: String, CodingKey {
        case key
        case displayKey = "display_key"
        case status
        case limitActivations = "limit_activations"
        case customer
        case expiresAt = "expires_at"
        case activation
    }
}

struct PolarActivationResponse: Decodable {
    var id: String
    var licenseKey: PolarActivatedLicense

    enum CodingKeys: String, CodingKey {
        case id
        case licenseKey = "license_key"
    }
}

struct PolarActivatedLicense: Decodable {
    var key: String
    var displayKey: String?
    var status: String?
    var customer: PolarCustomer?
    var expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case key
        case displayKey = "display_key"
        case status
        case customer
        case expiresAt = "expires_at"
    }
}

struct PolarActivationBase: Decodable {
    var id: String
}

struct PolarCustomer: Decodable {
    var email: String?
}

struct PolarAPIError: Decodable {
    var error: String?
    var detail: String?
}

struct EmptyResponse: Decodable {}

enum PolarLicenseError: LocalizedError {
    case api(String)
    case invalidResponse
    case notPermitted

    var errorDescription: String? {
        userMessage
    }

    var userMessage: String {
        switch self {
        case .api(let message):
            message
        case .invalidResponse:
            "Invalid Polar response"
        case .notPermitted:
            "No activations available"
        }
    }
}

private extension Error {
    var userMessage: String {
        if let polar = self as? PolarLicenseError {
            return polar.userMessage
        }
        return localizedDescription
    }
}

private extension JSONDecoder {
    static var license: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = ISO8601DateFormatter.polarFractional.date(from: value)
                ?? ISO8601DateFormatter.polar.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(value)")
        }
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }
}

private extension JSONEncoder {
    static var license: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension ISO8601DateFormatter {
    static let polarFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let polar: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

struct LicenseKeychain {
    private let service = "com.backpocket.mac.license"
    private let account = "polar-license-key"

    var licenseKey: String? {
        get {
            var query = baseQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            guard status == errSecSuccess,
                  let data = item as? Data,
                  let key = String(data: data, encoding: .utf8)
            else { return nil }
            return key
        }
        set {
            SecItemDelete(baseQuery as CFDictionary)
            guard let newValue, let data = newValue.data(using: .utf8) else { return }
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    // Data-protection keychain: items are scoped to the app's Team ID rather than a
    // specific code signature, so re-signed builds don't trigger an access prompt.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}
