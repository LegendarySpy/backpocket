import ServiceManagement
import SwiftUI

enum TriggerModifier: String, CaseIterable, Identifiable {
    case option, control, command, shift
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .option: "⌥"
        case .control: "⌃"
        case .command: "⌘"
        case .shift: "⇧"
        }
    }

    var label: String {
        switch self {
        case .option: "⌥ Option"
        case .control: "⌃ Control"
        case .command: "⌘ Command"
        case .shift: "⇧ Shift"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var trigger: TriggerModifier {
        didSet { UserDefaults.standard.set(trigger.rawValue, forKey: "trigger") }
    }

    init() {
        trigger = TriggerModifier(rawValue: UserDefaults.standard.string(forKey: "trigger") ?? "") ?? .option
    }
}

struct SettingsRootView: View {
    var body: some View {
        TabView {
            FactsTab()
                .tabItem { Label("Facts", systemImage: "person.text.rectangle") }
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
    }
}

private struct FactsTab: View {
    @ObservedObject private var store = FactStore.shared
    @ObservedObject private var license = LicenseManager.shared
    @FocusState private var focusedFact: UUID?
    @State private var showingPlaceholderHelp = false

    private var isAtFreeLimit: Bool {
        !license.state.isLicensed && store.facts.count >= LicenseManager.freeFactLimit
    }

    private var hasEmptyFact: Bool {
        store.facts.contains {
            $0.name.trimmingCharacters(in: .whitespaces).isEmpty &&
            $0.value.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(store.facts.indices, id: \.self) { index in
                        FactRow(
                            fact: $store.facts[index],
                            focus: $focusedFact,
                            isPlanLocked: isPlanLocked(index)
                        ) {
                            let id = store.facts[index].id
                            DispatchQueue.main.async {
                                withAnimation { store.remove(id) }
                            }
                        }
                    }
                }
                .padding(14)
            }

            Divider()

            HStack {
                Button {
                    let fact = store.add()
                    focusedFact = fact.id
                } label: {
                    Label("Add Fact", systemImage: "plus")
                }
                .disabled(hasEmptyFact || isAtFreeLimit)

                if isAtFreeLimit {
                    Text("Free limit reached")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)

                    if let checkoutURL = PolarLicenseClient().checkoutURL {
                        Button("Unlock") {
                            NSWorkspace.shared.open(checkoutURL)
                        }
                    }
                }

                Spacer()
                Button {
                    showingPlaceholderHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Show placeholders")
                .popover(isPresented: $showingPlaceholderHelp, arrowEdge: .bottom) {
                    PlaceholderHelpView()
                }
            }
            .padding(10)
        }
        .frame(width: 440, height: 360)
    }

    private func isPlanLocked(_ index: Int) -> Bool {
        !license.state.isLicensed && index >= LicenseManager.freeFactLimit
    }
}

private struct PlaceholderHelpView: View {
    private let examples = [
        ("{date}", "2026-07-05"),
        ("{shortdate}", "7/5/26"),
        ("{longdate}", "July 5, 2026"),
        ("{time}", "14:30"),
        ("{datetime}", "2026-07-05 14:30"),
        ("{date:+7:MMM d}", "Jul 12"),
        ("{clipboard}", "current clipboard text"),
        ("{username}", "macOS username"),
        ("{hostname}", "computer name"),
        ("{app}", "current app"),
        ("{uuid}", "new UUID")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Placeholders")
                .font(.system(size: 13, weight: .semibold))
            ForEach(examples, id: \.0) { token, description in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(token)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 128, alignment: .leading)
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Text("[[+]] still controls where name+text lands.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 310, alignment: .leading)
    }
}

private struct FactRow: View {
    @Binding var fact: Fact
    @FocusState.Binding var focus: UUID?
    var isPlanLocked: Bool
    var onDelete: () -> Void
    @State private var hovering = false
    @State private var valueRevealed = false

    private var valueIsLocked: Bool {
        fact.isSensitive && !valueRevealed
    }

    var body: some View {
        HStack(spacing: 10) {
            TextField("Name", text: $fact.name)
                .font(.system(size: 13, weight: .semibold))
                .focused($focus, equals: fact.id)
                .frame(width: 120, alignment: .leading)
                .disabled(isPlanLocked)

            valueField

            if isPlanLocked {
                Image(systemName: "key.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help("Unlock unlimited facts")
            } else {
                Button {
                    toggleSensitivity()
                } label: {
                    Image(systemName: fact.isSensitive ? "lock.fill" : "lock.open")
                        .font(.system(size: 11))
                        .foregroundStyle(fact.isSensitive ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .opacity(fact.isSensitive || hovering ? 1 : 0)
                .help(fact.isSensitive ? "Unlock this fact" : "Ask for Touch ID before inserting this fact")
            }

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
        }
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .opacity(isPlanLocked ? 0.58 : 1)
        .onHover { hovering = $0 }
        .onAppear { valueRevealed = !fact.isSensitive || Auth.isUnlocked }
        .onChange(of: fact.isSensitive) { _, isSensitive in
            valueRevealed = !isSensitive || Auth.isUnlocked
        }
    }

    @ViewBuilder
    private var valueField: some View {
        if valueIsLocked {
            Button {
                revealValue()
            } label: {
                HStack(spacing: 8) {
                    Text(maskedValue)
                        .font(.system(size: 12.5, design: .monospaced))
                        .lineLimit(1)
                    Text("Hidden")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Unlock with Touch ID to view or edit")
            .disabled(isPlanLocked)
        } else {
            TextField("Value", text: $fact.value)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .disabled(isPlanLocked)
        }
    }

    private var maskedValue: String {
        String(repeating: "•", count: min(max(fact.value.count, 6), 18))
    }

    private func revealValue() {
        Auth.requireIfNeeded(reason: "show \(fact.name.isEmpty ? "locked fact" : fact.name)") {
            valueRevealed = true
        }
    }

    private func toggleSensitivity() {
        if fact.isSensitive {
            Auth.requireIfNeeded(reason: "unlock \(fact.name.isEmpty ? "fact" : fact.name)") {
                fact.isSensitive = false
                valueRevealed = true
            }
        } else {
            fact.isSensitive = true
            valueRevealed = false
        }
    }
}

private struct GeneralTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = FactStore.shared
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var iCloudSync: Binding<Bool> {
        Binding(
            get: { store.iCloudSyncEnabled },
            set: { store.setICloudSyncEnabled($0) }
        )
    }

    var body: some View {
        Form {
            Picker("Open palette with", selection: $settings.trigger) {
                ForEach(TriggerModifier.allCases) { trigger in
                    Text("Double-tap \(trigger.label)").tag(trigger)
                }
            }

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            Toggle(isOn: iCloudSync) {
                Text("Sync with iCloud")
                Text(store.iCloudStatus)
            }

            if !accessibilityGranted {
                LabeledContent {
                    Button("Open System Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                } label: {
                    Text("Accessibility access")
                    Text("Needed to find your cursor and type for you.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 360)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AXIsProcessTrusted()
        }
    }
}

private struct AboutTab: View {
    @ObservedObject private var license = LicenseManager.shared
    @State private var key = ""

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private var checkoutURL: URL? {
        PolarLicenseClient().checkoutURL
    }

    private var portalURL: URL? {
        PolarLicenseClient().portalURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            hero
            licenseCard
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 440, height: 360)
    }

    // MARK: Hero

    private var hero: some View {
        HStack(spacing: 16) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(
                    LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .shadow(color: .blue.opacity(0.25), radius: 7, y: 3)

            VStack(alignment: .leading, spacing: 3) {
                Text("Backpocket")
                    .font(.system(size: 21, weight: .semibold))
                Text("Your facts, one double-tap away.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Text("Version \(version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: License card

    private var licenseCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 11) {
                    Image(systemName: license.state.isLicensed ? "checkmark.seal.fill" : "seal")
                        .font(.system(size: 17))
                        .foregroundStyle(license.state.isLicensed ? Color.green : Color.secondary)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(license.state.isLicensed ? "Licensed" : "Free plan")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(planSubtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    if license.isWorking {
                        ProgressView().controlSize(.small)
                    }
                }

                if let snapshot = license.currentSnapshot {
                    Divider()
                    licenseDetails(snapshot)
                } else {
                    activationField
                }
            }
            .padding(16)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
            )

            if license.currentSnapshot != nil {
                licenseActions
            }
        }
    }

    private var planSubtitle: String {
        if license.state.isLicensed {
            return "Unlimited facts, unlocked."
        }
        switch license.state {
        case .validating:
            return "Checking your license…"
        case .inactive(let reason):
            return reason
        default:
            return "Up to \(LicenseManager.freeFactLimit) facts."
        }
    }

    private func licenseDetails(_ snapshot: LicenseSnapshot) -> some View {
        VStack(spacing: 9) {
            detailRow("Key", snapshot.displayKey, monospaced: true)
            if let email = snapshot.customerEmail {
                detailRow("Account", email)
            }
            if let expiresAt = snapshot.expiresAt {
                detailRow("Renews", expiresAt.formatted(date: .abbreviated, time: .omitted))
            }
        }
    }

    private var licenseActions: some View {
        HStack(spacing: 16) {
            if let portalURL {
                Button("Portal") {
                    NSWorkspace.shared.open(portalURL)
                }
                .disabled(license.isWorking)
            }

            Spacer(minLength: 0)

            Button("Refresh") { license.refresh() }
                .disabled(license.isWorking)
            Button("Remove") { license.deactivate() }
                .disabled(license.isWorking)
        }
        .buttonStyle(.link)
        .controlSize(.small)
        .padding(.horizontal, 4)
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var activationField: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SecureField("Enter license key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.oneTimeCode)
                    .disabled(license.isWorking)
                    .onSubmit { activate() }
                Button("Activate") { activate() }
                    .disabled(license.isWorking || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let checkoutURL {
                HStack(spacing: 5) {
                    Text("Don't have a key?")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Button("Get a license") {
                        NSWorkspace.shared.open(checkoutURL)
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            Button("Check for Updates…") {
                AppDelegate.shared?.checkForUpdates()
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
            Spacer(minLength: 0)
        }
    }

    private func activate() {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        license.activate(key: key)
        key = ""
    }
}
