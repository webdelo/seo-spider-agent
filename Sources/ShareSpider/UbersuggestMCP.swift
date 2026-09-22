import AppKit
import CryptoKit
import Foundation

/// OAuth connection to Ubersuggest's remote Streamable-HTTP MCP server. The
/// user authorizes it in their own browser; access and refresh tokens are kept
/// only in ShareSpider's local Application Support directory.
@MainActor
final class UbersuggestMCPAuth: ObservableObject {
    static let shared = UbersuggestMCPAuth()
    @Published private(set) var status = "Not connected"
    @Published private(set) var isAuthorizing = false

    private static let endpoint = URL(string: "https://ubersuggest-mcp.neilpatelapi.com/mcp")!
    private static let authorizationEndpoint = URL(string: "https://ubersuggest-mcp.neilpatelapi.com/authorize")!
    private static let tokenEndpoint = URL(string: "https://ubersuggest-mcp.neilpatelapi.com/token")!
    private static let registrationEndpoint = URL(string: "https://ubersuggest-mcp.neilpatelapi.com/register")!

    private init() { refreshStatus() }
    var isConnected: Bool { !credentials.refreshToken.isEmpty }

    func refreshStatus() { status = isConnected ? "Connected to Ubersuggest MCP" : "Not connected" }
    func disconnect() { save(.init()); refreshStatus() }

    func testConnection() async {
        guard isConnected else { status = "Connect Ubersuggest first."; return }
        do {
            let count = try await UbersuggestMCPClient.toolCount()
            status = "Connected · \(count) MCP tools available"
        } catch { status = "Connection failed: \(error.localizedDescription)" }
    }

    func accessToken() async throws -> String {
        let current = credentials
        guard !current.refreshToken.isEmpty, !current.clientID.isEmpty else { throw AuthError.notConnected }
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(["grant_type": "refresh_token", "refresh_token": current.refreshToken, "client_id": current.clientID])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw AuthError.request(readMessage(data, fallback: "Ubersuggest token refresh failed.")) }
        let token = try JSONDecoder().decode(Token.self, from: data)
        var updated = current; updated.accessToken = token.accessToken; updated.refreshToken = token.refreshToken ?? current.refreshToken
        save(updated)
        return token.accessToken
    }

    func authorize() async {
        guard !isAuthorizing else { return }
        isAuthorizing = true; defer { isAuthorizing = false }
        do {
            let server = try OAuthLoopbackServer()
            try await server.start()
            let redirectURI = "http://127.0.0.1:\(server.port)/oauth2callback"
            let registered = try await register(redirectURI: redirectURI)
            let verifier = Data((0..<64).map { _ in UInt8.random(in: 0...255) }).base64URLEncodedValue
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedValue
            var components = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                .init(name: "client_id", value: registered.clientID), .init(name: "redirect_uri", value: redirectURI),
                .init(name: "response_type", value: "code"), .init(name: "scope", value: "backlinks"),
                .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256")
            ]
            guard let url = components.url else { throw AuthError.request("Could not create Ubersuggest authorization URL.") }
            status = "Waiting for Ubersuggest authorization…"
            NSWorkspace.shared.open(url)
            let code = try await server.waitForCode()
            var request = URLRequest(url: Self.tokenEndpoint)
            request.httpMethod = "POST"; request.timeoutInterval = 20
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = form(["grant_type": "authorization_code", "code": code, "client_id": registered.clientID, "redirect_uri": redirectURI, "code_verifier": verifier])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw AuthError.request(readMessage(data, fallback: "Ubersuggest authorization failed.")) }
            let token = try JSONDecoder().decode(Token.self, from: data)
            guard let refresh = token.refreshToken, !refresh.isEmpty else { throw AuthError.request("Ubersuggest did not return a refresh token.") }
            save(.init(clientID: registered.clientID, refreshToken: refresh, accessToken: token.accessToken))
            status = "Connected to Ubersuggest MCP"
        } catch { status = "Authorization failed: \(error.localizedDescription)" }
    }

    private func register(redirectURI: String) async throws -> ClientRegistration {
        var request = URLRequest(url: Self.registrationEndpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_name": "ShareSpider", "redirect_uris": [redirectURI], "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"], "token_endpoint_auth_method": "none"])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw AuthError.request(readMessage(data, fallback: "Ubersuggest client registration failed.")) }
        return try JSONDecoder().decode(ClientRegistration.self, from: data)
    }

    private var credentials: Credentials { (try? JSONDecoder().decode(Credentials.self, from: Data(contentsOf: Self.file))) ?? .init() }
    private static var file: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ubersuggest-mcp-credentials.json")
    }
    private func save(_ value: Credentials) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: Self.file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }

    private struct Credentials: Codable { var clientID = ""; var refreshToken = ""; var accessToken = "" }
    private struct ClientRegistration: Decodable { let clientID: String; enum CodingKeys: String, CodingKey { case clientID = "client_id" } }
    private struct Token: Decodable { let accessToken: String; let refreshToken: String?; enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case refreshToken = "refresh_token" } }
    private enum AuthError: LocalizedError { case notConnected, request(String); var errorDescription: String? { switch self { case .notConnected: "Connect Ubersuggest MCP in Settings → Integrations first."; case .request(let value): value } } }
}

struct UbersuggestBacklinkImport: Codable, Hashable, Sendable {
    var target = ""
    var importedAt = Date()
    var domains: [String] = []
    var linkCount = 0
    var spamDomains: [String] = []
    var toolName = ""

    enum CodingKeys: String, CodingKey { case target, importedAt, domains, linkCount, spamDomains, toolName }
    init(target: String = "", importedAt: Date = Date(), domains: [String] = [], linkCount: Int = 0, spamDomains: [String] = [], toolName: String = "") {
        self.target = target; self.importedAt = importedAt; self.domains = domains; self.linkCount = linkCount; self.spamDomains = spamDomains; self.toolName = toolName
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        target = try values.decodeIfPresent(String.self, forKey: .target) ?? ""
        importedAt = try values.decodeIfPresent(Date.self, forKey: .importedAt) ?? Date()
        domains = try values.decodeIfPresent([String].self, forKey: .domains) ?? []
        linkCount = try values.decodeIfPresent(Int.self, forKey: .linkCount) ?? domains.count
        spamDomains = try values.decodeIfPresent([String].self, forKey: .spamDomains) ?? []
        toolName = try values.decodeIfPresent(String.self, forKey: .toolName) ?? ""
    }
}

enum UbersuggestBacklinkService {
    struct Progress: Sendable { var completed: Int; var total: Int; var message: String }
    static func load(target: String) -> UbersuggestBacklinkImport? {
        guard let data = try? Data(contentsOf: cacheURL(target: target)) else { return nil }
        return try? JSONDecoder().decode(UbersuggestBacklinkImport.self, from: data)
    }

    static func referringDomains(target rawTarget: String, progress: @escaping @Sendable (Progress) async -> Void = { _ in }) async throws -> UbersuggestBacklinkImport {
        let target = GSCBacklinkImportService.normalizedDomain(rawTarget)
        guard !target.isEmpty else { throw ServiceError.invalidTarget }
        let tools = try await UbersuggestMCPClient.tools()
        guard let tool = tools.sorted(by: { score($0) > score($1) }).first, score(tool) > 0 else { throw ServiceError.noBacklinkTool(tools.map(\.name)) }
        var baseArguments: [String: Any] = [:]
        let properties = (tool.inputSchema["properties"] as? [String: Any]) ?? [:]
        for name in properties.keys {
            let key = name.lowercased()
            if ["domain", "target", "website", "site", "url"].contains(key) { baseArguments[name] = target }
        }
        if baseArguments.isEmpty { baseArguments = ["domain": target] }
        // `backlinks` returns one row per distinct donor when one_per_domain
        // is set, which is exactly the referring-domain profile we want.
        if let onePerDomainKey = properties.keys.first(where: { $0.lowercased() == "one_per_domain" || $0.lowercased() == "oneperdomain" }) {
            baseArguments[onePerDomainKey] = true
        }
        // Recent MCP schemas expose the same scope through enum-based fields.
        // Supply them only when the advertised schema confirms the value, so
        // an older server never receives invented/unsupported arguments.
        func enumValue(named name: String, matching wanted: Set<String>) -> String? {
            guard let key = properties.keys.first(where: { $0.lowercased() == name }),
                  let schema = properties[key] as? [String: Any] else { return nil }
            let values = (schema["enum"] as? [String]) ?? ((schema["items"] as? [String: Any])?["enum"] as? [String]) ?? []
            return values.first { wanted.contains($0.lowercased()) }
        }
        if let key = properties.keys.first(where: { $0.lowercased() == "mode" }),
           let value = enumValue(named: "mode", matching: ["domain", "root_domain", "domain_with_subdomains"]) {
            baseArguments[key] = value
        }
        if let key = properties.keys.first(where: { $0.lowercased() == "filter_by" || $0.lowercased() == "filterby" }),
           let value = enumValue(named: key.lowercased(), matching: ["one_per_domain", "oneperdomain"]) {
            baseArguments[key] = value
        }

        let limitKey = properties.keys.first { ["limit", "per_page", "rows", "size", "count"].contains($0.lowercased()) } ?? "limit"
        let offsetKey = properties.keys.first { ["offset", "start", "skip", "page_offset"].contains($0.lowercased()) } ?? "offset"
        let pageSize = 100
        var offset = 0
        var domains = Set<String>()
        var spamDomains = Set<String>()
        var linkCount = 0
        while true {
            try Task.checkCancellation()
            var arguments = baseArguments
            arguments[limitKey] = pageSize
            arguments[offsetKey] = offset
            // Ubersuggest MCP answers with asynchronous reports: the first
            // `tools/call` returns `done:false` and an empty list while the
            // backend builds the report; a later call returns the data. Poll
            // until done.  The report is created asynchronously and the first
            // answer is normally {"done":false,"backlinks":[]}; it is not an
            // empty backlink profile.  Keep the arguments identical for every
            // poll so the service can retrieve the same pending report.
            var page = (domains: Set<String>(), spamDomains: Set<String>(), linkCount: 0, done: false)
            var polls = 0
            let maximumPolls = 90 // three minutes, with a responsive two-second cadence
            while !page.done && polls < maximumPolls {
                let response = try await UbersuggestMCPClient.call(tool: tool.name, arguments: arguments)
                page = extractPage(response, ownDomain: target)
                if !page.done {
                    polls += 1
                    await progress(.init(completed: domains.count, total: max(domains.count, offset + pageSize), message: "Waiting for the Ubersuggest backlink report to build (\(polls)/\(maximumPolls))…"))
                    if polls < maximumPolls { try await Task.sleep(for: .seconds(2)) }
                }
            }
            // Do not mistake a still-pending report for an empty final page.
            guard page.done else { throw ServiceError.reportTimedOut(tool.name) }
            guard !page.domains.isEmpty else { break }
            let before = domains.count
            domains.formUnion(page.domains)
            spamDomains.formUnion(page.spamDomains)
            linkCount += page.linkCount
            await progress(.init(completed: domains.count, total: max(domains.count, offset + page.domains.count), message: "Loaded \(domains.count) donor domains; requesting the next Ubersuggest page…"))
            // Do not require a full page: a provider may cap each response
            // well below the requested page size. Continue by offset until no
            // new donor domains arrive (a repeated page is a valid end).
            guard domains.count > before else { break }
            offset += page.domains.count
        }
        let orderedDomains = domains.sorted()
        guard !orderedDomains.isEmpty else { throw ServiceError.noDomains(tool.name) }
        await progress(.init(completed: orderedDomains.count, total: orderedDomains.count, message: "All available Ubersuggest donor domains loaded."))
        let result = UbersuggestBacklinkImport(target: target, importedAt: Date(), domains: orderedDomains, linkCount: max(linkCount, orderedDomains.count), spamDomains: spamDomains.sorted(), toolName: tool.name)
        if let data = try? JSONEncoder().encode(result) { try? data.write(to: cacheURL(target: target), options: .atomic) }
        return result
    }

    private static func score(_ tool: UbersuggestMCPClient.Tool) -> Int {
        let name = tool.name.lowercased()
        // The backlinks tool returns individual link rows (with one_per_domain
        // for a donor list) — the direct source of a referring-domain profile.
        if name == "backlinks" { return 100 }
        // linking_domains only reports recently gained/lost donors, and is
        // asynchronous; it is a fallback, not the primary source.
        if name == "linking_domains" { return 80 }
        let text = "\(name) \(tool.description)".lowercased()
        var value = 0
        if text.contains("backlink") { value += 3 }
        if text.contains("referring") { value += 4 }
        if text.contains("domain") { value += 2 }
        if text.contains("link") { value += 1 }
        return value
    }
    private static func extractPage(_ value: Any, ownDomain: String) -> (domains: Set<String>, spamDomains: Set<String>, linkCount: Int, done: Bool) {
        var domains = Set<String>()
        var spamDomains = Set<String>()
        var linkCount = 0
        var done = true
        func number(_ value: Any?) -> Int? {
            if let value = value as? Int { return value }
            if let value = value as? NSNumber { return value.intValue }
            if let value = value as? String { return Int(value) }
            return nil
        }
        // Some reports explicitly flag completeness with a "done" boolean.
        func bool(_ value: Any) -> Bool? {
            if let value = value as? Bool { return value }
            if let value = value as? NSNumber { return value.boolValue }
            if let value = value as? String {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "1", "yes": return true
                case "false", "0", "no": return false
                default: return nil
                }
            }
            return nil
        }
        func isSpam(_ object: [String: Any]) -> Bool {
            let marker = object.first { $0.key.lowercased().contains("spam") }?.value
            if let value = marker as? Bool { return value }
            if let value = marker as? NSNumber { return value.boolValue || value.intValue >= 50 }
            if let value = marker as? String { return value.lowercased() == "true" || (Int(value) ?? 0) >= 50 }
            return false
        }
        func domainFromURL(_ raw: String) -> String {
            guard let url = URL(string: raw) else { return GSCBacklinkImportService.normalizedDomain(raw) }
            return GSCBacklinkImportService.normalizedDomain(url.host ?? "")
        }
        func collect(_ current: Any, key: String = "") {
            if let object = current as? [String: Any] {
                // Completion is a sibling of the result rows.  The former
                // code tried to read it while visiting the scalar `done`
                // value, so {"done":false} was silently treated as complete.
                if let value = object["done"], let value = bool(value) { done = value }
                if let value = object["pendingData"], let value = bool(value) { done = !value }
                let candidate = object.first { name, _ in
                    let k = name.lowercased()
                    return k == "domain" || k == "source_domain" || k == "linking_domain" || k == "referring_domain" || k == "site" || k == "url_from" || k == "source"
                }?.value as? String
                // Prefer url_from host, falling back to a literal domain field.
                if let rawURL = object["url_from"] as? String {
                    let d = domainFromURL(rawURL)
                    if d.contains("."), d != ownDomain {
                        domains.insert(d)
                        if isSpam(object) { spamDomains.insert(d) }
                        linkCount += number(object["backlinks"]) ?? number(object["links"]) ?? number(object["link_count"]) ?? 1
                    }
                } else if let candidate {
                    let domain = GSCBacklinkImportService.normalizedDomain(candidate)
                    if domain.contains("."), domain != ownDomain {
                        domains.insert(domain)
                        if isSpam(object) { spamDomains.insert(domain) }
                        linkCount += number(object["backlinks"]) ?? number(object["links"]) ?? number(object["link_count"]) ?? 1
                    }
                }
                for (name, item) in object { collect(item, key: name.lowercased()) }
            } else if let array = current as? [Any] { for item in array { collect(item, key: key) } }
            else if (key == "done" || key == "pendingdata"), let value = bool(current) {
                done = key == "pendingdata" ? !value : value
            }
            else if let text = current as? String, key.contains("domain") || key.contains("site") || key.contains("source") || key == "url_from" {
                let domain = domainFromURL(text)
                if domain.contains("."), domain != ownDomain { domains.insert(domain) }
            }
        }
        collect(value)
        return (domains, spamDomains, linkCount, done)
    }
    private static var directory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ShareSpider/ubersuggest-backlinks", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private static func cacheURL(target: String) -> URL { directory.appendingPathComponent("\(GSCBacklinkImportService.normalizedDomain(target).replacingOccurrences(of: "[^a-z0-9.-]", with: "_", options: .regularExpression)).json") }
    enum ServiceError: LocalizedError {
        case invalidTarget, noBacklinkTool([String]), noDomains(String), reportTimedOut(String)
        var errorDescription: String? { switch self { case .invalidTarget: "The project domain is invalid."; case .noBacklinkTool(let names): "Ubersuggest MCP did not expose a backlink/referring-domain tool. Available tools: \(names.joined(separator: ", "))."; case .noDomains(let tool): "Ubersuggest tool \(tool) returned no donor domains."; case .reportTimedOut(let tool): "Ubersuggest tool \(tool) did not finish its backlink report within three minutes." } }
    }
}

enum UbersuggestMCPClient {
    struct Tool { let name: String; let description: String; let inputSchema: [String: Any] }
    private static let endpoint = URL(string: "https://ubersuggest-mcp.neilpatelapi.com/mcp")!

    static func tools() async throws -> [Tool] {
        let session = try await initialize()
        let result = try await request(method: "tools/list", params: [:], session: session)
        let values = (result["tools"] as? [[String: Any]]) ?? []
        return values.compactMap { value in
            guard let name = value["name"] as? String else { return nil }
            return Tool(name: name, description: value["description"] as? String ?? "", inputSchema: value["inputSchema"] as? [String: Any] ?? [:])
        }
    }
    static func toolCount() async throws -> Int { try await tools().count }
    static func call(tool: String, arguments: [String: Any]) async throws -> Any {
        let session = try await initialize()
        let result = try await request(method: "tools/call", params: ["name": tool, "arguments": arguments], session: session)
        let content = (result["content"] as? [[String: Any]]) ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        if let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) { return value }
        if let sc = result["structuredContent"] as? [String: Any] { return sc }
        return result
    }

    private static func initialize() async throws -> String {
        let token = try await UbersuggestMCPAuth.shared.accessToken()
        let (result, session) = try await request(method: "initialize", params: ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "ShareSpider", "version": "1.0"]], accessToken: token, session: nil)
        _ = result
        _ = try? await request(method: "notifications/initialized", params: [:], accessToken: token, session: session)
        return session
    }
    private static func request(method: String, params: [String: Any], session: String) async throws -> [String: Any] {
        let token = try await UbersuggestMCPAuth.shared.accessToken()
        return try await request(method: method, params: params, accessToken: token, session: session).0
    }
    private static func request(method: String, params: [String: Any], accessToken: String, session: String?) async throws -> ([String: Any], String) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2025-03-26", forHTTPHeaderField: "MCP-Protocol-Version")
        if let session, !session.isEmpty { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        // Ubersuggest's Streamable-HTTP server is strict: it rejects bodies it
        // cannot parse with HTTP 400 "Parse error". A stable, small, unique id
        // avoids any Int64→JSON serialization surprise from Int.random and is
        // enough for our request/response correlation.
        let requestID = Int.random(in: 1...10_000)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": requestID, "method": method, "params": params])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let responseText = String(data: data, encoding: .utf8) ?? ""
        logDiagnostic(method: method, status: status, bodyPrefix: String(responseText.prefix(800)), sentSession: session ?? "")
        guard (200..<300).contains(status) else { throw MCPError.request(readMessage(data, fallback: "Ubersuggest MCP HTTP \(status)")) }
        let body = parseMCPBody(data)
        if let error = body["error"] as? [String: Any] { throw MCPError.request((error["message"] as? String) ?? "Ubersuggest MCP returned an error.") }
        let result = (body["result"] as? [String: Any]) ?? [:]
        // Ubersuggest uses the stateless Streamable-HTTP/SSE variant of MCP:
        // it legitimately omits Mcp-Session-Id. Keep the value when a server
        // provides one, but do not reject a valid stateless response.
        let sessionID = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id")) ?? session ?? ""
        return (result, sessionID)
    }
    /// Writes a short line about each MCP HTTP round trip to a local debug
    /// file so a failed export can be explained without exposing the token.
    /// The file lives next to the cache so it is easy to inspect on a problem.
    private static func logDiagnostic(method: String, status: Int, bodyPrefix: String, sentSession: String) {
        let line = "\(Date().formatted(date: .abbreviated, time: .standard)) \(method) -> HTTP \(status) session=\(sentSession.isEmpty ? "none" : "yes") body=\(bodyPrefix)"
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ubersuggest-mcp-debug.log")
        if let data = line.data(using: .utf8) {
            try? data.write(to: file, options: .atomic)
        }
    }
    private static func parseMCPBody(_ data: Data) -> [String: Any] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        let text = String(data: data, encoding: .utf8) ?? ""
        let last = text.split(separator: "\n").last(where: { $0.hasPrefix("data:") }).map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) } ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any]) ?? [:]
    }
    enum MCPError: LocalizedError { case request(String); var errorDescription: String? { switch self { case .request(let value): value } } }
}

private func form(_ values: [String: String]) -> Data { values.map { "\($0.key.urlEscaped)=\($0.value.urlEscaped)" }.joined(separator: "&").data(using: .utf8) ?? Data() }
private func readMessage(_ data: Data, fallback: String) -> String { guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return fallback }; return (object["error_description"] as? String) ?? (object["message"] as? String) ?? (object["error"] as? String) ?? fallback }
private extension String { var urlEscaped: String { addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self } }
private extension Data { var base64URLEncodedValue: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") } }
