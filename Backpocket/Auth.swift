import LocalAuthentication

/// Gates sensitive inserts behind Touch ID (or password fallback), with a grace
/// window so back-to-back inserts don't re-prompt.
@MainActor
enum Auth {
    static let gracePeriod: TimeInterval = 300
    private static var lastSuccess: TimeInterval = 0

    static func requireIfNeeded(reason: String, onSuccess: @escaping () -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSuccess < gracePeriod {
            onSuccess()
            return
        }
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async {
                guard success else { return }
                lastSuccess = ProcessInfo.processInfo.systemUptime
                onSuccess()
            }
        }
    }
}
