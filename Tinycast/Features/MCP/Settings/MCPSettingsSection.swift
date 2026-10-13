import SwiftUI

/// Settings → AI's MCP half: the switch, the servers, and what each one is doing right now.
struct MCPSettingsSection: View {
    @Environment(MCPCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings
    @Environment(MCPSettingsStore.self) private var store
    @State private var editor: MCPServerEditorTarget?
    @State private var pendingRemoval: MCPServer?
    @State private var removalError: String?

    var body: some View {
        @Bindable var appSettings = appSettings
        Section {
            Toggle(isOn: $appSettings.mcpEnabled) {
                SettingsRowTitle(.aiMCPServers, "Enable MCP servers")
            }
            Group {
                Toggle(isOn: $appSettings.tinycastMCPEnabled) {
                    SettingsRowTitle(.aiMCPServers, "Tinycast actions")
                    Text("Let the model open apps, files and windows through Tinycast itself.")
                }
                if appSettings.tinycastMCPEnabled {
                    Toggle(isOn: $appSettings.tinycastMCPSharingEnabled) {
                        SettingsRowTitle(.aiMCPServers, "Share with other AI")
                        Text("Serve the tools on this Mac over localhost HTTP.")
                    }
                    if appSettings.tinycastMCPSharingEnabled {
                        TinycastSharingRows()
                    }
                }
                if store.servers.isEmpty {
                    Text("No MCP servers yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.servers) { server in
                        MCPServerRow(
                            server: server, status: coordinator.status(of: server.id),
                            onEdit: { editor = MCPServerEditorTarget(server: server, isNew: false) },
                            onRemove: { pendingRemoval = server })
                    }
                }
                Button {
                    editor = MCPServerEditorTarget(server: MCPServer(), isNew: true)
                } label: {
                    Label {
                        SettingsRowTitle(.aiMCPServers, "Add MCP Server")
                    } icon: {
                        Image(systemName: "plus")
                            .foregroundStyle(.primary)
                    }
                }
            }
            .settingsEnabled(appSettings.mcpEnabled)
            if let removalError {
                Label(removalError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            SettingsSectionHeader(.aiMCPServers)
        } footer: {
            Text("Type @slug to address one server. A chat asks before its first tool call.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .settingsEditorPanel(item: $editor) { target in
            MCPServerEditor(target: target, onSave: save, onCancel: { editor = nil })
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.title ?? "this server")?", isPresented: removalBinding,
            presenting: pendingRemoval
        ) { server in
            Button("Remove", role: .destructive) { remove(server) }
        } message: { _ in
            Text("Its tools stop being offered, and its stored credentials are deleted.")
        }
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    /// A returned message is shown in the panel; nil closes it.
    private func save(_ server: MCPServer, _ secrets: MCPSecretStore.Secrets) -> String? {
        do {
            try coordinator.save(server, secrets: secrets)
        } catch {
            return "The credentials could not be saved to your login Keychain."
        }
        editor = nil
        return nil
    }

    private func remove(_ server: MCPServer) {
        pendingRemoval = nil
        do {
            try coordinator.remove(server.id)
            removalError = nil
        } catch {
            removalError =
                "\(server.title) was kept: its credentials could not be removed from your login Keychain."
        }
    }
}

/// Username, password, status and snippet for sharing Tinycast's tools on this Mac.
private struct TinycastSharingRows: View {
    @Environment(MCPCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        LabeledContent("Username") {
            TextField("tinycast", text: $settings.tinycastMCPUsername)
                .multilineTextAlignment(.trailing)
        }
        LabeledContent("Password") {
            HStack {
                Text(coordinator.sharingPassword() ?? "\u{2026}")
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Copy") {
                    if let password = coordinator.sharingPassword() {
                        Paster.copyPlainText(password)
                    }
                }
                Button("Reset") { coordinator.resetSharingPassword() }
            }
        }
        LabeledContent("Status") { status }
        LabeledContent("Connect") {
            Button("Copy snippet") {
                if let snippet = coordinator.tinycastConnectionSnippet() {
                    Paster.copyPlainText(snippet)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch coordinator.tinycastSharingState {
        case .stopped:
            Text("Stopped").foregroundStyle(.secondary)
        case .running:
            Text("127.0.0.1:\(TinycastMCPWire.port)").foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.orange)
        }
    }
}

private struct MCPServerRow: View {
    let server: MCPServer
    let status: MCPServerStatus
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        SettingsRow(title: server.title, subtitle: subtitle) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(.primary)
        } trailing: {
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.plain)
                .help("Edit \(server.title)")
                .accessibilityLabel("Edit \(server.title)")
            Button(action: onRemove) {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Remove \(server.title)")
            .accessibilityLabel("Remove \(server.title)")
        }
    }

    /// The slug leads, because it is the half a reader has to type into the composer.
    private var subtitle: String {
        let state = server.isEnabled ? status.label : "Disabled"
        return "@\(server.slug) · \(state) · \(server.transport.summary)"
    }
}
