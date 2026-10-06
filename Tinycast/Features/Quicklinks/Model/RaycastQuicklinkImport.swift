import Foundation

/// Maps Raycast's `quicklinks` blob onto `Quicklink`. See docs/features/raycast-import.md.
enum RaycastQuicklinkImport {
    /// `openWith` is an app path or a platform id; both resolve through the injected lookup.
    static func parse(
        _ value: Any?,
        bundleIDForAppPath: (String) -> String? = bundleID(at:)
    ) -> [Quicklink] {
        let root: [String: Any]
        let entries: [[String: Any]]
        if let dict = value as? [String: Any] {
            root = dict
            entries = dict["quicklinks"] as? [[String: Any]] ?? []
        } else if let array = value as? [[String: Any]] {
            root = [:]
            entries = array
        } else {
            return []
        }

        var platforms: [String: String] = [:]
        for row in root["openWithPlatforms"] as? [[String: Any]] ?? [] {
            guard let id = row["id"] as? String,
                let path = row["macos"] as? String,
                !id.isEmpty, !path.isEmpty
            else { continue }
            platforms[id] = path
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()

        return entries.compactMap { entry in
            guard let name = trimmed(entry["name"]), let rawLink = trimmed(entry["link"]) else {
                return nil
            }
            let link = Quicklink.replacingArgumentTokens(rawLink)
            guard !link.isEmpty else { return nil }
            return Quicklink(
                name: name,
                link: link,
                openWithBundleID: openWithBundleID(
                    in: entry, platforms: platforms, bundleIDForAppPath: bundleIDForAppPath),
                createdAt: date(entry["createdAt"] as? String, fractional: fractional, whole: whole))
        }
    }

    private static func openWithBundleID(
        in entry: [String: Any],
        platforms: [String: String],
        bundleIDForAppPath: (String) -> String?
    ) -> String? {
        guard let raw = trimmed(entry["openWith"]) ?? trimmed(entry["applicationId"]) else {
            return nil
        }
        let path = raw.hasPrefix("/") ? raw : platforms[raw]
        return path.flatMap(bundleIDForAppPath)
    }

    private static func bundleID(at path: String) -> String? {
        Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
    }

    private static func date(
        _ string: String?, fractional: ISO8601DateFormatter, whole: ISO8601DateFormatter
    ) -> Date {
        guard let string else { return Date() }
        return fractional.date(from: string) ?? whole.date(from: string) ?? Date()
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
