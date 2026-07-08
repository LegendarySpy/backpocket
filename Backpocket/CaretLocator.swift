import AppKit
import ApplicationServices

struct PaletteAnchor {
    let rect: NSRect        // caret, text box, or fallback point in AppKit coordinates
    let alignmentX: CGFloat // x position the input pill should hug
    let fromCaret: Bool     // anchored to real caret geometry, not a fallback
}

enum CaretLocator {
    /// Anchor for the palette, resolved against `pid`'s focused element so it
    /// stays valid even once the palette itself holds system focus.
    /// Order: caret bounds -> focused element's frame -> mouse.
    static func anchor(for pid: pid_t?) -> PaletteAnchor {
        if let caret = caretAnchor(pid: pid) { return caret }
        nudgeChromium(pid: pid)
        if let caret = caretAnchor(pid: pid) { return caret }
        return fallbackAnchor(pid: pid)
    }

    /// Like `anchor(for:)`, but with a short grace period: Chromium builds its
    /// accessibility tree asynchronously after the nudge, and waiting a few
    /// beats for the caret beats showing the palette somewhere it doesn't belong.
    @MainActor
    static func resolveAnchor(for pid: pid_t?, completion: @escaping @MainActor (PaletteAnchor) -> Void) {
        BPLog.log("app=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") mouse=\(NSEvent.mouseLocation)")
        if let caret = caretAnchor(pid: pid) {
            completion(caret)
            return
        }
        // Polling exists for Chromium's async tree; a terminal never grows a caret.
        if isTerminal(pid) {
            completion(fallbackAnchor(pid: pid))
            return
        }
        nudgeChromium(pid: pid)
        pollForCaret(pid: pid, attempt: 1, completion: completion)
    }

    private static let pollAttempts = 5
    private static let pollInterval: TimeInterval = 0.05

    @MainActor
    private static func pollForCaret(
        pid: pid_t?, attempt: Int, completion: @escaping @MainActor (PaletteAnchor) -> Void
    ) {
        if let caret = caretAnchor(pid: pid) {
            BPLog.log("caret appeared on poll \(attempt)")
            completion(caret)
            return
        }
        guard attempt < pollAttempts else {
            BPLog.log("no caret after \(attempt) polls; falling back")
            completion(fallbackAnchor(pid: pid))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            pollForCaret(pid: pid, attempt: attempt + 1, completion: completion)
        }
    }

    private static func fallbackAnchor(pid: pid_t?) -> PaletteAnchor {
        if isTerminal(pid), let anchor = terminalAnchor(pid: pid) { return anchor }
        let mouse = NSEvent.mouseLocation
        if let element = focusedElement(pid: pid),
           let frame = elementFrame(of: element).map(convert) {
            BPLog.log("elementFrame converted=\(frame) onScreen=\(isOnScreen(frame))")
            if isOnScreen(frame) {
                // A huge focused element (web area, canvas) says nothing about
                // where the user is looking; the mouse is the better guess.
                if frame.height > 200 {
                    return PaletteAnchor(rect: pointRect(mouse), alignmentX: mouse.x, fromCaret: false)
                }
                return PaletteAnchor(rect: frame, alignmentX: frame.minX, fromCaret: false)
            }
        } else {
            BPLog.log("elementFrame unavailable")
        }
        BPLog.log("fallback=mouse")
        return PaletteAnchor(rect: pointRect(mouse), alignmentX: mouse.x, fromCaret: false)
    }

    // MARK: - Terminals

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
    ]

    private static func isTerminal(_ pid: pid_t?) -> Bool {
        guard let pid, let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else {
            return false
        }
        return terminalBundleIDs.contains(bundleID)
    }

    /// GPU terminals answer no bounds-for-range (ghostty#9932, planned for 1.4),
    /// but their visible text plus the content frame is a character grid, and
    /// typing lands at the end of the bottom-most prompt-shaped line.
    private static func terminalAnchor(pid: pid_t?) -> PaletteAnchor? {
        let element = focusedElement(pid: pid)
        let frame = element.flatMap { elementFrame(of: $0).map(convert) } ?? focusedWindowFrame(pid: pid)
        // Small focused elements (Warp's input block) do better on the generic path.
        guard let frame, isOnScreen(frame), frame.height > 200 else { return nil }
        guard let element, let text = stringValue(of: element),
              let anchor = gridAnchor(text: text, frame: frame, pid: pid) else {
            BPLog.log("terminal fallback=frame bottom-left frame=\(frame)")
            let cell = pid.flatMap { measuredCells[$0]?.height } ?? 17
            let rect = NSRect(x: frame.minX, y: frame.minY, width: 2, height: cell)
            return PaletteAnchor(rect: rect, alignmentX: rect.minX, fromCaret: false)
        }
        return anchor
    }

    private static let promptGlyphs: Set<Character> = ["❯", "›", ">", "$", "%", "#", "➜", "→", "λ"]

    /// Cell sizes measured from moments the buffer spanned the grid, remembered
    /// per process so short buffers (a fresh prompt) reuse real geometry.
    private static var measuredCells: [pid_t: CGSize] = [:]

    private static func gridAnchor(text: String, frame: NSRect, pid: pid_t?) -> PaletteAnchor? {
        let lines = text.components(separatedBy: "\n")
        guard let row = lines.lastIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, let last = trimmed.last else { return false }
            return promptGlyphs.contains(first) || promptGlyphs.contains(last)
        }) else { return nil }

        var measured = pid.flatMap { measuredCells[$0] } ?? .zero

        // When the buffer fills the grid the division is an exact measurement
        // of the cell height; a short buffer reuses the last measurement.
        let naturalHeight = frame.height / CGFloat(lines.count)
        if (8 ... 40).contains(naturalHeight) { measured.height = naturalHeight }
        let cell = measured.height > 0 ? measured.height : 17

        // Same for width: trust it only when the longest line spans the grid,
        // which a monospace width-to-height ratio confirms.
        let columns = lines.lazy.map(\.count).max() ?? 0
        let naturalWidth = frame.width / CGFloat(max(columns, 1))
        if naturalWidth > cell * 0.3, naturalWidth < cell * 0.8 { measured.width = naturalWidth }
        if let pid, measured != .zero {
            measuredCells[pid] = measured
            measuredCells = measuredCells.filter { NSRunningApplication(processIdentifier: $0.key) != nil }
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

    private static func focusedWindowFrame(pid: pid_t?) -> NSRect? {
        guard let pid else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &ref
        ) == .success, let raw = ref, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return elementFrame(of: raw as! AXUIElement).map(convert)
    }

    /// Warming an app when it activates means its lazy Chromium accessibility
    /// tree is ready by the time the palette opens. AXEnhancedUserInterface is
    /// the flag Chrome honors, AXManualAccessibility the Electron one; both are
    /// inert everywhere else.
    static func warmUp(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
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
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue((rangeValue as! AXValue), .cfRange, &selection) else { return nil }

        // A live selection's bounds span the whole selection; the insertion point
        // is the collapsed range at its start. Some apps return nothing for
        // zero-length ranges, so widen before giving up.
        let candidates = [
            CFRange(location: selection.location, length: 0),
            CFRange(location: max(selection.location - 1, 0), length: 1),
            selection,
        ]
        for var candidate in candidates {
            guard let candidateValue = AXValueCreate(.cfRange, &candidate) else { continue }
            var boundsRef: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, candidateValue, &boundsRef
            ) == .success, let boundsValue = boundsRef, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { continue }
            var rect = CGRect.zero
            guard AXValueGetValue((boundsValue as! AXValue), .cgRect, &rect),
                  rect.origin != .zero, rect.height > 0 else { continue }
            return rect
        }
        return nil
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
        let container = pid.map { AXUIElementCreateApplication($0) } ?? AXUIElementCreateSystemWide()
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

    private static func pointRect(_ point: CGPoint) -> NSRect {
        NSRect(x: point.x, y: point.y, width: 1, height: 1)
    }
}
