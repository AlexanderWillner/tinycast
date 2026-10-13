import Foundation
import Observation

/// MCP's action surface: what is running, what the model may call, and who is asked first.
@MainActor
@Observable
final class MCPCoordinator {
    private let settings: AppSettings
    private let store: MCPSettingsStore
    private let manager: MCPServerManager
    private unowned let core: AppCore

    /// Servers each conversation was granted; keyed, since a dialog may outlive a chat switch.
    @ObservationIgnored private var chatGrants: [UUID: Set<UUID>] = [:]
    /// Entries a recent search listed, so runs use an id the model actually saw.
    @ObservationIgnored private var tinycastEntries: [String: AppEntry] = [:]
    private let tinycastServer = TinycastMCPServer()

    init(
        settings: AppSettings, store: MCPSettingsStore, manager: MCPServerManager, core: AppCore
    ) {
        self.settings = settings
        self.store = store
        self.manager = manager
        self.core = core
        tinycastServer.onCall = { [weak self] name, arguments in
            guard let self else { return (content: "Gone.", isError: true) }
            return await self.handleTinycastCall(name: name, arguments: arguments)
        }
    }

    var isActive: Bool { settings.aiEnabled && settings.mcpEnabled }

    /// Off means off: no connection, no resident process, and nothing offered to a model.
    func applyEnabled() {
        defer { dropWithdrawnServers() }
        guard isActive else {
            core.mcpOAuth.stop()
            manager.stop()
            tinycastServer.stop()
            return
        }
        manager.reconcile(ownServers)
        reconcileSharing()
    }

    /// The HTTP server mirrors the switches: no tools, no sharing, no listener.
    private func reconcileSharing() {
        guard settings.tinycastMCPEnabled, settings.tinycastMCPSharingEnabled else {
            tinycastServer.stop()
            return
        }
        guard let password = sharingPassword() ?? generateSharingPassword() else {
            tinycastServer.stop()
            return
        }
        tinycastServer.tools = TinycastTools.tools()
        tinycastServer.credentials = (settings.tinycastMCPUsername, password)
        tinycastServer.version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        tinycastServer.start()
    }

    var tinycastSharingState: TinycastMCPServer.State { tinycastServer.state }

    /// What an outside client pastes into its MCP settings; nil while sharing is off.
    func tinycastConnectionSnippet() -> String? {
        guard settings.tinycastMCPEnabled, settings.tinycastMCPSharingEnabled,
            let password = sharingPassword()
        else { return nil }
        let header =
            "Basic "
            + TinycastMCPWire.basicAuthValue(
                username: settings.tinycastMCPUsername, password: password)
        return "{\"type\": \"http\", \"url\": \"\(TinycastMCPWire.urlString)\", "
            + "\"headers\": {\"Authorization\": \"\(header)\"}}"
    }

    /// The sharing password, generated once and kept in the Keychain, never in UserDefaults.
    func sharingPassword() -> String? {
        let keychain = KeychainSecretStore.mcpSecrets
        if let stored = try? keychain.secret(for: TinycastTools.serverID), !stored.isEmpty {
            return stored
        }
        return nil
    }

    func resetSharingPassword() {
        _ = generateSharingPassword()
        reconcileSharing()
    }

    @discardableResult
    private func generateSharingPassword() -> String? {
        let password = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32))
        guard (try? KeychainSecretStore.mcpSecrets.setSecret(password, for: TinycastTools.serverID))
            != nil
        else { return nil }
        return password
    }

    /// The Codex helper keeps what it was launched with, so a server taken away is taken from it.
    private func dropWithdrawnServers(besides withdrawn: UUID? = nil) {
        let offered = store.enabledServers.filter { $0.trust != .never && $0.id != withdrawn }
        core.chatGPTSubscription.dropWithdrawnServers(
            keeping: isActive ? Set(offered.map(\.slug)) : [])
    }

    /// Connecting on the way into chat, so the first send does not wait on every handshake.
    func warmUp() {
        guard isActive else { return }
        manager.reconcile(ownServers)
    }

    /// What Tinycast runs itself; Codex and Claude start their own copy of every local server.
    private var ownServers: [MCPServer] {
        let cliRoute = core.aiChatCoordinator.everyChatRunsItsOwnTools
        return store.enabledServers.filter { $0.runsInTinycast(whileCLIRouteSelected: cliRoute) }
    }

    var slugs: Set<String> {
        guard isActive else { return [] }
        var slugs = Set(store.enabledServers.map(\.slug))
        if settings.tinycastMCPEnabled { slugs.insert(TinycastTools.slug) }
        return slugs
    }

    /// What a chat's tools menu lists; empty while MCP is off.
    var servers: [MCPServer] {
        guard isActive else { return [] }
        return store.enabledServers + (settings.tinycastMCPEnabled ? [TinycastTools.server()] : [])
    }

    func server(slug: String) -> MCPServer? {
        guard isActive else { return nil }
        if settings.tinycastMCPEnabled, slug == TinycastTools.slug { return TinycastTools.server() }
        return store.enabledServers.first { $0.slug == slug }
    }

    /// What this turn may reach: everything enabled, or one server when `@slug` named it.
    func tools(scopedTo slug: String?) -> [AITool] {
        guard isActive else { return [] }
        var tools = manager.tools
            .filter { tool in
                guard slug == nil || tool.serverSlug == slug else { return false }
                return store.server(id: tool.serverID)?.trust != .never
            }
            .map(\.aiTool)
        if settings.tinycastMCPEnabled, slug == nil || slug == TinycastTools.slug {
            tools += TinycastTools.tools()
        }
        return tools
    }

    /// The same list for a CLI route; it starts its own copies, so Tinycast's need not be ready.
    /// Tinycast's own tools ride along once shared: spawned CLIs speak HTTP like anyone outside.
    func toolServers(scopedTo slug: String?) async -> [AIToolServer] {
        guard isActive else { return [] }
        let secrets = MCPSecretStore()
        var result: [AIToolServer] = []
        if settings.tinycastMCPEnabled, settings.tinycastMCPSharingEnabled,
            slug == nil || slug == TinycastTools.slug,
            let password = sharingPassword()
        {
            result.append(
                AIToolServer(
                    handle: TinycastTools.slug, title: TinycastTools.title,
                    transport: .url(
                        TinycastMCPWire.urlString, headerName: "Authorization",
                        headerValue: "Basic "
                            + TinycastMCPWire.basicAuthValue(
                                username: settings.tinycastMCPUsername, password: password))))
        }
        for server in store.enabledServers
        where server.trust != .never && (slug == nil || server.slug == slug) {
            let stored = secrets.secrets(for: server.id)
            var bearer: String?
            if server.oauth == true { bearer = try? await core.mcpOAuth.lentToken(for: server) }
            guard
                let toolServer = server.toolServer(
                    headerValue: stored.headerValue, environment: stored.environment,
                    bearerToken: bearer)
            else { continue }
            result.append(toolServer)
        }
        return result
    }

    /// Consent for a call a vendor CLI is making, through the same policy and the same dialog.
    /// Tinycast's own tools defer: the CLI's question is advisory, the execution-time dialog decides.
    func permit(_ call: AIToolServerCall, in chat: UUID) async -> Bool {
        if call.handle == TinycastTools.slug { return true }
        guard isActive, let server = server(slug: call.handle) else { return false }
        return await isPermitted(server, tool: call.tool, in: chat)
    }

    func invoke(_ call: AIToolCall, in chat: UUID) async -> AIToolResult {
        guard let route = MCPToolName.parse(call.name) else {
            return .failure(call.id, "That tool is no longer connected.")
        }
        if route.slug == TinycastTools.slug {
            return await invokeTinycast(tool: route.tool, call: call, in: chat)
        }
        guard let server = server(slug: route.slug),
            let connection = manager.connection(slug: route.slug)
        else {
            return .failure(call.id, "That tool is no longer connected.")
        }
        guard await isPermitted(server, tool: route.tool, in: chat) else {
            return .failure(call.id, "The user declined this tool call.")
        }
        manager.markUsed()
        do {
            let (content, isError) = try await connection.call(
                route.tool, arguments: JSONValue(data: Data(call.arguments.utf8)) ?? .object([:]))
            return AIToolResult(callID: call.id, content: content, isError: isError)
        } catch {
            return .failure(call.id, error.localizedDescription)
        }
    }

    func signIn(_ server: MCPServer, credentials: MCPOAuth.Credentials) async throws {
        guard isActive else { throw MCPOAuth.Failure.signInRequired }
        manager.disconnect(server.id)
        try await core.mcpOAuth.signIn(server: server, credentials: credentials)
    }

    func signOut(_ id: UUID) throws {
        manager.disconnect(id)
        try core.mcpOAuth.signOut(id)
        dropWithdrawnServers(besides: id)
    }

    func cancelSignIn(_ id: UUID) { core.mcpOAuth.cancelSignIn(id) }

    func status(of id: UUID) -> MCPServerStatus { manager.status(of: id) }

    func save(_ server: MCPServer, secrets: MCPSecretStore.Secrets) throws {
        try MCPSecretStore().save(secrets, for: server.id)
        core.mcpOAuth.cancelSignIn(server.id)
        manager.disconnect(server.id)
        store.save(server)
        applyEnabled()
    }

    func remove(_ id: UUID) throws {
        core.mcpOAuth.cancelSignIn(id)
        try MCPSecretStore().remove(for: id)
        store.remove(id: id)
        applyEnabled()
    }

    func discardUnsaved(_ id: UUID) {
        cancelSignIn(id)
        if store.server(id: id) == nil { try? MCPSecretStore().remove(for: id) }
    }

    func authenticationStatus(
        _ server: MCPServer, stored: MCPOAuth.Credentials?
    ) -> MCPOAuthManager.Status {
        core.mcpOAuth.status(for: server, stored: stored)
    }

    func test(_ server: MCPServer, secrets: MCPSecretStore.Secrets) async -> MCPServerStatus {
        if server.oauth == true {
            let stored = MCPSecretStore().secrets(for: server.id).oauth
            guard stored?.clientID == secrets.oauth?.clientID,
                stored?.clientSecret == secrets.oauth?.clientSecret
            else { return .signInRequired }
        }
        let connection = MCPServerConnection(server: server, secrets: secrets, oauth: core.mcpOAuth)
        defer { connection.stop() }
        await connection.start()
        return connection.status
    }

    /// Tinycast's own tools: fixed ask-per-chat consent, never a standing grant.
    private func invokeTinycast(tool: String, call: AIToolCall, in chat: UUID) async -> AIToolResult {
        guard settings.tinycastMCPEnabled else {
            return .failure(call.id, "Tinycast tools are off.")
        }
        guard await permitTinycast(tool: tool, in: chat) else {
            return .failure(call.id, "The user declined this tool call.")
        }
        guard let arguments = JSONValue(data: Data(call.arguments.utf8)) else {
            return .failure(call.id, "Pass arguments as JSON.")
        }
        let result = executeTinycast(tool: tool, arguments: arguments)
        return AIToolResult(callID: call.id, content: result.content, isError: result.isError)
    }

    /// Runs a consented call from either channel; failures are content, never thrown.
    private func executeTinycast(tool: String, arguments: JSONValue) -> (
        content: String, isError: Bool
    ) {
        let params = arguments.objectValue ?? [:]
        switch tool {
        case TinycastTools.searchTool:
            guard let query = params["query"]?.stringValue, !query.isEmpty else {
                return ("Pass a query to search.", true)
            }
            return (
                TinycastTools.search(query, in: core.appIndex, cache: &tinycastEntries), false)
        case TinycastTools.runTool:
            guard let id = params["id"]?.stringValue, !id.isEmpty else {
                return ("Pass an entry id from a search.", true)
            }
            return (
                TinycastTools.run(id: id, cache: tinycastEntries, launcher: core.launcherCoordinator),
                false)
        default:
            return ("Unknown tool.", true)
        }
    }

    private func permitTinycast(tool: String, in chat: UUID) async -> Bool {
        if chatGrants[chat]?.contains(TinycastTools.serverID) == true { return true }
        let index = await core.choose(
            title: "Let Tinycast run an action?",
            message: "The model wants to call \u{201C}\(tool)\u{201D}. "
                + "Tinycast runs this itself, on this Mac.",
            symbol: "wrench.and.screwdriver",
            options: [
                DialogAction(title: "Allow This Chat"),
                DialogAction(title: "Don't Allow", role: .cancel)
            ],
            defaultIndex: 1)
        guard index == 0 else { return false }
        chatGrants[chat, default: []].insert(TinycastTools.serverID)
        return true
    }

    private func handleTinycastCall(name: String, arguments: JSONValue) async -> (
        content: String, isError: Bool
    ) {
        guard settings.tinycastMCPEnabled else { return ("Tinycast tools are off.", true) }
        guard let tool = tinycastToolName(name) else { return ("Unknown tool.", true) }
        guard await askTinycast(tool: tool) else {
            return ("The user declined this tool call.", true)
        }
        return executeTinycast(tool: tool, arguments: arguments)
    }

    /// Wire names carry the slug outside; bare names stay callable for old hands.
    private func tinycastToolName(_ wireName: String) -> String? {
        let short =
            wireName.hasPrefix(TinycastTools.slug + MCPToolName.separator)
            ? String(wireName.dropFirst(TinycastTools.slug.count + MCPToolName.separator.count))
            : wireName
        return short == TinycastTools.searchTool || short == TinycastTools.runTool ? short : nil
    }

    /// Outside calls carry no chat, so every one asks; nothing is ever standing-granted here.
    private func askTinycast(tool: String) async -> Bool {
        await core.choose(
            title: "Let Tinycast run an action?",
            message: "An outside model wants to call \u{201C}\(tool)\u{201D}. "
                + "Tinycast runs this itself, on this Mac.",
            symbol: "wrench.and.screwdriver",
            options: [
                DialogAction(title: "Allow"),
                DialogAction(title: "Don't Allow", role: .cancel)
            ],
            defaultIndex: 1) == 0
    }

    private func isPermitted(_ server: MCPServer, tool: String, in chat: UUID) async -> Bool {
        switch MCPTrustPolicy.decide(
            trust: server.trust, isGrantedForChat: chatGrants[chat]?.contains(server.id) == true)
        {
        case .allow: return true
        case .refuse: return false
        case .ask: break
        }
        switch await ask(server, tool: tool) {
        case .always:
            store.setTrust(.always, for: server.id)
            return true
        case .thisChat:
            chatGrants[chat, default: []].insert(server.id)
            return true
        case .refuse:
            return false
        }
    }

    /// Escape refuses this one call: a dialog can grant a server, only Settings can withhold one.
    private func ask(_ server: MCPServer, tool: String) async -> MCPTrustChoice {
        let choices: [MCPTrustChoice] = [.always, .thisChat, .refuse]
        let index = await core.choose(
            title: "Let \(server.title) run its tools?",
            message: "The model wants to call \u{201C}\(tool)\u{201D}. Tinycast did not write this "
                + "server and cannot vouch for what it does.",
            symbol: "wrench.and.screwdriver",
            options: [
                DialogAction(title: "Always Allow"),
                DialogAction(title: "Allow This Chat"),
                DialogAction(title: "Don't Allow", role: .cancel)
            ],
            defaultIndex: 1)
        return choices.indices.contains(index) ? choices[index] : .refuse
    }
}
