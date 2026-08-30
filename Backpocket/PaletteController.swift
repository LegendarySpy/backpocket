import AppKit
import SwiftUI

@MainActor
final class PaletteModel: ObservableObject {
    @Published var query = ""
    @Published var selection = 0
    @Published var growsUp = true

    private var ranking: (query: String, facts: [Fact], hint: String?, results: [FuzzyResult])?

    /// Derived, not stored: publishing results from the query's didSet would
    /// publish mid-view-update whenever the text field writes the binding. A
    /// single body pass reads this several times, so the rank itself is memoized.
    var results: [FuzzyResult] {
        var facts = FactStore.shared.availableFacts(unlimited: LicenseManager.shared.state.isLicensed)
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            facts += PlaceholderResolver.builtInFacts
        }
        if let ranking, ranking.query == query, ranking.hint == fieldHint, ranking.facts == facts {
            return ranking.results
        }
        let ranked = Fuzzy.rank(query, in: facts, context: appIdentifier, fieldHint: fieldHint)
        ranking = (query, facts, fieldHint, ranked)
        return ranked
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

    /// Bumped per show so the input field re-takes focus every time, not just
    /// the first time its view appears.
    @Published var focusToken = 0

    func prepareForShow(appIdentifier: String?, appName: String?, fieldHint: String?) {
        self.appIdentifier = appIdentifier
        self.appName = appName
        self.fieldHint = fieldHint
        introducing = true
        focusToken += 1
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
            resolution = nil
            if panel.isVisible { dismiss(reactivate: false) }
        }
    }

    private var lastToggle: TimeInterval = 0

    func toggle() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastToggle > 0.2 else { return }
        lastToggle = now
        panel.isVisible ? dismiss() : show()
    }

    /// Bumped whenever a pending show becomes irrelevant, so its resolution is dropped.
    private var showGeneration = 0

    /// The in-flight (or just-finished) read of the target app. One resolution
    /// serves both taps of a double-tap: the first starts it, the second awaits it.
    private var resolution: (pid: pid_t?, task: Task<PaletteTarget, Never>, startedAt: TimeInterval)?
    private static let resolutionLifetime: TimeInterval = 0.6

    /// The first tap starts the accessibility read and stages the palette off
    /// screen, so the second tap only has to order it front.
    func prefetchAnchor() {
        guard !panel.isVisible else { return }
        let app = NSWorkspace.shared.frontmostApplication
        let generation = showGeneration
        let task = resolve(for: app)
        Task { @MainActor in
            let target = await task.value
            guard !panel.isVisible, generation == showGeneration else { return }
            stage(target, app: app)
        }
    }

    func show() {
        showGeneration += 1
        let generation = showGeneration
        let app = NSWorkspace.shared.frontmostApplication
        targetApp = app
        let task = resolve(for: app)
        Task { @MainActor in
            let target = await task.value
            guard generation == showGeneration else { return }
            stage(target, app: app)
            orderFront()
            if !target.anchor.fromCaret { await settleOntoCaret(pid: app?.processIdentifier) }
        }
    }

    /// The palette opened on a fallback. Keep glancing for the real caret and
    /// settle onto it within the first frames, before the user has read it.
    private func settleOntoCaret(pid: pid_t?) async {
        let generation = showGeneration
        for _ in 0 ..< 4 {
            try? await Task.sleep(for: .milliseconds(70))
            guard generation == showGeneration, panel.isVisible, model.query.isEmpty else { return }
            if let anchor = CaretLocator.caretOnly(for: pid) {
                BPLog.log("settling onto caret after fallback open")
                position(at: anchor)
                return
            }
        }
    }

    private func resolve(for app: NSRunningApplication?) -> Task<PaletteTarget, Never> {
        let pid = app?.processIdentifier
        let now = ProcessInfo.processInfo.systemUptime
        if let resolution, resolution.pid == pid, now - resolution.startedAt < Self.resolutionLifetime {
            return resolution.task
        }
        let task = Task { @MainActor in await CaretLocator.resolveTarget(for: pid) }
        resolution = (pid, task, now)
        return task
    }

    /// Everything the palette needs on screen except being on screen. Runs off
    /// the resolved target only, so re-staging never touches accessibility again.
    private func stage(_ target: PaletteTarget, app: NSRunningApplication?) {
        model.prepareForShow(
            appIdentifier: Self.appIdentifier(for: app),
            appName: app?.localizedName,
            fieldHint: target.fieldHint
        )
        position(at: target.anchor)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func orderFront() {
        panel.makeKeyAndOrderFront(nil)
        focusInput()
        // Pills enter once the panel is visible so their blur-replace rides the window fade.
        DispatchQueue.main.async { [weak self] in
            withAnimation(.smooth(duration: 0.08)) { self?.model.introducing = false }
        }
    }

    /// `reactivate` hands focus back to the app the palette opened over. Skipped
    /// when dismissal came from the user clicking into something else.
    func dismiss(reactivate: Bool = true) {
        showGeneration += 1
        resolution = nil
        panel.orderOut(nil)
        model.prepareForDismiss()
        if reactivate { targetApp?.activate() }
    }

    private func insert(_ fact: Fact, typing value: String) {
        let appIdentifier = model.appIdentifier
        let pid = targetApp?.processIdentifier
        dismiss()
        let type = { [weak self] in
            FactStore.shared.markUsed(fact.id, appIdentifier: appIdentifier)
            self?.deliverSoon(value, sensitive: fact.isSensitive, pid: pid)
        }
        if fact.isSensitive {
            Auth.requireIfNeeded(reason: "insert \(fact.name)", onSuccess: type)
        } else {
            type()
        }
    }

    private func insertRaw(_ text: String) {
        let pid = targetApp?.processIdentifier
        dismiss()
        let value = PlaceholderResolver.resolve(text, context: model.placeholderContext)
        deliverSoon(value, sensitive: false, pid: pid)
    }

    /// Pasting is one keystroke instead of one per character, so nothing can be
    /// dropped or reordered mid-value.
    ///
    /// A sensitive value never transits the pasteboard, however briefly. It goes
    /// in through accessibility where that provably works — instant, and it never
    /// leaves the field — and is typed out character by character everywhere else.
    private func deliverSoon(_ value: String, sensitive: Bool, pid: pid_t?) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            if sensitive {
                if await CaretLocator.insertText(value, pid: pid) { return }
                Typer.type(value)
            } else if Pasteboard.stage(value) {
                Typer.pressCommandV()
            } else {
                Typer.type(value)
            }
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
