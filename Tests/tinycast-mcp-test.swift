import Foundation

@main
struct TinycastMCPTest {
    static func main() {
        testAuth()
        testEnvelopes()
        testToolsList()
        testHTTP()
        print("Tinycast MCP wire passed")
    }

    private static func testAuth() {
        let headers = ["Authorization": "Basic " + TinycastMCPWire.basicAuthValue(username: "t", password: "s3cret")]
        guard TinycastMCPWire.authorized(headers: headers, username: "t", password: "s3cret") else {
            fatalError("Valid credentials refused")
        }
        guard !TinycastMCPWire.authorized(headers: headers, username: "t", password: "wrong") else {
            fatalError("Wrong password accepted")
        }
        guard !TinycastMCPWire.authorized(headers: ["Authorization": "Bearer s3cret"], username: "t", password: "s3cret") else {
            fatalError("Bearer accepted where only Basic lives")
        }
        guard !TinycastMCPWire.authorized(headers: [:], username: "t", password: "s3cret") else {
            fatalError("Missing credentials accepted")
        }
        guard !TinycastMCPWire.authorized(headers: headers, username: "t", password: "") else {
            fatalError("Empty password accepted")
        }
        guard TinycastMCPWire.authorized(
            headers: ["aUtHoRiZaTiOn": "Basic " + TinycastMCPWire.basicAuthValue(username: "t", password: "s3cret")],
            username: "t", password: "s3cret")
        else {
            fatalError("Header names are case-insensitive")
        }
    }

    private static func testEnvelopes() {
        guard let call = TinycastMCPWire.parse(Data("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}".utf8)),
            call.method == "tools/list", call.id == JSONValue.number(7)
        else {
            fatalError("Request lost its id or method")
        }
        guard let note = TinycastMCPWire.parse(Data("{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"params\":{\"a\":1}}".utf8)),
            note.id == nil, note.params.objectValue?["a"]?.intValue == 1
        else {
            fatalError("Notification lost its params")
        }
        guard TinycastMCPWire.parse(Data("nope".utf8)) == nil else {
            fatalError("Garbage parsed as a call")
        }
        let body = TinycastMCPWire.response(id: .number(7), result: .object(["ok": .bool(true)]))
        guard
            let envelope = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            (envelope["id"] as? NSNumber)?.intValue == 7,
            envelope["result"] != nil
        else {
            fatalError("Response forgot its envelope")
        }
        let failed = TinycastMCPWire.failure(id: .number(7), code: -32_601, message: "Nope.")
        guard String(bytes: failed, encoding: .utf8)?.contains("-32601") == true else {
            fatalError("Failure lost its code")
        }
    }

    private static func testToolsList() {
        let tools = [
            AITool(
                name: "tinycast__launcher_search", description: "Search.",
                parameters: .object(["type": .string("object")]), origin: "Tinycast",
                title: "Search launcher")
        ]
        let list = TinycastMCPWire.toolsList(tools)
        guard let entries = list.objectValue?["tools"]?.arrayValue,
            entries.count == 1,
            entries[0].objectValue?["name"]?.stringValue == "tinycast__launcher_search",
            entries[0].objectValue?["inputSchema"]?.objectValue?["type"]?.stringValue == "object"
        else {
            fatalError("Tool list lost a name or schema")
        }
        let result = TinycastMCPWire.callResult(content: "Hi.", isError: false)
        guard result.objectValue?["content"]?.arrayValue?.count == 1,
            result.objectValue?["isError"]?.boolValue == false
        else {
            fatalError("Call result broke its blocks")
        }
        let initialize = TinycastMCPWire.initializeResult(version: "9")
        guard initialize.objectValue?["serverInfo"]?.objectValue?["version"]?.stringValue == "9",
            initialize.objectValue?["protocolVersion"]?.stringValue == MCPProtocol.version
        else {
            fatalError("Handshake lost its version")
        }
    }

    private static func testHTTP() {
        let reply = TinycastMCPWire.http(status: 200, contentType: "application/json", body: Data("{}".utf8))
        guard let head = String(bytes: reply, encoding: .utf8),
            head.hasPrefix("HTTP/1.1 200 OK\r\n"),
            head.contains("Content-Length: 2\r\n\r\n{}")
        else {
            fatalError("Framing lost status or length")
        }
        guard String(bytes: TinycastMCPWire.unauthorized(), encoding: .utf8)?
            .contains("WWW-Authenticate: Basic") == true
        else {
            fatalError("Challenge lost its scheme")
        }
    }
}
