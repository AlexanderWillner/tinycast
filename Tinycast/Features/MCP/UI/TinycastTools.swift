import AppKit
import Foundation

/// Tinycast's own actions as model tools: the launcher, callable. The transport is never used;
/// this server runs in-process, so these tools stay out of CLI routes that start their own copies.
enum TinycastTools {
    static let slug = "tinycast"
    static let title = "Tinycast"
    /// Stable for the process, which is all chat grants and menus keyed by it need.
    static let serverID = UUID()

    static func server() -> MCPServer {
        MCPServer(id: serverID, name: title, slug: slug, isEnabled: true, trust: .ask)
    }

    struct SearchArgs: Decodable {
        let query: String
    }

    struct RunArgs: Decodable {
        let id: String
    }

    static func tools() -> [AITool] {
        [
            AITool(
                name: MCPToolName.compose(slug: slug, tool: "launcher_search"),
                description:
                    "Search Tinycast's launcher for apps, files, windows, shortcuts and more. "
                    + "Returns entry ids to run.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("What to look up")
                        ])
                    ]),
                    "required": .array([.string("query")])
                ]),
                origin: title, title: "Search launcher"),
            AITool(
                name: MCPToolName.compose(slug: slug, tool: "launcher_run"),
                description:
                    "Run a launcher entry by id from a search. The user confirms each run.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("An entry id from a search")
                        ])
                    ]),
                    "required": .array([.string("id")])
                ]),
                origin: title, title: "Run launcher entry")
        ]
    }

    /// Exhaustive: a new launcher kind fails to build until it lands on one side.
    /// Blocked: shell, auto-typing, unaudited system actions, AI-invoking-AI.
    static func runnable(_ kind: AppEntry.Kind) -> Bool {
        switch kind {
        case .application, .systemSettings, .command, .quicklink, .windowCommand, .windowLayout,
            .windowRoom, .meeting, .appleShortcut, .extensionCommand:
            return true
        case .quickAction, .customCommand, .snippet, .systemAction:
            return false
        }
    }

    @MainActor
    static func search(
        _ query: String, in index: AppIndex, cache: inout [String: AppEntry]
    ) -> String {
        cache.removeAll()
        let hits = index.matches(query, limit: 8).filter { runnable($0.kind) }
        for hit in hits { cache[hit.id] = hit }
        guard !hits.isEmpty else { return "No runnable launcher entries match." }
        return hits.map { entry in
            "• \(entry.name) (\(entry.kind.rawValue))"
                + (entry.subtitle.map { " — \($0)" } ?? "") + " — id: \(entry.id)"
        }.joined(separator: "\n")
    }

    @MainActor
    static func run(
        id: String, cache: [String: AppEntry], launcher: LauncherCoordinator
    ) -> String {
        guard let entry = cache[id] else {
            return "Unknown id. Search first and use a listed id."
        }
        guard runnable(entry.kind) else { return "That entry cannot run from here." }
        launcher.launch(entry, fromAI: true)
        return "Ran \(entry.name)."
    }
}
