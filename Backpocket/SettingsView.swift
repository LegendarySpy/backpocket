import ServiceManagement
import SwiftUI

enum TriggerModifier: String, CaseIterable, Identifiable {
    case option, control, command, shift

    static let defaultsKey = "trigger"

    var id: String { rawValue }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .option: .option
        case .control: .control
        case .command: .command
        case .shift: .shift
        }
    }

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

enum PalettePreviewMode: String, CaseIterable, Identifiable {
    case always, selected, never

    static let defaultsKey = "palettePreview"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .always: "All results"
        case .selected: "Selected result"
        case .never: "Never"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var trigger: TriggerModifier {
        didSet { UserDefaults.standard.set(trigger.rawValue, forKey: TriggerModifier.defaultsKey) }
    }

    @Published var palettePreview: PalettePreviewMode {
        didSet { UserDefaults.standard.set(palettePreview.rawValue, forKey: PalettePreviewMode.defaultsKey) }
    }

    init() {
        trigger = TriggerModifier(rawValue: UserDefaults.standard.string(forKey: TriggerModifier.defaultsKey) ?? "") ?? .option
        palettePreview = PalettePreviewMode(rawValue: UserDefaults.standard.string(forKey: PalettePreviewMode.defaultsKey) ?? "") ?? .selected
    }
}

struct SettingsRootView: View {
    private enum Tab { case facts, general, about }
    @State private var selection = Tab.facts
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if hasCompletedOnboarding {
            tabs
        } else {
            OnboardingView {
                withAnimation { hasCompletedOnboarding = true }
            }
            // Only while onboarding: the tabs want their native title back.
            .background(CleanTitlebar())
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            FactsTab()
                .tabItem { Label("Facts", systemImage: "person.text.rectangle") }
                .tag(Tab.facts)
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .onReceive(NotificationCenter.default.publisher(for: .factCaptured)) { _ in
            selection = .facts
        }
        .onReceive(NotificationCenter.default.publisher(for: .licenseRequired)) { _ in
            selection = .about
        }
        .onAppear {
            if CaptureService.pendingFocusID != nil { selection = .facts }
        }
    }
}

/// Traffic lights only: no rule across the top and no "Backpocket Settings"
/// caption competing with the step's own heading.
private struct CleanTitlebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: view.window)
    }

    /// Onboarding hands the same window over to the tabs, which do want their
    /// title, so the change has to be undone rather than left behind.
    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        guard let window = view.window else { return }
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
    }
}

private struct FactsTab: View {
    @ObservedObject private var store = FactStore.shared
    @ObservedObject private var license = LicenseManager.shared
    @FocusState private var focusedFact: UUID?
    @State private var showingPlaceholderHelp = false
    @State private var backupFailure: String?

    private var hasEmptyFact: Bool {
        store.facts.contains {
            $0.name.trimmingCharacters(in: .whitespaces).isEmpty &&
            $0.value.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var isAtFreeLimit: Bool {
        !license.state.isLicensed && store.storedFactCount >= LicenseManager.freeFactLimit
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach($store.facts) { $fact in
                            FactRow(
                                fact: $fact,
                                focus: $focusedFact,
                                isPlanLocked: !store.isAvailable(fact, unlimited: license.state.isLicensed)
                            ) {
                                withAnimation { store.remove(fact.id) }
                            }
                            .id(fact.id)
                        }

                        if store.facts.isEmpty {
                            EmptyFacts()
                        }
                    }
                    .padding(14)
                }
                .onAppear { focusCapturedFact(proxy) }
                .onReceive(NotificationCenter.default.publisher(for: .factCaptured)) { _ in
                    focusCapturedFact(proxy)
                }
            }

            if let failure = store.saveFailure ?? backupFailure {
                FailureBanner(message: failure) {
                    backupFailure = nil
                }
            }

            Divider()

            HStack {
                Button {
                    if let fact = store.add(unlimited: license.state.isLicensed) {
                        focusedFact = fact.id
                    }
                } label: {
                    Label("Add Fact", systemImage: "plus")
                }
                .disabled(hasEmptyFact || isAtFreeLimit)

                if isAtFreeLimit {
                    Text("5 fact limit")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)

                    Button("Unlock") {
                        NotificationCenter.default.post(name: .licenseRequired, object: nil)
                    }
                }

                Menu {
                    Button("Export Facts…") {
                        Backup.export(store.facts) { backupFailure = $0 }
                    }
                    Button("Import Facts…") {
                        Backup.restore(into: store) { backupFailure = $0 }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Export or import your facts")

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

    /// The Settings window may still be animating in, so the focus and scroll
    /// land after a short beat.
    private func focusCapturedFact(_ proxy: ScrollViewProxy) {
        guard let id = CaptureService.takePendingFocus() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation { proxy.scrollTo(id) }
            focusedFact = id
        }
    }
}

/// Saving failing quietly is the one failure that costs work, so it gets a
/// permanent strip rather than a notification that can be missed.
private struct FailureBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }
}

private struct EmptyFacts: View {
    var body: some View {
        VStack(spacing: 5) {
            Text("No facts yet")
                .font(.system(size: 13, weight: .medium))
            Text("Add the things you retype: email, address, phone, IBAN.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 46)
    }
}

/// Live values, so nothing here is a hardcoded date that quietly goes stale.
private struct PlaceholderHelpView: View {
    private let tokens = [
        "{date}", "{shortdate}", "{longdate}", "{time}", "{datetime}",
        "{date:+7:MMM d}", "{clipboard}", "{username}", "{fullname}",
        "{hostname}", "{app}", "{uuid}"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Placeholders")
                .font(.system(size: 13, weight: .semibold))
            Text("Use these anywhere in a value. They resolve as it's typed.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(tokens, id: \.self) { token in
                    PlaceholderRow(token: token, result: resolved(token))
                }
            }
        }
        .padding(16)
        .frame(width: 330, alignment: .leading)
    }

    private func resolved(_ token: String) -> String {
        let value = PlaceholderResolver.resolve(
            token,
            context: PlaceholderResolver.Context(appName: NSRunningApplication.current.localizedName)
        )
        if value.isEmpty { return "—" }
        let line = value.components(separatedBy: .newlines).joined(separator: " ")
        return line.count > 30 ? line.prefix(29) + "…" : line
    }
}

private struct FactRow: View {
    @Binding var fact: Fact
    @FocusState.Binding var focus: UUID?
    let isPlanLocked: Bool
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
                .disabled(fact.isUnopened)
                .help(fact.isSensitive ? "Unlock this fact" : "Encrypt this fact and ask for Touch ID before inserting it")
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
        if fact.isUnopened {
            // Synced from another Mac, encrypted, and the key hasn't arrived yet.
            HStack(spacing: 6) {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 10))
                Text("Waiting for iCloud Keychain")
                    .font(.system(size: 11.5))

                Spacer(minLength: 8)

                Button("Replace") { fact.value = "" }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .help("Discard the encrypted value and type a new one")
            }
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Encrypted on another Mac. It opens by itself once iCloud Keychain catches up.")
            .disabled(isPlanLocked)
        } else if valueIsLocked {
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
            // Grows for the things worth storing whole: addresses, signatures,
            // anything that is genuinely more than one line.
            TextField("Value", text: $fact.value, axis: .vertical)
                .lineLimit(1 ... 6)
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
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var updater = Updater.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var checksAutomatically = Updater.shared.automaticallyChecks

    private var iCloudSync: Binding<Bool> {
        Binding(
            get: { store.iCloudSyncEnabled },
            set: { store.setICloudSyncEnabled($0) }
        )
    }

    var body: some View {
        Form {
            if !permissions.isTrusted {
                accessibilitySection
            }

            Section {
                Picker("Open palette with", selection: $settings.trigger) {
                    ForEach(TriggerModifier.allCases) { trigger in
                        Text("Double-tap \(trigger.label)").tag(trigger)
                    }
                }

                Picker(selection: $settings.palettePreview) {
                    ForEach(PalettePreviewMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    Text("Preview values")
                    Text("Show what Return will type, next to each result.")
                }
            }

            Section {
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

                Toggle(isOn: $checksAutomatically) {
                    Text("Check for updates automatically")
                    Text(updater.summary)
                }
                .onChange(of: checksAutomatically) { _, enabled in
                    updater.automaticallyChecks = enabled
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 360)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    @ViewBuilder
    private var accessibilitySection: some View {
        Section {
            LabeledContent {
                Button("Open System Settings…") { permissions.openSystemSettings() }
            } label: {
                Text("Accessibility access")
                Text("Needed to find your cursor and type for you. The palette turns on the moment you grant it — no restart.")
            }

        }
    }
}

private struct AboutTab: View {
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var license = LicenseManager.shared
    @State private var licenseKey = ""
    @State private var isVisible = false
    @State private var legalDocument: LegalDocument?

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            updateStatus
                .padding(.top, 12)

            Spacer(minLength: 10)

            licenseCard
            legalLinks
                .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 440, height: 360)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .sheet(item: $legalDocument) { document in
            LegalDocumentView(document: document)
        }
    }

    private var hero: some View {
        VStack(spacing: 5) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("Backpocket")
                .font(.system(size: 21, weight: .semibold))
            Text("Version \(version)")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var licenseCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: license.state.isLicensed ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(license.state.isLicensed ? licenseGold : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(.quaternary, in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(license.state.isLicensed ? "Backpocket Unlimited" : "Free plan")
                        .font(.system(size: 13, weight: .semibold))
                    Text(licenseSubtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if license.isWorking {
                    ProgressView().controlSize(.small)
                } else if !license.state.isLicensed, let checkoutURL = license.checkoutURL {
                    Button("Get Unlimited") { NSWorkspace.shared.open(checkoutURL) }
                }
            }

            if let snapshot = license.currentSnapshot, license.state.isLicensed {
                HStack {
                    Text(snapshot.displayKey)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Spacer(minLength: 8)

                    if let portalURL = license.portalURL {
                        Button("Purchases") { NSWorkspace.shared.open(portalURL) }
                    }
                    Button("Remove") { license.deactivate() }
                }
                .buttonStyle(.link)
                .controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    SecureField("License key", text: $licenseKey)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.oneTimeCode)
                        .onSubmit { activateLicense() }

                    Button("Activate") { activateLicense() }
                        .disabled(
                            license.isWorking
                                || licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
        }
        .padding(10)
        .background {
            LicenseCardBackground(
                isActive: isVisible,
                isLicensed: license.state.isLicensed
            )
        }
    }

    private var licenseSubtitle: String {
        if license.state.isLicensed { return "Unlimited facts! Thanks for supporting Backpocket." }
        if case .inactive(let reason) = license.state { return reason }
        if case .validating = license.state { return "Checking license…" }
        return "You can save 5 facts for free."
    }

    private var licenseGold: Color {
        Color(red: 0.92, green: 0.58, blue: 0.08)
    }

    private var legalLinks: some View {
        HStack(spacing: 7) {
            Button("Privacy") { legalDocument = .privacy }
            Text("·")
            Button("Terms") { legalDocument = .terms }
            Text("·")
            Button("Report a Bug") {
                if let supportURL { NSWorkspace.shared.open(supportURL) }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
    }

    private var supportURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BackpocketSupportURL") as? String,
              !value.isEmpty,
              !value.hasPrefix("$("),
              let baseURL = URL(string: value),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { return nil }

        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "version", value: version)
        ]
        return components.url
    }

    private var updateStatus: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                if case .checking = updater.status {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(tint)
                }
                Text(updater.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Button(updater.hasUpdate ? "Install Update…" : "Check for Updates…") {
                updater.checkForUpdates()
            }
            .controlSize(.small)
            .disabled(!updater.canCheck)
        }
    }

    private var icon: String {
        if updater.hasUpdate { return "arrow.down.circle.fill" }
        return updater.isUpToDate ? "checkmark.circle.fill" : "info.circle"
    }

    private var tint: Color {
        if updater.hasUpdate { return .accentColor }
        return updater.isUpToDate ? .green : .secondary
    }

    private func activateLicense() {
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        license.activate(key: key)
        licenseKey = ""
    }
}

private struct LicenseCardBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isActive: Bool
    let isLicensed: Bool

    private var sheenColor: Color {
        if isLicensed {
            return Color(red: 1.0, green: 0.65, blue: 0.08).opacity(0.22)
        }
        return Color.accentColor.opacity(0.14)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion || !isActive)) { timeline in
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.quinary)

                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(sheenColor)
                        .colorEffect(
                            ShaderLibrary.licenseSheen(
                                .float(Float(timeline.date.timeIntervalSinceReferenceDate
                                    .truncatingRemainder(dividingBy: 8))),
                                .float2(geometry.size)
                            )
                        )
                }
            }
        }
    }
}
