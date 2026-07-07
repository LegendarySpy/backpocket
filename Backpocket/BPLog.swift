import Foundation
import os

/// Geometry debug log. Never logs fact values.
/// View with Console.app or: log show --predicate 'subsystem == "com.backpocket.mac"'
enum BPLog {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.backpocket.mac",
        category: "geometry"
    )

    static func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }
}
