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
    @FocusState private var focusedFact: UUID?

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
                    ForEach($store.facts) { $fact in
                        FactRow(fact: $fact, focus: $focusedFact) {
                            let id = fact.id
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
                .disabled(hasEmptyFact)
                Spacer()
            }
            .padding(10)
        }
        .frame(width: 440, height: 360)
    }
}

private struct FactRow: View {
    @Binding var fact: Fact
    @FocusState.Binding var focus: UUID?
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

            valueField

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
        } else {
            TextField("Value", text: $fact.value)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(.secondary)
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
    @State private var showingUpToDate = false

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    LinearGradient(colors: [.indigo, .blue], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .padding(.bottom, 4)

            Text("Backpocket")
                .font(.system(size: 16, weight: .semibold))
            Text("Version \(version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button("Check for Updates…") {
                showingUpToDate = true
            }
            .padding(.top, 8)

            Text("Your facts, one double-tap away.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
        }
        .frame(width: 440, height: 360)
        .alert("You're up to date", isPresented: $showingUpToDate) {
            Button("OK") {}
        } message: {
            Text("Backpocket \(version) is the newest version.")
        }
    }
}
