import AppKit
import ApplicationServices

struct PaletteAnchor {
    let rect: NSRect        // caret, text box, or fallback point in AppKit coordinates
    let alignmentX: CGFloat // x position the input pill should hug
    let fromCaret: Bool     // anchored to real caret geometry, not a fallback
}

/// Everything the palette reads out of the target app, gathered in one pass so
/// showing it never has to touch accessibility again.
struct PaletteTarget {
    let anchor: PaletteAnchor
    let fieldHint: String?
}

enum CaretLocator {
    /// Nothing may block the main thread waiting on another process: a busy app
    /// would otherwise stall the trigger for the system default (6s).
    static let messagingTimeout: Float = 0.25

    static func installMessagingTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }

    /// Anchor plus field hint for `pid`, resolved against its focused element so
    /// both stay valid once the palette itself holds system focus.
    @MainActor
    static func resolveTarget(for pid: pid_t?) -> PaletteTarget {
        BPLog.log("resolve app=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        let anchor = resolveAnchor(for: pid)
        return PaletteTarget(anchor: anchor, fieldHint: fieldHint(for: pid))
    }

    /// A caret, or nothing. Used to settle onto the real caret when the palette
    /// had to open on a fallback.
    static func caretOnly(for pid: pid_t?) -> PaletteAnchor? {
        caretAnchor(pid: pid)
    }

    @MainActor
    private static func resolveAnchor(for pid: pid_t?) -> PaletteAnchor {
        if let caret = caretAnchor(pid: pid) { return caret }

        // Ask Chromium/Electron to expose its accessibility tree, then use the
        // best answer available now. Waiting here makes the palette feel slower
        // than the gesture; PaletteController keeps checking for the real caret
        // after the panel is already visible.
        nudgeChromium(pid: pid)
        if let caret = caretAnchor(pid: pid) { return caret }
        BPLog.log("caret not immediately available; opening on fallback")
        return fallbackAnchor(pid: pid)
    }

    private static func fallbackAnchor(pid: pid_t?) -> PaletteAnchor {
        if let element = focusedElement(pid: pid) {
            if let grid = gridAnchor(of: element, pid: pid) { return grid }
        }
        let cursor = NSEvent.mouseLocation
        let rect = NSRect(x: cursor.x, y: cursor.y, width: 2, height: 18)
        BPLog.log("fallback=cursor \(cursor)")
        return PaletteAnchor(rect: rect, alignmentX: cursor.x, fromCaret: false)
    }

    // MARK: - Terminals

    /// GPU terminals answer no bounds-for-range (ghostty#9932, planned for 1.4),
    /// but their visible text plus the content frame is a character grid, and
    /// typing lands at the end of the bottom-most prompt-shaped line. Recognised
    /// by that shape rather than by bundle ID, so any terminal qualifies.
    private static func gridAnchor(of element: AXUIElement, pid: pid_t?) -> PaletteAnchor? {
        guard !answersCaretGeometry(element),
              let frame = elementFrame(of: element).map(convert),
              isOnScreen(frame), frame.height > 200,
              let text = stringValue(of: element)
        else { return nil }
        return gridAnchor(text: text, frame: frame, pid: pid)
    }

    /// Whether the element can answer caret geometry at all. One that cannot is a
    /// character grid; one that can is a document that merely declined this time.
    /// That capability, not the content, is what separates a terminal from a text
    /// file whose last line happens to begin with `#` or `>`.
    private static func answersCaretGeometry(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success,
              let names = names as? [String]
        else { return true } // unknown: stay off the grid path
        return names.contains(kAXBoundsForRangeParameterizedAttribute as String)
    }

    private static let promptGlyphs: Set<Character> = ["❯", "›", ">", "$", "%", "#", "➜", "→", "λ"]

    /// Full-screen TUIs frame their input line in box drawing, so the prompt sits
    /// inside the border rather than at either end of the row.
    private static func promptCore(of line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: boxDrawing)
            .trimmingCharacters(in: .whitespaces)
    }

    private static let boxDrawing: CharacterSet = {
        var set = CharacterSet(charactersIn: UnicodeScalar(0x2500)! ... UnicodeScalar(0x257F)!)
        set.insert(charactersIn: "|")
        return set
    }()

    /// Cell sizes measured from moments the buffer spanned the grid, remembered
    /// per process so short buffers (a fresh prompt) reuse real geometry.
    private static var measuredCells: [pid_t: CGSize] = [:]

    /// Widest line seen per process, so one wide moment teaches the column width
    /// for every quiet prompt afterwards. Tied to the width it was seen at, since
    /// resizing the window rewrites how many columns there are.
    private static var observedColumns: [pid_t: (frameWidth: CGFloat, columns: Int)] = [:]

    private static func gridAnchor(text: String, frame: NSRect, pid: pid_t?) -> PaletteAnchor? {
        let lines = text.components(separatedBy: "\n")
        guard let row = lines.lastIndex(where: { line in
            let trimmed = promptCore(of: line)
            guard let first = trimmed.first, let last = trimmed.last else { return false }
            return promptGlyphs.contains(first) || promptGlyphs.contains(last)
        }) else { return nil }

        var measured = pid.flatMap { measuredCells[$0] } ?? .zero

        // When the buffer fills the grid the division is an exact measurement
        // of the cell height; a short buffer reuses the last measurement.
        // A terminal reports only the rows it has used, so a fresh prompt yields
        // a spacing far larger than any cell; that measurement is discarded
        // rather than disqualifying, and the last real one is reused.
        let naturalHeight = frame.height / CGFloat(lines.count)
        if (8 ... 40).contains(naturalHeight) { measured.height = naturalHeight }
        let cell = measured.height > 0 ? measured.height : 17

        // Same for width: trust it only when the longest line spans the grid,
        // which a monospace width-to-height ratio confirms. A bare shell prompt
        // never spans the grid, but earlier output might have, so the widest line
        // seen from this process is kept until the window changes size.
        var columns = lines.lazy.map(\.count).max() ?? 0
        if let pid {
            if let seen = observedColumns[pid], seen.frameWidth == frame.width {
                columns = max(columns, seen.columns)
            }
            observedColumns[pid] = (frame.width, columns)
        }
        let naturalWidth = frame.width / CGFloat(max(columns, 1))
        if naturalWidth > cell * 0.3, naturalWidth < cell * 0.8 { measured.width = naturalWidth }
        if let pid, measured != .zero {
            measuredCells[pid] = measured
            measuredCells = measuredCells.filter { NSRunningApplication(processIdentifier: $0.key) != nil }
            observedColumns = observedColumns.filter { NSRunningApplication(processIdentifier: $0.key) != nil }
        }

        // Shorter than the grid the buffer hangs from the top, longer only the
        // tail is visible.
        let y = naturalHeight < 8
            ? frame.minY + CGFloat(lines.count - 1 - row) * cell
            : frame.maxY - CGFloat(row + 1) * cell

        var x = frame.minX
        if measured.width > 0 {
            let gridColumns = Int(frame.width / measured.width)
            x = frame.minX + CGFloat(min(lines[row].count + 1, gridColumns)) * measured.width
        }
        let rect = NSRect(
            x: min(x, frame.maxX - 8),
            y: max(frame.minY, min(y, frame.maxY - cell)),
            width: 2,
            height: cell
        )
        BPLog.log("terminal grid rows=\(lines.count) row=\(row) cell=\(measured) rect=\(rect)")
        return PaletteAnchor(rect: rect, alignmentX: rect.minX, fromCaret: false)
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    private static func appElement(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// Warming an app when it activates means its lazy Chromium accessibility
    /// tree is ready by the time the palette opens. AXEnhancedUserInterface is
    /// the flag Chrome honors, AXManualAccessibility the Electron one; both are
    /// inert everywhere else.
    static func warmUp(pid: pid_t) {
        let app = appElement(pid)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Touch the focused caret once after an app activates. This prompts lazy
    /// Chromium/Electron accessibility trees to finish before the user's first
    /// modifier tap, without caching a field that may change afterward.
    @MainActor
    static func prefetchCaret(pid: pid_t) {
        nudgeChromium(pid: pid)
        _ = caretAnchor(pid: pid)
    }

    /// Words the focused field uses to describe itself (placeholder, title,
    /// accessibility description, or an associated label element). Fact ranking
    /// matches these against fact names, so an "Email" field surfaces email facts.
    static func fieldHint(for pid: pid_t?) -> String? {
        guard let element = focusedElement(pid: pid) else { return nil }
        var parts: [String] = []
        for attribute in [kAXPlaceholderValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
               let text = ref as? String, !text.isEmpty {
                parts.append(text)
            }
        }
        var labelRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleUIElementAttribute as CFString, &labelRef) == .success,
           let raw = labelRef, CFGetTypeID(raw) == AXUIElementGetTypeID() {
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(raw as! AXUIElement, kAXValueAttribute as CFString, &valueRef) == .success,
               let text = valueRef as? String, !text.isEmpty {
                parts.append(text)
            }
        }
        let hint = parts.joined(separator: " ")
        BPLog.log("fieldHint=\(hint.isEmpty ? "none" : hint)")
        return hint.isEmpty ? nil : hint
    }

    private static func caretAnchor(pid: pid_t?) -> PaletteAnchor? {
        guard let element = focusedElement(pid: pid) else { return nil }
        guard let axRect = caretRect(of: element) else {
            BPLog.log("caretRect unavailable")
            return nil
        }
        let rect = convert(axRect)
        // Chromium reports the omnibox caret as a zero-size rect in a screen corner.
        let valid = isOnScreen(rect) && rect.height >= 4 && rect.height < 120 && rect.width < 200
        BPLog.log("caretRect ax=\(axRect) converted=\(rect) valid=\(valid)")
        guard valid else { return nil }

        if let frame = elementFrame(of: element).map(convert), isOnScreen(frame) {
            // A caret nowhere near its own element is stale geometry.
            guard frame.insetBy(dx: -8, dy: -8).intersects(rect) else {
                BPLog.log("caret outside focused element; ignoring")
                return nil
            }
            // In compact text boxes, clear the whole box instead of hugging the
            // caret so the pills never brush the box border.
            if frame.height < 120 {
                return PaletteAnchor(
                    rect: NSRect(x: rect.minX, y: frame.minY, width: rect.width, height: frame.height),
                    alignmentX: rect.minX,
                    fromCaret: true
                )
            }
        }
        return PaletteAnchor(rect: rect, alignmentX: rect.minX, fromCaret: true)
    }

    private static func caretRect(of element: AXUIElement) -> CGRect? {
        rangeCaretRect(of: element) ?? markerCaretRect(of: element)
    }

    private static func rangeCaretRect(of element: AXUIElement) -> CGRect? {
        guard let selection = selectedRange(of: element) else { return nil }

        // A live selection's bounds span the whole selection; the insertion point
        // is the collapsed range at its start. Some apps return nothing for
        // zero-length ranges, so widen before giving up.
        let candidates = [
            CFRange(location: selection.location, length: 0),
            CFRange(location: max(selection.location - 1, 0), length: 1),
            selection,
        ]
        for candidate in candidates {
            if let rect = boundsForRange(candidate, of: element) { return rect }
        }
        return linePrefixCaretRect(of: element, selection: selection)
    }

    /// Editors that answer no bounds for a bare insertion point still answer for
    /// the text before it on its own line; that run's trailing edge is the caret.
    private static func linePrefixCaretRect(of element: AXUIElement, selection: CFRange) -> CGRect? {
        var lineRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXLineForIndexParameterizedAttribute as CFString,
            selection.location as CFNumber, &lineRef
        ) == .success, let line = lineRef as? Int else { return nil }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXRangeForLineParameterizedAttribute as CFString, line as CFNumber, &rangeRef
        ) == .success, let raw = rangeRef, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var lineRange = CFRange()
        guard AXValueGetValue((raw as! AXValue), .cfRange, &lineRange) else { return nil }

        let prefix = CFRange(location: lineRange.location, length: selection.location - lineRange.location)
        guard prefix.length > 0, let rect = boundsForRange(prefix, of: element) else { return nil }
        BPLog.log("caret from line prefix line=\(line) rect=\(rect)")
        return CGRect(x: rect.maxX, y: rect.minY, width: 2, height: rect.height)
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue((rangeValue as! AXValue), .cfRange, &selection) else { return nil }
        return selection
    }

    private static func boundsForRange(_ range: CFRange, of element: AXUIElement) -> CGRect? {
        var range = range
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsRef
        ) == .success, let boundsValue = boundsRef, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue((boundsValue as! AXValue), .cgRect, &rect),
              rect.origin != .zero, rect.height > 0 else { return nil }
        return rect
    }

    /// Rich web editors sometimes answer WebKit-style text markers when
    /// integer-range bounds come back empty.
    private static func markerCaretRect(of element: AXUIElement) -> CGRect? {
        var markerRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, "AXSelectedTextMarkerRange" as CFString, &markerRangeRef
        ) == .success, let markerRange = markerRangeRef else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForTextMarkerRange" as CFString, markerRange, &boundsRef
        ) == .success, let boundsValue = boundsRef, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue((boundsValue as! AXValue), .cgRect, &rect),
              rect.origin != .zero, rect.height > 0 else { return nil }
        BPLog.log("markerCaretRect=\(rect)")
        return rect
    }

    private static func elementFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, CFGetTypeID(posValue) == AXValueGetTypeID(),
              let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue((posValue as! AXValue), .cgPoint, &position)
        AXValueGetValue((sizeValue as! AXValue), .cgSize, &size)
        guard size != .zero else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// The target app's own focused element, or the system-wide one when no pid
    /// is known. Asking the app directly keeps working after the palette panel
    /// takes system focus.
    private static func focusedElement(pid: pid_t?) -> AXUIElement? {
        let container = pid.map { appElement($0) } ?? AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            container, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let raw = focusedRef, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        // When the palette itself holds focus (re-trigger while open), anchoring
        // to it would make each open drift from the last one's position.
        var elementPid: pid_t = 0
        AXUIElementGetPid(element, &elementPid)
        guard elementPid != getpid() else {
            BPLog.log("focusedElement is ours; ignoring")
            return nil
        }
        return element
    }

    // MARK: - Insertion

    /// Writes `value` straight into the focused field, with no pasteboard and no
    /// synthetic keystrokes. Returns false when the write can't be *proven* to
    /// have landed, so the caller can type instead.
    ///
    /// Proof is required because Chromium reports the attribute settable, accepts
    /// the write, returns success, and changes nothing. Trusting that would drop
    /// the value silently; typing after an unnoticed success would insert it twice.
    @MainActor
    static func insertText(_ value: String, pid: pid_t?) async -> Bool {
        guard let element = focusedElement(pid: pid) else { return false }
        // Nothing to compare against (secure fields, Zed) means no proof is possible.
        guard let before = stringValue(of: element) else {
            BPLog.log("insert: field is unreadable, not risking an unverifiable write")
            return false
        }
        guard AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, value as CFTypeRef
        ) == .success else { return false }

        for _ in 0 ..< 8 {
            try? await Task.sleep(for: .milliseconds(25))
            if let after = stringValue(of: element), after != before {
                BPLog.log("insert: landed via accessibility")
                return true
            }
        }
        BPLog.log("insert: accessibility write claimed success but changed nothing; typing instead")
        return false
    }

    /// Chromium/Electron apps expose caret geometry only after being asked nicely.
    private static func nudgeChromium(pid: pid_t?) {
        guard let pid = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        warmUp(pid: pid)
    }

    /// AX rects have a top-left origin on the primary display; AppKit's origin is bottom-left.
    private static func convert(_ axRect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: axRect.minX, y: primaryHeight - axRect.maxY, width: axRect.width, height: axRect.height)
    }

    private static func isOnScreen(_ rect: NSRect) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(rect) }
    }
}
