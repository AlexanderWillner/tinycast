import Foundation

/// Walks an `Alfred.alfredpreferences` package. Foundation-only, so the harness compiles it.
/// See docs/features/alfred-import.md.
enum AlfredPreferencesReader {
    static func isPackage(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return false
        }
        return url.lastPathComponent.hasSuffix(".alfredpreferences")
            || fileManager.fileExists(atPath: url.appendingPathComponent("preferences").path)
    }

    static func read(package: URL, fileManager: FileManager = .default) throws -> AlfredImport.Result {
        guard fileManager.fileExists(atPath: package.appendingPathComponent("preferences").path)
        else { throw AlfredImportError.notAlfredPackage }
        let preferences = mergedPreferences(package: package, fileManager: fileManager)
        let links = mapQuicklinks(package: package, preferences: preferences, fileManager: fileManager)
        let workflows = AlfredWorkflowImport.scan(
            directory: package.appendingPathComponent("workflows"), fileManager: fileManager)
        return AlfredImport.Result(
            searchScopes: mapSearchScopes(preferences),
            paletteHotkey: AlfredHotkeyImport.binding(preferences.plist("hotkey")?["default"]),
            clipboardHotkey: AlfredHotkeyImport.binding(
                preferences.plist("features/clipboard")?["hotkey"]),
            snippets: mapSnippets(package: package, fileManager: fileManager),
            quicklinks: links.quicklinks,
            commands: workflows.commands,
            skippedWorkflows: workflows.skipped,
            skippedSearches: links.skipped)
    }

    // MARK: - Preferences

    /// Alfred keeps a Mac's own settings under `preferences/local/<id>`, one folder per machine a
    /// package has been synced through. The most recently written one is this Mac's, so it wins.
    private static func mergedPreferences(package: URL, fileManager: FileManager) -> Preferences {
        let root = package.appendingPathComponent("preferences")
        var merged = Preferences()
        merged.absorb(plists(in: root, skipping: ["local"], fileManager: fileManager))
        if let profile = newestLocalProfile(in: root, fileManager: fileManager) {
            merged.absorb(plists(in: profile, skipping: [], fileManager: fileManager))
        }
        return merged
    }

    private static func newestLocalProfile(in root: URL, fileManager: FileManager) -> URL? {
        let local = root.appendingPathComponent("local")
        // Sorted first, so two profiles written in the same second still resolve to one of them.
        let profiles =
            ((try? fileManager.contentsOfDirectory(
                at: local, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []).filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return profiles.max {
            newestWrite(of: $0, fileManager: fileManager)
                < newestWrite(of: $1, fileManager: fileManager)
        }
    }

    /// When a setting was last written, not when its folder happened to be touched.
    private static func newestWrite(of directory: URL, fileManager: FileManager) -> Date {
        let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        var newest = Date.distantPast
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate,
                modified > newest
            else { continue }
            newest = modified
        }
        return newest
    }

    /// Every `prefs.plist` under `root`, keyed by relative folder; hand-walked so symlinks keep working.
    private static func plists(
        in root: URL, skipping skipped: Set<String>, fileManager: FileManager
    ) -> [String: [String: Any]] {
        var values: [String: [String: Any]] = [:]
        var stack = [(dir: root, key: "", top: true)]
        while let current = stack.popLast() {
            let entries =
                (try? fileManager.contentsOfDirectory(
                    at: current.dir, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [])) ?? []
            for entry in entries {
                let isDir =
                    (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isDir {
                    if current.top, skipped.contains(entry.lastPathComponent) { continue }
                    let key =
                        current.key.isEmpty
                        ? entry.lastPathComponent : "\(current.key)/\(entry.lastPathComponent)"
                    stack.append((entry, key, false))
                } else if entry.lastPathComponent == "prefs.plist" {
                    // `preferences/prefs.plist` sits at the root and names no feature, so it has no key.
                    guard !current.key.isEmpty,
                        let data = try? Data(contentsOf: entry),
                        let plist = try? PropertyListSerialization.propertyList(
                            from: data, format: nil) as? [String: Any]
                    else { continue }
                    values[current.key] = plist
                }
            }
        }
        return values
    }

    /// The folders Alfred's own launcher walks, which is what `searchScopes` also holds.
    private static func mapSearchScopes(_ preferences: Preferences) -> [String]? {
        guard let scopes = preferences.plist("features/defaultresults")?["scope"] as? [String]
        else { return nil }
        let normalized = SearchScopes.normalize(scopes)
        return normalized.isEmpty ? nil : normalized
    }

    // MARK: - Snippets

    private static func mapSnippets(package: URL, fileManager: FileManager) -> [Snippet] {
        AlfredSnippetImport.collect(
            directory: package.appendingPathComponent("snippets"), fileManager: fileManager)
    }

    // MARK: - Quicklinks

    private static func mapQuicklinks(
        package: URL, preferences: Preferences, fileManager: FileManager
    ) -> (quicklinks: [Quicklink], skipped: [String]) {
        var links = AlfredQuicklinkImport.bookmarks(inPages: bookmarkPages(in: package))
        var skipped: [String] = []
        links.append(contentsOf: customSearches(preferences.plist("features/websearch")))
        let searches = defaultSearches(package: package, preferences: preferences,
            fileManager: fileManager)
        links.append(contentsOf: searches.quicklinks)
        skipped.append(contentsOf: searches.skipped)
        return (links, skipped)
    }

    private static func customSearches(_ preferences: [String: Any]?) -> [Quicklink] {
        guard let sites = preferences?["customSites"] as? [String: Any] else { return [] }
        return sites.keys.sorted().compactMap { uid in
            guard let site = sites[uid] as? [String: Any],
                site["enabled"] as? Bool ?? true,
                let url = site["url"] as? String, !url.isEmpty
            else { return nil }
            return AlfredQuicklinkImport.search(
                title: site["text"] as? String ?? "", keyword: site["keyword"] as? String, url: url)
        }
    }

    /// Alfred stores only a keyword per default search; the URL template lives inside Alfred, so a
    /// folder we have no template for is reported rather than guessed at.
    private static func defaultSearches(
        package: URL, preferences: Preferences, fileManager: FileManager
    ) -> (quicklinks: [Quicklink], skipped: [String]) {
        let root = package.appendingPathComponent("preferences/features/websearch")
        let folders =
            ((try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []).filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var quicklinks: [Quicklink] = []
        var skipped: [String] = []
        for folder in folders {
            let name = folder.lastPathComponent
            guard let prefs = preferences.plist("features/websearch/\(name)"),
                let keyword = prefs["keyword"] as? String, !keyword.isEmpty,
                prefs["enabled"] as? Bool ?? true
            else { continue }
            if let link = AlfredQuicklinkImport.defaultSearch(folder: name, keyword: keyword) {
                quicklinks.append(link)
            } else {
                skipped.append(name)
            }
        }
        return (quicklinks, skipped)
    }

    /// `remote/pages/pages.data` indexes the page files sitting beside it.
    private static func bookmarkPages(in package: URL) -> [[String: Any]] {
        let root = package.appendingPathComponent("remote/pages")
        guard let index = try? Data(contentsOf: root.appendingPathComponent("pages.data")),
            let plist = try? PropertyListSerialization.propertyList(from: index, format: nil)
                as? [String: Any],
            let uids = plist["pages"] as? [String]
        else { return [] }
        return uids.sorted().compactMap { uid in
            guard let data = try? Data(contentsOf: root.appendingPathComponent("\(uid).data")) else {
                return nil
            }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil))
                as? [String: Any]
        }
    }
}

/// Merged `prefs.plist`s keyed by their folder path under `preferences/`, the profile last.
private struct Preferences {
    private var values: [String: [String: Any]] = [:]

    mutating func absorb(_ other: [String: [String: Any]]) {
        for (key, value) in other { values[key] = value }
    }

    func plist(_ path: String) -> [String: Any]? { values[path] }
}
