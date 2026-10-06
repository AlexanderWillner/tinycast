import Foundation

/// Turns the Alfred workflows Tinycast can run into custom commands. Alfred is a graph and we are
/// one script per command, so only a workflow that is exactly that shape comes over.
/// See docs/features/alfred-import.md.
enum AlfredWorkflowImport {
    /// A workflow folder per entry, `user.workflow.` prefixed or bundled with Alfred itself.
    nonisolated static func scan(
        directory: URL, fileManager: FileManager = .default
    ) -> (commands: [AlfredImport.Command], skipped: Int) {
        let contents =
            (try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        var commands: [AlfredImport.Command] = []
        var skipped = 0
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let info = url.appendingPathComponent("info.plist")
            guard (try? fileManager.contentsOfDirectory(atPath: url.path)) != nil else { continue }
            if let imported = command(infoPlist: info) {
                commands.append(imported)
            } else {
                skipped += 1
            }
        }
        return (commands, skipped)
    }

    static func command(infoPlist: URL) -> AlfredImport.Command? {
        guard let info = plist(at: infoPlist), info["disabled"] as? Bool != true else { return nil }
        let objects = info["objects"] as? [[String: Any]] ?? []
        let byID = Dictionary(
            objects.compactMap { object -> (String, [String: Any])? in
                guard let uid = object["uid"] as? String else { return nil }
                return (uid, object)
            },
            uniquingKeysWith: { first, _ in first })
        let connections = info["connections"] as? [String: Any] ?? [:]

        // One trigger and one script, so the mapping is never a guess between two branches.
        let triggers = objects.filter { isTrigger($0["type"] as? String) }
        guard triggers.count == 1, let trigger = triggers.first,
            let triggerID = trigger["uid"] as? String,
            let config = trigger["config"] as? [String: Any]
        else { return nil }
        let scripts = reachable(from: triggerID, connections: connections)
            .compactMap { byID[$0] }
            .filter { $0["type"] as? String == "alfred.workflow.action.script" }
        guard scripts.count == 1, let node = scripts.first,
            let scriptConfig = node["config"] as? [String: Any],
            // `0` is Alfred's own bash; every other interpreter is one we cannot stand in for.
            scriptConfig["type"] as? Int == 0,
            let source = (scriptConfig["script"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !source.isEmpty,
            (scriptConfig["scriptfile"] as? String ?? "").isEmpty
        else { return nil }

        let substitutesQuery = (scriptConfig["scriptargtype"] as? Int ?? 0) == 0
        guard let command = script(of: source, substitutesQuery: substitutesQuery) else {
            return nil
        }

        let keyword =
            (config["keyword"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name =
            (info["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? keyword?.nilIfEmpty
            ?? infoPlist.deletingLastPathComponent().lastPathComponent
        let hotkey =
            trigger["type"] as? String == "alfred.workflow.trigger.hotkey"
            ? AlfredHotkeyImport.binding([
                "key": config["hotkey"] ?? -1, "mod": config["hotmod"] ?? 0
            ]) : nil
        return AlfredImport.Command(
            command: CustomCommand(
                name: AlfredImport.named(name, keyword: keyword),
                command: command,
                arguments: takesInput(config, triggerType: trigger["type"] as? String ?? "")
                    ? [CustomCommandArgument(name: "argument", isOptional: true)] : [],
                // Alfred always opens the Run Script output, so a converted workflow does too.
                showsOutput: true),
            hotkey: hotkey)
    }

    /// `{query}` is substituted by Alfred before bash sees it; ours is the command's `$1`.
    private static func script(of source: String, substitutesQuery: Bool) -> String? {
        guard substitutesQuery, source.contains("{query}") else { return source }
        // Only an unquoted `"${1}"` lands right; inside quotes the result is Alfred's, not ours.
        guard !hasQuotedOccurrence(of: "{query}", in: source) else { return nil }
        return source.replacingOccurrences(of: "{query}", with: "\"${1}\"")
    }

    private static func hasQuotedOccurrence(of needle: String, in script: String) -> Bool {
        var index = script.startIndex
        var quote: Character?
        var escaped = false
        while index < script.endIndex {
            if let open = quote, !escaped, script[index...].hasPrefix(needle) { return true }
            let character = script[index]
            index = script.index(after: index)
            if escaped {
                escaped = false
            } else if let open = quote {
                // A backslash escapes only inside a double-quoted run; in single quotes it is itself.
                if character == "\\" && open == "\"" {
                    escaped = true
                } else if character == open {
                    quote = nil
                }
            } else if character == "'" || character == "\"" {
                quote = character
            }
        }
        return false
    }

    /// Alfred counts a keyword's and a hotkey's argument setting differently, so each is read in
    /// its own vocabulary: a keyword's `2` is "No argument", a hotkey's is `0`, and a hotkey's `3`
    /// is a fixed argument the workflow supplies rather than anything the user types.
    private static func takesInput(_ config: [String: Any], triggerType: String) -> Bool {
        guard triggerType == "alfred.workflow.trigger.hotkey" else {
            return (config["argumenttype"] as? Int ?? 0) != 2
        }
        return (1...2).contains(config["argument"] as? Int ?? 0)
    }

    private static func isTrigger(_ type: String?) -> Bool {
        type == "alfred.workflow.input.keyword" || type == "alfred.workflow.trigger.hotkey"
    }

    private static func reachable(from uid: String, connections: [String: Any]) -> Set<String> {
        var seen: Set<String> = []
        var pending = [uid]
        while let current = pending.popLast() {
            guard seen.insert(current).inserted else { continue }
            for edge in connections[current] as? [[String: Any]] ?? [] {
                if let destination = edge["destinationuid"] as? String { pending.append(destination) }
            }
        }
        return seen
    }

    private static func plist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return nil }
        return plist
    }
}

private extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
