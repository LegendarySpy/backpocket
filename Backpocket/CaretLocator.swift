import AppKit
import ApplicationServices

struct PaletteAnchor {
    let rect: NSRect        // caret, text box, or fallback point in AppKit coordinates
    let alignmentX: CGFloat // x position the input pill should hug
}

enum CaretLocator {
    /// Anchor for the palette. Order: caret bounds -> mouse if it's inside a
    /// large focused element -> element's top-left -> mouse.
    static func anchor() -> PaletteAnchor {
        let mouse = NSEvent.mouseLocation
        BPLog.log("app=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") mouse=\(mouse)")

        if let caret = caretAnchor() { return caret }

        nudgeChromium()
        if let caret = caretAnchor() { return caret }

        if let axFrame = focusedElementFrame() {
            let frame = convert(axFrame)
            BPLog.log("elementFrame ax=\(axFrame) converted=\(frame) onScreen=\(isOnScreen(frame))")
            if isOnScreen(frame) {
                if frame.height > 200, frame.contains(mouse) {
                    return PaletteAnchor(rect: pointRect(mouse), alignmentX: mouse.x)
                }
                return PaletteAnchor(
                    rect: frame,
                    alignmentX: frame.minX
                )
            }
        } else {
            BPLog.log("elementFrame unavailable")
        }
        BPLog.log("fallback=mouse")
        return PaletteAnchor(rect: pointRect(mouse), alignmentX: mouse.x)
    }

    private static func caretAnchor() -> PaletteAnchor? {
        guard let axRect = caretRect() else {
            BPLog.log("caretRect unavailable")
            return nil
        }
        let rect = convert(axRect)
        // Chromium reports the omnibox caret as a zero-size rect in a screen corner.
        let valid = isOnScreen(rect) && rect.height >= 4 && rect.height < 120 && rect.width < 200
        BPLog.log("caretRect ax=\(axRect) converted=\(rect) valid=\(valid)")
        guard valid else { return nil }
        return PaletteAnchor(rect: rect, alignmentX: rect.minX)
    }

    private static func caretRect() -> CGRect? {
        guard let element = focusedElement() else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsRef
        ) == .success, let boundsValue = boundsRef, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue((boundsValue as! AXValue), .cgRect, &rect), rect.origin != .zero else { return nil }
        return rect
    }

    private static func focusedElementFrame() -> CGRect? {
        guard let element = focusedElement() else { return nil }
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

    private static func focusedElement() -> AXUIElement? {
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let raw = focusedRef, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        // When the palette itself holds focus (re-trigger while open), anchoring
        // to it would make each open drift from the last one's position.
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != getpid() else {
            BPLog.log("focusedElement is ours; ignoring")
            return nil
        }
        return element
    }

    /// Chromium/Electron apps expose caret geometry only after being asked nicely.
    private static func nudgeChromium() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
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
