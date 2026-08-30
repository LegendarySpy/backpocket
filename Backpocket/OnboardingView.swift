import SwiftUI

/// First-launch walkthrough shown in place of the settings tabs.
struct OnboardingView: View {
    var onFinish: () -> Void

    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var pageIndex = 0

    /// The permission step is only worth a page when it isn't already granted.
    private var pages: [Page] {
        permissions.isTrusted ? [.trigger, .locking, .placeholders] : Page.allCases
    }

    private var page: Page {
        pages[min(pageIndex, pages.count - 1)]
    }

    private var isLast: Bool {
        page == pages.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

            Text(page.title)
                .font(.system(size: 17, weight: .semibold))

            Text(page.body(trigger: settings.trigger))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            detail
                .padding(.top, 18)

            Spacer(minLength: 20)

            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(width: 440, height: 360)
        .animation(.snappy(duration: 0.28), value: pageIndex)
        .animation(.snappy(duration: 0.28), value: permissions.isTrusted)
    }

    @ViewBuilder
    private var detail: some View {
        switch page {
        case .accessibility: AccessibilityStep()
        case .trigger: TriggerStep(trigger: settings.trigger)
        case .locking: LockedFactStep()
        case .placeholders: PlaceholderExamples()
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            ForEach(pages, id: \.self) { dot in
                Circle()
                    .fill(dot == page ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                    .frame(width: 6, height: 6)
            }

            Spacer(minLength: 0)

            if pageIndex > 0 {
                Button("Back") { pageIndex -= 1 }
            }

            Button(isLast ? "Done" : "Continue") {
                if isLast {
                    onFinish()
                } else {
                    pageIndex += 1
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(page == .accessibility && !permissions.isTrusted)
        }
    }
}

private enum Page: CaseIterable {
    case accessibility, trigger, locking, placeholders

    var title: String {
        switch self {
        case .accessibility: "One permission to grant"
        case .trigger: "Your facts, one double-tap away"
        case .locking: "Lock what's sensitive"
        case .placeholders: "Values that fill themselves in"
        }
    }

    func body(trigger: TriggerModifier) -> String {
        switch self {
        case .accessibility:
            "Backpocket needs Accessibility access to see where your cursor is and type for you. It starts working the moment you allow it — no restart."
        case .trigger:
            "Double-tap \(trigger.label) in any text field, type a few letters, and press Return. The value lands where your cursor was."
        case .locking:
            "Click the lock on a fact and its value is encrypted before it's saved or synced, masked in the palette, and typed rather than pasted. Touch ID unlocks it."
        case .placeholders:
            "Put a token in any value and it resolves as it's typed."
        }
    }
}

private struct AccessibilityStep: View {
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: permissions.isTrusted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 16))
                .foregroundStyle(permissions.isTrusted ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))

            Text(permissions.isTrusted ? "Accessibility access granted" : "Waiting for access…")
                .font(.system(size: 12.5, weight: .medium))

            Spacer(minLength: 8)

            if !permissions.isTrusted {
                Button("Open System Settings…") { permissions.openSystemSettings() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The chosen modifier, tapped twice.
private struct TriggerStep: View {
    let trigger: TriggerModifier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            keycap
            keycap
            Text("in any text field")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
    }

    private var keycap: some View {
        Text(trigger.symbol)
            .font(.system(size: 17, weight: .medium))
            .frame(width: 40, height: 36)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            )
    }
}

/// A locked fact, exactly as it appears in the Facts list.
private struct LockedFactStep: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("Bank PIN")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 120, alignment: .leading)

            Text("••••••")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)

            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .frame(width: 330)
    }
}

/// Live examples: the right column is what these tokens resolve to right now,
/// so nothing here can go stale.
struct PlaceholderExamples: View {
    private let tokens = ["{date}", "{time}", "{clipboard}", "{date:+7:MMM d}"]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(tokens, id: \.self) { token in
                PlaceholderRow(token: token, result: resolved(token))
            }
        }
    }

    private func resolved(_ token: String) -> String {
        let value = PlaceholderResolver.resolve(token)
        if token == "{clipboard}" {
            return value.isEmpty ? "what you last copied" : condense(value)
        }
        return value
    }

    private func condense(_ text: String) -> String {
        let line = text.components(separatedBy: .newlines).joined(separator: " ")
        return line.count > 28 ? line.prefix(27) + "…" : line
    }
}

struct PlaceholderRow: View {
    let token: String
    let result: String

    var body: some View {
        HStack(spacing: 10) {
            Text(token)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .frame(width: 132, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.quaternary)

            Text(result)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
