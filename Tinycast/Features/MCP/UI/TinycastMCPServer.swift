import Foundation
import Network

/// Serves Tinycast's own tools over localhost HTTP, as Streamable HTTP with plain JSON answers:
/// the same tools the in-process loop calls, for CLI routes and outside clients that run their
/// own MCP client. Localhost only; every call asks on this Mac, nothing is ever standing-granted.
@MainActor
final class TinycastMCPServer {
    enum State: Equatable {
        case stopped
        case running
        case failed(String)
    }

    /// What the clients may call; refreshed while starting, read per call.
    var tools: [AITool] = []
    var credentials: (username: String, password: String) = ("", "")
    var version: String = "1"
    /// A tool name with its arguments; failures are content, so this never throws.
    var onCall: ((String, JSONValue) async -> (content: String, isError: Bool))?
    private(set) var state = State.stopped
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
            self?.task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if state != .stopped { state = .stopped }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        task?.cancel()
        task = nil
    }

    private func run() async {
        do {
            // Mirrors TinycastMCPWire.port: only a literal converts to NWEndpoint.Port.
            let port: NWEndpoint.Port = 4932
            let listener = try NetworkListener(
                using: .parameters { TCP() }
                    .localEndpoint(.hostPort(host: .ipv4(.loopback), port: port)))
            try await listener.onStateUpdate { [weak self] _, status in
                switch status {
                case .ready:
                    self?.state = .running
                case .waiting, .failed:
                    self?.fail("The port is occupied or unavailable.")
                default: break
                }
            }.run { [weak self] connection in
                await self?.serve(connection)
            }
        } catch is CancellationError {
            state = .stopped
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func serve(_ connection: NetworkConnection<TCP>) async {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in try await self?.answer(connection) }
                group.addTask { try await Task.sleep(for: .seconds(70)) }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch { return }
    }

    private func answer(_ connection: NetworkConnection<TCP>) async throws {
        var bytes = Data()
        while bytes.count < 16_384 {
            let message = try await connection.receive(atLeast: 1, atMost: 16_384 - bytes.count)
            bytes.append(message.content)
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            if message.metadata.endOfStream { break }
        }
        guard let headerEnd = bytes.range(of: Data("\r\n\r\n".utf8)),
            let head = String(bytes: bytes[..<headerEnd.lowerBound], encoding: .utf8)
        else { return }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count == 3 else { return }
        let method = String(parts[0])
        let target = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] =
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        var body = bytes[headerEnd.upperBound...]
        if method == "POST", target == TinycastMCPWire.path {
            let length = Int(headers["content-length"] ?? "") ?? 0
            guard length <= 262_144 else {
                let reply = TinycastMCPWire.http(
                    status: 413, contentType: "application/json",
                    body: TinycastMCPWire.failure(id: nil, code: -32_600, message: "Too large."))
                try await connection.send(reply, endOfStream: true)
                return
            }
            while body.count < length {
                let message = try await connection.receive(atLeast: 1, atMost: length - body.count)
                body.append(message.content)
                if message.metadata.endOfStream { break }
            }
            guard body.count >= length else { return }
        }
        let reply = await self.reply(
            method: method, target: target, headers: headers, body: Data(body))
        try await connection.send(reply, endOfStream: true)
    }

    private func reply(
        method: String, target: String, headers: [String: String], body: Data
    ) async -> Data {
        guard target == TinycastMCPWire.path else {
            return TinycastMCPWire.http(
                status: 404, contentType: "application/json",
                body: TinycastMCPWire.failure(id: nil, code: -32_600, message: "Unknown path."))
        }
        guard method == "POST" else {
            return TinycastMCPWire.http(
                status: 405, contentType: "application/json",
                body: TinycastMCPWire.failure(id: nil, code: -32_600, message: "POST only."))
        }
        let credentials = self.credentials
        guard
            TinycastMCPWire.authorized(
                headers: headers, username: credentials.username, password: credentials.password)
        else {
            return TinycastMCPWire.unauthorized()
        }
        guard let call = TinycastMCPWire.parse(body) else {
            return TinycastMCPWire.http(
                status: 400, contentType: "application/json",
                body: TinycastMCPWire.failure(id: nil, code: -32_700, message: "Unreadable request."))
        }
        switch call.method {
        case "initialize":
            return ok(call.id, TinycastMCPWire.initializeResult(version: version))
        case "notifications/initialized":
            return TinycastMCPWire.http(status: 202, contentType: nil, body: Data())
        case "ping":
            return ok(call.id, .object([:]))
        case "tools/list":
            return ok(call.id, TinycastMCPWire.toolsList(tools))
        case "tools/call":
            let params = call.params.objectValue ?? [:]
            guard let name = params["name"]?.stringValue else {
                return ok(call.id, TinycastMCPWire.callResult(content: "Pass a tool name.", isError: true))
            }
            let arguments = params["arguments"] ?? .object([:])
            let result = await onCall?(name, arguments)
                ?? (content: "Unavailable.", isError: true)
            return ok(call.id, TinycastMCPWire.callResult(content: result.content, isError: result.isError))
        default:
            return TinycastMCPWire.http(
                status: 200, contentType: "application/json",
                body: TinycastMCPWire.failure(id: call.id, code: -32_601, message: "Unknown method."))
        }
    }

    private func ok(_ id: JSONValue?, _ result: JSONValue) -> Data {
        TinycastMCPWire.http(
            status: 200, contentType: "application/json",
            body: TinycastMCPWire.response(id: id, result: result))
    }
}
