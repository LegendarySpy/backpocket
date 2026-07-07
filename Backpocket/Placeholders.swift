import AppKit
import Foundation

enum PlaceholderResolver {
    struct Context {
        var appName: String?
        var addText: String?
    }

    /// Marks where the palette's add-text ("email+work") lands inside a value.
    static let addTextToken = "{+}"

    static let builtInFacts = [
        Fact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!, name: "Date", value: "{date}"),
        Fact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!, name: "Short Date", value: "{shortdate}"),
        Fact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!, name: "Long Date", value: "{longdate}"),
        Fact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000104")!, name: "Tomorrow", value: "{date:+1}"),
        Fact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000105")!, name: "Next Week", value: "{date:+7}"),
        Fact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000106")!, name: "Time", value: "{time}"),
        Fact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000107")!, name: "Date and Time", value: "{datetime}"),
        Fact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000108")!, name: "ISO Date", value: "{iso}"),
        Fact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000109")!, name: "Timestamp", value: "{timestamp}"),
        Fact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000110")!, name: "Clipboard", value: "{clipboard}"),
        Fact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!, name: "Username", value: "{username}"),
        Fact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000112")!, name: "Full Name", value: "{fullname}"),
        Fact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000113")!, name: "Computer Name", value: "{hostname}"),
        Fact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000114")!, name: "Current App", value: "{app}"),
        Fact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000115")!, name: "UUID", value: "{uuid}")
    ]

    static func resolve(
        _ text: String,
        now: Date = Date(),
        pasteboard: NSPasteboard = .general,
        context: Context = Context()
    ) -> String {
        var output = ""
        var cursor = text.startIndex

        while let open = text[cursor...].firstIndex(of: "{") {
            output += text[cursor..<open]

            guard let close = text[text.index(after: open)...].firstIndex(of: "}") else {
                output += text[open...]
                return output
            }

            let token = String(text[text.index(after: open)..<close])
            if let replacement = replacement(for: token, now: now, pasteboard: pasteboard, context: context) {
                output += replacement
            } else {
                output += text[open...close]
            }
            cursor = text.index(after: close)
        }

        output += text[cursor...]
        return output
    }

    private static func replacement(
        for token: String,
        now: Date,
        pasteboard: NSPasteboard,
        context: Context
    ) -> String? {
        let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let argument = parts.count > 1 ? String(parts[1]) : nil

        switch name {
        case "+":
            return context.addText ?? ""
        case "date":
            return format(resolveDate(now, argument: argument), defaultFormat: "yyyy-MM-dd", customFormat: formatArgument(argument))
        case "shortdate":
            return DateFormatter.localizedString(from: resolveDate(now, argument: argument), dateStyle: .short, timeStyle: .none)
        case "longdate":
            return DateFormatter.localizedString(from: resolveDate(now, argument: argument), dateStyle: .long, timeStyle: .none)
        case "time":
            return format(now, defaultFormat: "HH:mm", customFormat: argument)
        case "datetime", "date-time":
            return format(resolveDate(now, argument: argument), defaultFormat: "yyyy-MM-dd HH:mm", customFormat: formatArgument(argument))
        case "iso":
            return ISO8601DateFormatter().string(from: resolveDate(now, argument: argument))
        case "timestamp":
            return String(Int(resolveDate(now, argument: argument).timeIntervalSince1970))
        case "weekday":
            return format(resolveDate(now, argument: argument), defaultFormat: "EEEE", customFormat: formatArgument(argument))
        case "month":
            return format(resolveDate(now, argument: argument), defaultFormat: "MMMM", customFormat: formatArgument(argument))
        case "year":
            return format(resolveDate(now, argument: argument), defaultFormat: "yyyy", customFormat: formatArgument(argument))
        case "clipboard":
            return pasteboard.string(forType: .string) ?? ""
        case "username":
            return NSUserName()
        case "fullname":
            return NSFullUserName()
        case "hostname":
            return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        case "app":
            return context.appName ?? ""
        case "uuid":
            return UUID().uuidString
        default:
            return nil
        }
    }

    private static func format(_ date: Date, defaultFormat: String, customFormat: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = customFormat?.isEmpty == false ? customFormat : defaultFormat
        return formatter.string(from: date)
    }

    private static func resolveDate(_ date: Date, argument: String?) -> Date {
        guard let offset = offsetDays(from: argument) else { return date }
        return Calendar.current.date(byAdding: .day, value: offset, to: date) ?? date
    }

    private static func formatArgument(_ argument: String?) -> String? {
        guard let argument else { return nil }
        let parts = argument.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if offsetDays(from: String(parts[0])) != nil {
            return parts.count > 1 ? String(parts[1]) : nil
        }
        return argument
    }

    private static func offsetDays(from argument: String?) -> Int? {
        guard let argument, let first = argument.first, first == "+" || first == "-" else { return nil }
        let number = argument.dropFirst().prefix { $0.isNumber }
        guard !number.isEmpty else { return nil }
        let value = Int(number) ?? 0
        return first == "-" ? -value : value
    }
}
