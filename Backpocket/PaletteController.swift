import AppKit
import SwiftUI

@MainActor
final class PaletteModel: ObservableObject {
    @Published var query = ""
    @Published var selection = 0
    @Published var growsUp = true

    /// Derived, not stored: publishing results from the query's didSet would
    /// publish mid-view-update whenever the text field writes the binding.
    var results: [FuzzyResult] {
        var facts = FactStore.shared.facts
        if !LicenseManager.shared.state.isLicensed {
            facts = Array(facts.prefix(LicenseManager.freeFactLimit))
        }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            facts += PlaceholderResolver.builtInFacts
        }
        return Fuzzy.rank(query, in: facts, context: appIdentifier, fieldHint: fieldHint)
    }

    var appIdentifier: String?
    var appName: String?
    var fieldHint: String?
    var onCommit: ((Fact, String) -> Void)?
    var onCommitRaw: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    func reset() {
        query = ""
        selection = 0
    }

    /// True until the panel is on screen; the pills blur-replace in alongside
    /// the window fade once it flips.
    @Published var introducing = true

    func prepareForShow(appIdentifier: String?, appName: String?, fieldHint: String?) {
        self.appIdentifier = appIdentifier
        self.appName = appName
        self.fieldHint = fieldHint
        introducing = true
        reset()
    }

    func prepareForDismiss() {
        reset()
    }

    func resolvedValue(for fact: Fact) -> String {
        PlaceholderResolver.resolve(fact.value, context: placeholderContext)
    }

    var placeholderContext: PlaceholderResolver.Context {
        PlaceholderResolver.Context(appName: appName)
    }

    /// What Return would type, shown dimmed in the pill. Sensitive values stay
    /// masked until they're inserted.
    func preview(for fact: Fact) -> String? {
        if fact.isSensitive { return "••••••" }
        let resolved = resolvedValue(for: fact)
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        return resolved.isEmpty ? nil : resolved
    }

    var selectedResult: FuzzyResult? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    var selected: Fact? {
        selectedResult?.fact
    }

    func adjustSelection(by delta: Int) {
        selection = min(max(selection + delta, 0), max(results.count - 1, 0))
    }

    func commit(_ fact: Fact) {
        onCommit?(fact, resolvedValue(for: fact))
    }

    func commit() {
        if let result = selectedResult {
            commit(result.fact)
        } else if !query.isEmpty {
            // No match: the query itself is what gets typed.
            onCommitRaw?(query)
        }
    }
}

final class PalettePanel: NSPanel {
    var onCancel: (() -> Void)?
    var onOrphanKeyDown: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// A keystroke that falls through the whole responder chain means the input
    /// field wasn't focused. Recover it instead of letting AppKit beep.
    override func keyDown(with event: NSEvent) {
        onOrphanKeyDown?(event)
    }
}

final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        return hitView === self ? nil : hitView
    }
}

@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
    static let shared = PaletteController()

    private let panel: PalettePanel
    private let model = PaletteModel()
    private var targetApp: NSRunningApplication?

    /// Fixed stage for the floating pills; empty regions are fully transparent,
    /// so the window itself never needs to resize.
    private let panelSize = NSSize(width: 308, height: 264)
    private let contentPadding: CGFloat = 34
    private let screenMargin: CGFloat = 8

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
        panel.contentView = PassThroughHostingView(rootView: PaletteView(model: model))
        panel.onCancel = { [weak self] in self?.dismiss() }
        panel.onOrphanKeyDown = { [weak self] event in self?.rescueOrphanKey(event) }

        model.onCommit = { [weak self] fact, value in self?.insert(fact, typing: value) }
        model.onCommitRaw = { [weak self] text in self?.insertRaw(text) }
        model.onDismiss = { [weak self] in self?.dismiss() }

        // Cmd-Tab away from the target app makes the palette irrelevant.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            DispatchQueue.main.async { self?.handleAppSwitch(note) }
        }

        // The app the user is already in never gets an activation event.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            CaretLocator.warmUp(pid: front.processIdentifier)
        }
    }

    private func handleAppSwitch(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        CaretLocator.warmUp(pid: app.processIdentifier)
        if app.processIdentifier != targetApp?.processIdentifier {
            showGeneration += 1 // a show still waiting on the old app's caret is moot
            if panel.isVisible { dismiss(reactivate: false) }
        }
    }

    private var lastToggle: TimeInterval = 0

    func toggle() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastToggle > 0.3 else { return }
        lastToggle = now
        panel.isVisible ? dismiss() : show()
    }

    /// Bumped when a pending show becomes irrelevant so its anchor resolution is dropped.
    private var showGeneration = 0

    private var staged: (anchor: PaletteAnchor, pid: pid_t?, at: TimeInterval)?
    private var prefetchingPid: pid_t??
    /// Set when show() arrives while the first tap's resolve is still running;
    /// its completion presents instead of a fresh resolve starting over.
    private var pendingShowGeneration: Int?

    /// The first tap of a double-tap does all the work — anchor, field hint,
    /// model prep, panel position and layout — so the second tap only orders front.
    func prefetchAnchor() {
        guard !panel.isVisible else { return }
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier
        prefetchingPid = .some(pid)
        CaretLocator.resolveAnchor(for: pid) { [weak self] anchor in
            guard let self else { return }
            prefetchingPid = nil
            stage(at: anchor, app: app)
            if let pending = pendingShowGeneration, pending == showGeneration {
                pendingShowGeneration = nil
                staged = nil
                orderFront(anchor: anchor)
            } else {
                staged = (anchor, pid, ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    func show() {
        showGeneration += 1
        let generation = showGeneration
        targetApp = NSWorkspace.shared.frontmostApplication
        let pid = targetApp?.processIdentifier
        pendingShowGeneration = nil
        if let staged, staged.pid == pid,
           ProcessInfo.processInfo.systemUptime - staged.at < 0.6 {
            self.staged = nil
            orderFront(anchor: staged.anchor)
            return
        }
        staged = nil
        if prefetchingPid == .some(pid) {
            pendingShowGeneration = generation
            return
        }
        CaretLocator.resolveAnchor(for: pid) { [weak self] anchor in
            guard let self, generation == showGeneration else { return }
            present(at: anchor, pid: pid)
        }
    }

    /// Cold path: no usable first-tap work, so stage and order front together.
    private func present(at anchor: PaletteAnchor, pid: pid_t?) {
        stage(at: anchor, app: targetApp)
        orderFront(anchor: anchor)
    }

    /// Everything the palette needs on screen except being on screen. The field
    /// hint runs here so a freshly nudged Chromium tree has had time to answer.
    private func stage(at anchor: PaletteAnchor, app: NSRunningApplication?) {
        model.prepareForShow(
            appIdentifier: Self.appIdentifier(for: app),
            appName: app?.localizedName,
            fieldHint: CaretLocator.fieldHint(for: app?.processIdentifier)
        )
        position(at: anchor)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func orderFront(anchor: PaletteAnchor) {
        panel.makeKeyAndOrderFront(nil)
        // Pills enter once the panel is visible so their blur-replace rides the window fade.
        DispatchQueue.main.async { [weak self] in
            withAnimation(.smooth(duration: 0.08)) { self?.model.introducing = false }
        }
        focusInputSoon()
        if !anchor.fromCaret { refinePositionSoon() }
    }

    /// When the first pass fell back, keep glancing for the real caret and
    /// slide onto it before the user starts typing.
    private func refinePositionSoon(delays: [TimeInterval] = [0.2, 0.6]) {
        guard let delay = delays.first else { return }
        let pid = targetApp?.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, panel.isVisible, model.query.isEmpty else { return }
            let anchor = CaretLocator.anchor(for: pid)
            if anchor.fromCaret {
                position(at: anchor)
            } else {
                refinePositionSoon(delays: Array(delays.dropFirst()))
            }
        }
    }

    /// `reactivate` hands focus back to the app the palette opened over. Skipped
    /// when dismissal came from the user clicking into something else.
    func dismiss(reactivate: Bool = true) {
        showGeneration += 1
        panel.orderOut(nil)
        model.prepareForDismiss()
        if reactivate { targetApp?.activate() }
    }

    private func insert(_ fact: Fact, typing value: String) {
        let appIdentifier = model.appIdentifier
        dismiss()
        let type = { [weak self] in
            FactStore.shared.markUsed(fact.id, appIdentifier: appIdentifier)
            self?.deliverSoon(value)
        }
        if fact.isSensitive {
            Auth.requireIfNeeded(reason: "insert \(fact.name)", onSuccess: type)
        } else {
            type()
        }
    }

    private func insertRaw(_ text: String) {
        dismiss()
        let value = PlaceholderResolver.resolve(text, context: model.placeholderContext)
        deliverSoon(value)
    }

    private func deliverSoon(_ value: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Typer.type(value)
        }
    }

    /// Pills hug the text box: input pill just above the anchor with results
    /// stacking upward, or flipped below it when there's no room.
    private func position(at anchor: PaletteAnchor) {
        let screen = screen(for: anchor.rect) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame
        // Taller anchors (whole text boxes) get more breathing room than a bare caret.
        let gap = min(max(6, anchor.rect.height * 0.25), 14)
        let growsUp = shouldGrowUp(from: anchor.rect, gap: gap, in: visibleFrame)
        model.growsUp = growsUp

        let inputTopOffset = panelSize.height - contentPadding
        var origin = CGPoint(
            x: anchor.alignmentX - contentPadding,
            y: growsUp
                ? anchor.rect.maxY + gap - contentPadding
                : anchor.rect.minY - gap - inputTopOffset
        )
        if let visible = visibleFrame {
            origin.x = min(max(visible.minX + screenMargin, origin.x), visible.maxX - panelSize.width - screenMargin)
            origin.y = min(max(visible.minY + screenMargin, origin.y), visible.maxY - panelSize.height - screenMargin)
        }
        BPLog.log("anchorRect=\(anchor.rect) alignX=\(anchor.alignmentX) panelOrigin=\(origin) growsUp=\(growsUp)")
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
    }

    private func shouldGrowUp(from rect: NSRect, gap: CGFloat, in visibleFrame: NSRect?) -> Bool {
        guard let visibleFrame else { return true }
        let roomAbove = visibleFrame.maxY - rect.maxY
        let roomBelow = rect.minY - visibleFrame.minY

        if roomAbove >= panelSize.height + gap { return true }
        if roomBelow >= panelSize.height + gap { return false }
        return roomAbove >= roomBelow
    }

    private func screen(for rect: NSRect) -> NSScreen? {
        let intersectingScreens = NSScreen.screens
            .map { screen in (screen: screen, area: screen.frame.intersection(rect).area) }
            .filter { $0.1 > 0 }
        if let best = intersectingScreens.max(by: { $0.1 < $1.1 })?.screen {
            return best
        }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    private static func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField { return field }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }

    private func focusInputSoon() {
        focusInput()
        for delay in [0.03, 0.1] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.focusInput()
            }
        }
    }

    private func focusInput() {
        guard panel.isVisible,
              let field = Self.firstTextField(in: panel.contentView),
              !Self.responder(panel.firstResponder, isEditing: field)
        else { return }
        panel.makeFirstResponder(field)
    }

    /// The panel is key but the input field wasn't focused when a key arrived.
    /// Refocus and replay the keystroke so it lands instead of beeping.
    private func rescueOrphanKey(_ event: NSEvent) {
        BPLog.log("orphan keyDown; refocusing input")
        focusInput()
        guard let field = Self.firstTextField(in: panel.contentView),
              let editor = field.currentEditor() else { return }
        editor.keyDown(with: event)
    }

    private static func responder(_ responder: NSResponder?, isEditing field: NSTextField) -> Bool {
        guard let responder else { return false }
        if responder === field { return true }
        if responder === field.currentEditor() { return true }
        guard let view = responder as? NSView else { return false }
        return view == field || view.isDescendant(of: field)
    }

    private static func appIdentifier(for app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        if let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }
        if let localizedName = app.localizedName, !localizedName.isEmpty {
            return "name:\(localizedName)"
        }
        return nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        focusInput()
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss(reactivate: false)
    }
}

private extension NSRect {
    var area: CGFloat {
        isNull ? 0 : width * height
    }
}
