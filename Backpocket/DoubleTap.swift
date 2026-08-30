import AppKit

/// Fires on a quick double-tap of the chosen modifier key alone. Only key *timing*
/// is observed to cancel pending taps; characters are never read.
final class DoubleTapMonitor {
    static let shared = DoubleTapMonitor()

    private static let window: TimeInterval = 0.4

    private var lastTap: TimeInterval = 0
    private var optionWasDown = false
    private var interrupted = false
    private var monitors: [Any] = []
    private var action: (() -> Void)?
    var onFirstTap: (() -> Void)?

    func start(action: @escaping () -> Void) {
        self.action = action
        restart()
    }

    /// Monitors registered without accessibility trust silently deliver nothing,
    /// so they get torn down and rebuilt when trust arrives.
    func restart() {
        guard action != nil else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        lastTap = 0
        optionWasDown = false
        interrupted = false

        let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] event in
            self?.handle(event)
        })
        let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] event in
            self?.handle(event)
            return event
        })
        monitors = [global, local].compactMap { $0 }
    }

    private var triggerFlag: NSEvent.ModifierFlags {
        let saved = UserDefaults.standard.string(forKey: TriggerModifier.defaultsKey) ?? ""
        return (TriggerModifier(rawValue: saved) ?? .option).flags
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            interrupted = true
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == triggerFlag, !optionWasDown {
            optionWasDown = true
            let now = ProcessInfo.processInfo.systemUptime
            if !interrupted, now - lastTap < Self.window {
                lastTap = 0
                DispatchQueue.main.async { self.action?() }
            } else {
                lastTap = now
                DispatchQueue.main.async { self.onFirstTap?() }
            }
            interrupted = false
        } else if flags.isEmpty {
            optionWasDown = false
        } else {
            optionWasDown = !flags.intersection(triggerFlag).isEmpty
            interrupted = true
        }
    }
}
