import Foundation

/// Alfred keeps one snippet per file under `snippets/<Collection>/`, its keyword spelled
/// `<name> [<uid>].json`. See docs/features/alfred-import.md.
enum AlfredSnippetImport {
    /// The affixes a collection's `info.plist` puts around every keyword in it.
    struct KeywordAffixes {
        var prefix = ""
        var suffix = ""
    }

    /// One collection per folder, sorted, so a re-import lands in the same order.
    nonisolated static func collect(
        directory: URL, fileManager: FileManager = .default
    ) -> [Snippet] {
        collections(in: directory, fileManager: fileManager).flatMap {
            snippets(in: $0, fileManager: fileManager)
        }
    }

    nonisolated static func parse(_ data: Data, affixes: KeywordAffixes = KeywordAffixes())
        -> Snippet?
    {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let stored = root["alfredsnippet"] as? [String: Any],
            let name = trimmed(stored["name"]),
            let text = stored["snippet"] as? String
        else { return nil }
        let keyword =
            trimmed(stored["keyword"]).map { affixes.prefix + $0 + affixes.suffix }
        return Snippet(name: name, text: rewritten(text), keyword: keyword)
    }

    /// Alfred writes `{date:yyyy-MM-dd}` where the template engine reads `format=`.
    static func rewritten(_ text: String) -> String {
        guard text.contains("{") else { return text }
        var result = ""
        var position = text.startIndex
        while position < text.endIndex, let opening = text[position...].firstIndex(of: "{") {
            result += text[position..<opening]
            guard let closing = text[text.index(after: opening)...].firstIndex(of: "}") else {
                return result + text[opening...]
            }
            let body = String(text[text.index(after: opening)..<closing])
            result += "{" + (rewrittenBody(body) ?? body) + "}"
            position = text.index(after: closing)
        }
        return result + text[position...]
    }

    // MARK: - Placeholders

    /// A value the engine's own parser would reject, spelled the way Alfred's docs spell it.
    private static func rewrittenBody(_ body: String) -> String? {
        let halves = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let words = halves[0].split(separator: " ", omittingEmptySubsequences: true)
        guard let command = words.first?.lowercased() else { return nil }
        let offsets = words.dropFirst().joined(separator: " ")
        let argument = halves.count > 1 ? String(halves[1]) : nil

        switch command {
        case "date", "time", "datetime", "isodate", "isodatetime":
            return dateToken(ourName(for: command), offsets: offsets, argument: argument)
        case "clipboard":
            return clipboardToken(argument)
        default:
            return nil
        }
    }

    /// Alfred's ISO tokens are the same value under a name our engine does not carry.
    private static func ourName(for command: String) -> String {
        switch command {
        case "isodate": return "date"
        case "isodatetime": return "datetime"
        default: return command
        }
    }

    private static func dateToken(_ command: String, offsets: String, argument: String?) -> String? {
        var token = command
        if !offsets.isEmpty { token += " offset=\(offsets)" }
        if let format = resolvedFormat(command, argument) { token += " format=\(format)" }
        return token
    }

    /// Alfred's four named styles are the system's own, so they land as those patterns.
    private static func resolvedFormat(_ command: String, _ argument: String?) -> String? {
        guard let argument, !argument.isEmpty else { return nil }
        if argument == command {
            return ["date": "yyyy-MM-dd", "time": "HH:mm:ss", "datetime": "yyyy-MM-dd'T'HH:mm:ssZ"][command]
        }
        // Anything else is already an ICU pattern, which is what our `format=` takes.
        return namedStyles[command]?[argument] ?? argument
    }

    private static let namedStyles: [String: [String: String]] = [
        "date": [
            "short": "M/d/yy", "medium": "MMM d, y", "long": "MMMM d, y", "full": "EEEE, MMMM d, y"
        ],
        "time": [
            "short": "HH:mm", "medium": "HH:mm:ss", "long": "h:mm:ss a", "full": "h:mm:ss a zzz"
        ],
        "datetime": [
            "short": "M/d/yy HH:mm", "medium": "MMM d, y HH:mm:ss", "long": "MMMM d, y h:mm:ss a",
            "full": "EEEE, MMMM d, y h:mm:ss a zzz"
        ]
    ]

    /// `{clipboard:2}` is an offset, `{clipboard:uppercase}` a modifier; the rest is Alfred's.
    private static func clipboardToken(_ argument: String?) -> String? {
        guard let argument, !argument.isEmpty else { return "clipboard" }
        if Int(argument) != nil { return "clipboard offset=\(argument)" }
        return ["uppercase", "lowercase"].contains(argument) ? "clipboard |\(argument)" : nil
    }

    // MARK: - Reading

    /// Collections are the snippet folders; a snippet file loose in the root is Alfred's too.
    private static func collections(
        in directory: URL, fileManager: FileManager
    ) -> [URL] {
        let contents =
            (try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
        let folders = contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        return folders.isEmpty
            ? [directory]
            : folders.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func snippets(in collection: URL, fileManager: FileManager) -> [Snippet] {
        let contents =
            (try? fileManager.contentsOfDirectory(
                at: collection, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        let affixes = keywordAffixes(in: collection, fileManager: fileManager)
        return
            contents
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return parse(data, affixes: affixes)
            }
    }

    /// A collection can ask for a prefix or a suffix around every keyword typed into it.
    private static func keywordAffixes(in collection: URL, fileManager: FileManager) -> KeywordAffixes
    {
        let info = collection.appendingPathComponent("info.plist")
        guard let data = try? Data(contentsOf: info),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return KeywordAffixes() }
        return KeywordAffixes(
            prefix: plist["snippetkeywordprefix"] as? String ?? "",
            suffix: plist["snippetkeywordsuffix"] as? String ?? "")
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
