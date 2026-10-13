import Foundation

/// Tinycast's own MCP over localhost HTTP: pure JSON-RPC and framing, no sockets, no secrets.
/// Sockets, consent and execution live in `TinycastMCPServer`, which calls back into this.
enum TinycastMCPWire {
    static let port = 4932
    static let path = "/mcp"
    static var urlString: String { "http://127.0.0.1:\(port)\(path)" }

    /// The base64 half of a Basic value for this username and password.
    static func basicAuthValue(username: String, password: String) -> String {
        Data("\(username):\(password)".utf8).base64EncodedString()
    }

    /// The `Authorization` value Codex sends: the password as a bearer token.
    static func bearerAuthValue(password: String) -> String {
        "Bearer \(password)"
    }

    static func authorized(headers: [String: String], username: String, password: String) -> Bool {
        guard !password.isEmpty else { return false }
        let lowered = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        guard let value = lowered["authorization"] else { return false }
        if value.hasPrefix("Bearer ") { return String(value.dropFirst(7)) == password }
        guard value.hasPrefix("Basic ") else { return false }
        return String(value.dropFirst(6)) == basicAuthValue(username: username, password: password)
    }

    struct Call: Equatable {
        let id: JSONValue?
        let method: String
        let params: JSONValue
    }

    /// The one JSON-RPC envelope this server answers; anything else is a 400 or 404 upstream.
    static func parse(_ data: Data) -> Call? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = object["method"] as? String
        else { return nil }
        let id = object["id"].map(JSONValue.init)
        return Call(id: id, method: method, params: JSONValue(object["params"] ?? [:]))
    }

    static func response(id: JSONValue?, result: JSONValue) -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "result": result.jsonObject]
        if let id { object["id"] = id.jsonObject }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func failure(id: JSONValue?, code: Int, message: String) -> Data {
        var object: [String: Any] = [
            "jsonrpc": "2.0", "error": ["code": code, "message": message]
        ]
        if let id { object["id"] = id.jsonObject }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func initializeResult(version: String) -> JSONValue {
        .object([
            "protocolVersion": .string(MCPProtocol.version),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object(["name": .string("tinycast"), "version": .string(version)])
        ])
    }

    static func toolsList(_ tools: [AITool]) -> JSONValue {
        .object([
            "tools": .array(
                tools.map { tool in
                    .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "inputSchema": tool.parameters
                    ])
                })
        ])
    }

    static func callResult(content: String, isError: Bool) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(content)])]),
            "isError": .bool(isError)
        ])
    }

    static func http(status: Int, contentType: String?, body: Data, extraHeaders: [String] = []) -> Data {
        var head = "HTTP/1.1 \(status) \(reason(for: status))\r\nConnection: close\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        for header in extraHeaders { head += "\(header)\r\n" }
        head += "Content-Length: \(body.count)\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func unauthorized() -> Data {
        http(
            status: 401, contentType: "application/json",
            body: failure(id: nil, code: -32_600, message: "Unknown or missing credentials."),
            extraHeaders: ["WWW-Authenticate: Basic realm=\"Tinycast\""])
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Content Too Large"
        case 500: "Internal Error"
        case 503: "Unavailable"
        default: "Error"
        }
    }
}
