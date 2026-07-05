import AppKit
import SwiftUI

@MainActor
final class PaletteModel: ObservableObject {
    @Published var query = "" {
        didSet { refresh() }
    }
    @Published var results: [FuzzyResult] = []
    @Published var selection = 0
    @Published var growsUp = true

    var onCommit: ((Fact) -> Void)?
    var onCommitRaw: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    func reset() {
        query = ""
        selection = 0
        refresh()
    }

    func refresh() {
        results = Fuzzy.rank(query, in: FactStore.shared.facts)
        selection = 0
    }

    var selected: Fact? {
        results.indices.contains(selection) ? results[selection].fact : nil
    }

    func adjustSelection(by delta: Int) {
        selection = min(max(selection + delta, 0), max(results.count - 1, 0))
    }

    func commit() {
        if let fact = selected {
            onCommit?(fact)
        } else if !query.isEmpty {
            // No match: the query itself is what gets typed.
            onCommitRaw?(query)
        }
    }
}

final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
    static let shared = PaletteController()

    private let panel: PalettePanel
    private let model = PaletteModel()
    private var targetApp: NSRunningApplication?

    /// Fixed stage for the floating pills; empty regions are fully transparent,
    /// so the window itself never needs to resize.
    private let panelSize = NSSize(width: 260, height: 216)

    override init() {
        panel = PalettePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PaletteView(model: model))

        model.onCommit = { [weak self] fact in self?.insert(fact) }
        model.onCommitRaw = { [weak self] text in self?.insertRaw(text) }
        model.onDismiss = { [weak self] in self?.dismiss() }

        // Cmd-Tab away from the target app makes the palette irrelevant.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            DispatchQueue.main.async { self?.handleAppSwitch(note) }
        }
    }

    private func handleAppSwitch(_ note: Notification) {
        guard panel.isVisible,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != targetApp?.processIdentifier,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        dismiss(reactivate: false)
    }

    private var lastToggle: TimeInterval = 0

    func toggle() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastToggle > 0.3 else { return }
        lastToggle = now
        panel.isVisible ? dismiss() : show()
    }

    func show() {
        targetApp = NSWorkspace.shared.frontmostApplication
        let anchor = CaretLocator.anchor()
        position(at: anchor)
        model.reset()
        panel.makeKeyAndOrderFront(nil)
        // SwiftUI's FocusState can fail inside a non-activating panel (seen in
        // Electron-hosted apps); claim first responder at the AppKit level too.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, self.panel.isVisible,
                  let field = Self.firstTextField(in: self.panel.contentView) else { return }
            if self.panel.firstResponder === self.panel {
                self.panel.makeFirstResponder(field)
            }
        }
    }

    /// `reactivate` hands focus back to the app the palette opened over. Skipped
    /// when dismissal came from the user clicking into something else.
    func dismiss(reactivate: Bool = true) {
        panel.orderOut(nil)
        if reactivate { targetApp?.activate() }
    }

    private func insert(_ fact: Fact) {
        dismiss()
        FactStore.shared.markUsed(fact.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Typer.type(fact.value)
        }
    }

    private func insertRaw(_ text: String) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Typer.type(text)
        }
    }

    /// Pills hug the text box: input pill just above the anchor with results
    /// stacking upward, or flipped below it when there's no room.
    private func position(at anchor: PaletteAnchor) {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.point) } ?? NSScreen.main
        let visibleMaxY = screen?.visibleFrame.maxY ?? .infinity
        let growsUp = anchor.point.y + 6 + panelSize.height <= visibleMaxY
        model.growsUp = growsUp

        var origin = CGPoint(
            x: anchor.point.x - 14,
            y: growsUp ? anchor.point.y + 4 : anchor.point.y - anchor.clearance - panelSize.height
        )
        if let visible = screen?.visibleFrame {
            origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - panelSize.width - 8)
            origin.y = min(max(visible.minY + 8, origin.y), visible.maxY - panelSize.height - 8)
        }
        BPLog.log("anchor=\(anchor.point) clearance=\(anchor.clearance) panelOrigin=\(origin) growsUp=\(growsUp)")
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
    }

    private static func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField { return field }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss(reactivate: false)
    }
}
