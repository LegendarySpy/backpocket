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
        let mouse = NSEvent.mouseLocation
        BPLog.log("app=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") mouse=\(mouse)")

        if let caret = caretAnchor(pid: pid) { return caret }

        nudgeChromium(pid: pid)
        if let caret = caretAnchor(pid: pid) { return caret }

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

    /// Chromium builds its accessibility tree lazily, so caret geometry misses on
    /// the first ask. Warming the app when it activates means the tree is ready
    /// by the time the palette opens. AXManualAccessibility is Chromium-specific
    /// and inert everywhere else.
    static func warmUp(pid: pid_t) {
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
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
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
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
