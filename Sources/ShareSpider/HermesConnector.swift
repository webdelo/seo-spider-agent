import Foundation

/// Local connection preferences for the independently running Hermes desktop
/// agent.  ShareSpider never starts Hermes per audit; it joins its gateway when
/// it is already available.
struct HermesSettings: Codable, Sendable {
    /// Hermes' documented local Agent API default. The Desktop dashboard can
    /// run on a different ephemeral port; it is not itself the agent API.
    var endpoint = "http://127.0.0.1:8642"
    /// API_SERVER_KEY for the local Hermes Agent API.
    var apiKey = ""

    private enum CodingKeys: String, CodingKey { case endpoint, apiKey }
    init(endpoint: String = "http://127.0.0.1:8642", apiKey: String = "") {
        self.endpoint = endpoint
        self.apiKey = apiKey
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try values.decodeIfPresent(String.self, forKey: .endpoint) ?? "http://127.0.0.1:8642"
        apiKey = try values.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    }

    private static var file: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("hermes-settings.json")
    }

    static func load() -> HermesSettings {
        guard let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(HermesSettings.self, from: data) else { return .init() }
        return value
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }
}

struct HermesConnectionStatus: Sendable, Equatable {
    var connected: Bool
    var message: String
    static let notChecked = HermesConnectionStatus(connected: false, message: "Not checked")
}

/// Compact, serialisable project view used by the read-only ShareSpider MCP
/// server.  It deliberately avoids raw page bodies and credentials.
private struct HermesProjectSnapshot: Codable, Sendable {
    struct URLRow: Codable, Sendable {
        var url: String
        var status: Int?
        var title: String
        var pageType: String
        var indexability: String
        var canonical: String
        var schemaTypes: [String]
        var pageWeight: Int
        var aiParsability: String
        var htmlSize: Int
        var transport: String
    }

    var generatedAt: Date
    var context: AuditContext
    var urls: [URLRow]

    static var directory: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    static var file: URL { directory.appendingPathComponent("hermes-project-context.json") }
    static var serverFile: URL { directory.appendingPathComponent("sharespider-mcp.py") }

    static func write(context: AuditContext, records: [CrawlRecord]) throws -> URL {
        let rows = records.map {
            URLRow(url: $0.url.absoluteString, status: $0.statusCode, title: $0.title, pageType: $0.displayPageType,
                   indexability: $0.indexability, canonical: $0.canonical, schemaTypes: $0.schemaTypes,
                   pageWeight: $0.pageWeight, aiParsability: $0.aiParsability, htmlSize: $0.htmlSize,
                   transport: $0.transportUsed)
        }
        let snapshot = HermesProjectSnapshot(generatedAt: Date(), context: context, urls: rows)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    /// A dependency-free MCP stdio server. Hermes starts this once and keeps it
    /// alive for its current session; every tool reads the latest snapshot that
    /// ShareSpider wrote for the active project.
    static func installMCPServer() throws -> URL {
        let script = #"""
#!/usr/bin/env python3
import json, os, sys

SNAPSHOT = os.environ.get("SHARESPIDER_HERMES_SNAPSHOT", "__SNAPSHOT__")
TOOLS = [
 {"name":"get_overview","description":"Get crawl overview and page-type summary.","inputSchema":{"type":"object","properties":{}}},
 {"name":"get_issues","description":"Get current issues with priority and counts.","inputSchema":{"type":"object","properties":{}}},
 {"name":"get_urls","description":"Get matching project URLs. Supports query, status, pageType and limit.","inputSchema":{"type":"object","properties":{"query":{"type":"string"},"status":{"type":"integer"},"pageType":{"type":"string"},"limit":{"type":"integer"}}}},
 {"name":"get_url_details","description":"Get the stored detail for one URL.","inputSchema":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}},
 {"name":"get_gsc_data","description":"Get Google Search Console summary and categories.","inputSchema":{"type":"object","properties":{}}},
 {"name":"get_backlinks","description":"Get backlink summary and donor breakdown.","inputSchema":{"type":"object","properties":{}}},
 {"name":"get_schema_data","description":"Get schema type and compatibility distributions.","inputSchema":{"type":"object","properties":{}}},
 {"name":"get_page_weight_data","description":"Get Page Weight and AI Parsability data for matching URLs.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"}}}},
]
def snapshot():
    with open(SNAPSHOT, "r", encoding="utf-8") as f: return json.load(f)
def reply(i, result):
    if i is not None: print(json.dumps({"jsonrpc":"2.0","id":i,"result":result}, ensure_ascii=False), flush=True)
def tool_result(value, error=False):
    return {"content":[{"type":"text","text":json.dumps(value, ensure_ascii=False)}], "isError":error}
def call(name, a):
    d=snapshot(); c=d["context"]; urls=d["urls"]
    if name=="get_overview": return {"generatedAt":d["generatedAt"],"crawl":c["crawlSummary"],"overview":c["overview"],"pageTypes":c["pageTypeDistribution"]}
    if name=="get_issues": return c["issues"]
    if name=="get_gsc_data": return {"summary":c["gscSummary"],"categories":c["gscErrorCategories"]}
    if name=="get_backlinks": return {"summary":c["backlinkSummary"],"donorTypes":c["donorTypeBreakdown"],"anchorTypes":c["anchorTypeBreakdown"],"topDomains":c["topReferringDomains"],"sources":c["topBacklinkSources"]}
    if name=="get_schema_data": return {"types":c["schemaTypesDistribution"],"compatibility":c["schemaCompatibilityDistribution"]}
    if name=="get_url_details":
        target=a.get("url", ""); return next((x for x in urls if x["url"]==target), {"error":"URL not found"})
    if name=="get_page_weight_data":
        limit=max(1,min(int(a.get("limit",100)),500)); return {"summary":c["pageMetrics"],"urls":[x for x in urls if x["pageWeight"] or x["htmlSize"] or x["aiParsability"]!="Not assessed"][:limit]}
    if name=="get_urls":
        q=a.get("query","").lower(); status=a.get("status"); typ=a.get("pageType","").lower(); limit=max(1,min(int(a.get("limit",100)),500))
        return [x for x in urls if (not q or q in x["url"].lower() or q in x["title"].lower()) and (status is None or x["status"]==status) and (not typ or x["pageType"].lower()==typ)][:limit]
    return {"error":"Unknown tool"}
for line in sys.stdin:
    try:
        r=json.loads(line); mid=r.get("id"); method=r.get("method"); params=r.get("params") or {}
        if method in ("initialize","server/discover"):
            reply(mid,{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":False}},"serverInfo":{"name":"sharespider","version":"1.0"}})
        elif method=="tools/list": reply(mid,{"tools":TOOLS})
        elif method=="tools/call": reply(mid,tool_result(call(params.get("name",""),params.get("arguments") or {})))
    except Exception as e:
        reply(r.get("id") if 'r' in locals() else None, tool_result({"error":str(e)}, True))
"""#.replacingOccurrences(of: "__SNAPSHOT__", with: file.path)
        try script.data(using: .utf8)?.write(to: serverFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: serverFile.path)
        return serverFile
    }
}

actor HermesConnector {
    static let shared = HermesConnector()
    private var sessionID: String?
    private var gatewayBaseURL: URL?
    private var resolvedEndpoint = ""

    private struct DashboardStatus: Decodable {
        var gateway_running: Bool
        var gateway_health_url: String?
        var overall: String?
    }
    private struct CreatedSession: Decodable {
        var session: Session?
        struct Session: Decodable { var id: String }
    }
    private struct ChatResponse: Decodable {
        var message: Message
        struct Message: Decodable { var content: String }
    }

    func testConnection(settings: HermesSettings = .load()) async -> HermesConnectionStatus {
        do {
            // Configure the read-only MCP source before the gateway is used.
            // With a stopped gateway (the usual first-time setup) Hermes will
            // load this entry on its next start, so the first audit can use
            // the tools without a second setup step.
            let script = try HermesProjectSnapshot.installMCPServer()
            try await registerMCPServer(script: script)
            let base = try await resolveGateway(settings: settings, forceRefresh: true)
            return HermesConnectionStatus(connected: true, message: "Connected · \(base.host ?? "local Hermes") · ShareSpider MCP ready")
        } catch let error as LocalizedError {
            return HermesConnectionStatus(connected: false, message: error.errorDescription ?? "Disconnected")
        } catch {
            return HermesConnectionStatus(connected: false, message: "Disconnected")
        }
    }

    func analyze(context: AuditContext, records: [CrawlRecord]) async -> [AICodexAnalyst.CustomAnalysis] {
        do {
            _ = try HermesProjectSnapshot.write(context: context, records: records)
            let script = try HermesProjectSnapshot.installMCPServer()
            try await registerMCPServer(script: script)
            let settings = HermesSettings.load()
            let base = try await resolveGateway(settings: settings)
            let session = try await ensureSession(base: base, apiKey: settings.apiKey)
            let compactContext = try String(decoding: JSONEncoder().encode(context), as: UTF8.self)
            let prompt = """
            Проанализируй технический SEO-аудит текущего проекта. Тебе передан только агрегированный контекст ниже. Для подробностей самостоятельно используй MCP-инструменты ShareSpider: get_overview, get_issues, get_urls, get_url_details, get_gsc_data, get_backlinks, get_schema_data, get_page_weight_data. Проведи не более 10 дополнительных исследований. Перепроверяй выводы по исходным данным инструментов, не придумывай отсутствующие данные. При необходимости можешь исследовать сайт своими доступными инструментами.

            Верни ТОЛЬКО JSON: {"final_summary":"...","findings":[{"title":"...","evidence":"...","confidence":"High|Medium|Low","conclusion":"...","status":"Confirmed|Probable"}]}.

            Aggregate context:
            \(compactContext)
            """
            let response = try await post(base.appendingPathComponent("api/sessions/\(session)/chat"), body: ["message": prompt], apiKey: settings.apiKey)
            let message = try JSONDecoder().decode(ChatResponse.self, from: response).message.content
            return decodeFindings(message)
        } catch {
            return [.init(question: "Hermes agent analysis", reasonForAnalysis: "The Hermes agent could not start a verified investigation.", sourceData: "ShareSpider MCP", modelUsed: "Hermes", rawResult: "", codexVerification: error.localizedDescription, finalConclusion: "Hermes analysis was not completed: \(error.localizedDescription)", confidence: "Low", status: "Unable to verify")]
        }
    }

    private func resolveGateway(settings: HermesSettings, forceRefresh: Bool = false) async throws -> URL {
        let rawEndpoint = settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let endpoint = URL(string: rawEndpoint), let scheme = endpoint.scheme, ["http", "https"].contains(scheme) else { throw HermesError.invalidEndpoint }
        if !forceRefresh, let cached = gatewayBaseURL, resolvedEndpoint == rawEndpoint { return cached }
        // The Agent API is the preferred explicit endpoint. The dashboard has
        // a different API and must never be mistaken for an agent gateway.
        do {
            _ = try await get(endpoint.appendingPathComponent("v1/capabilities"), apiKey: settings.apiKey)
            gatewayBaseURL = endpoint
            resolvedEndpoint = rawEndpoint
            sessionID = nil
            return endpoint
        } catch HermesError.authenticationRequired {
            throw HermesError.authenticationRequired
        } catch {
            // This endpoint may be the Desktop dashboard. It has its own
            // status endpoint and can point at an Agent API when configured.
        }
        do {
            let data = try await get(endpoint.appendingPathComponent("api/status"))
            let dashboard = try JSONDecoder().decode(DashboardStatus.self, from: data)
            guard dashboard.gateway_running, let health = dashboard.gateway_health_url, let healthURL = URL(string: health) else { throw HermesError.apiServerUnavailable }
            let base = healthURL.deletingLastPathComponent()
            _ = try await get(base.appendingPathComponent("v1/capabilities"), apiKey: settings.apiKey)
            gatewayBaseURL = base
            resolvedEndpoint = rawEndpoint
            sessionID = nil
            return base
        } catch HermesError.authenticationRequired { throw HermesError.authenticationRequired }
        catch HermesError.apiServerUnavailable { throw HermesError.apiServerUnavailable }
        catch {
            throw HermesError.apiServerUnavailable
        }
    }

    private func ensureSession(base: URL, apiKey: String) async throws -> String {
        if let sessionID { return sessionID }
        let response = try await post(base.appendingPathComponent("api/sessions"), body: ["source": "sharespider", "title": "ShareSpider SEO audit \(UUID().uuidString.prefix(8))"], apiKey: apiKey)
        guard let id = try JSONDecoder().decode(CreatedSession.self, from: response).session?.id else { throw HermesError.invalidResponse }
        sessionID = id
        return id
    }

    private func get(_ url: URL, apiKey: String = "") async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 12
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HermesError.unavailable }
        if http.statusCode == 401 { throw HermesError.authenticationRequired }
        guard (200..<300).contains(http.statusCode) else { throw HermesError.unavailable }
        return data
    }

    private func post(_ url: URL, body: [String: String], apiKey: String) async throws -> Data {
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 1_800
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HermesError.unavailable }
        if http.statusCode == 401 { throw HermesError.authenticationRequired }
        guard (200..<300).contains(http.statusCode) else { throw HermesError.unavailable }
        return data
    }

    private func registerMCPServer(script: URL) async throws {
        let localHermes = FileManager.default.homeDirectoryForCurrentUser.path + "/.hermes/hermes-agent/venv/bin/hermes"
        let possibleExecutables = [localHermes, "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes"]
        guard let executable = possibleExecutables.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw HermesError.notInstalled }
        let list = await Task.detached(priority: .utility) { () -> String in
            let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["mcp", "list"]; process.standardOutput = output; process.standardError = output
            guard (try? process.run()) != nil else { return "" }
            process.waitUntilExit()
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }.value
        if list.localizedCaseInsensitiveContains("sharespider") { return }
        let result = await Task.detached(priority: .utility) { () -> Int32 in
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["mcp", "add", "sharespider", "--command", "/usr/bin/env", "--args", "python3", script.path]
            process.standardOutput = Pipe(); process.standardError = Pipe()
            do { try process.run(); process.waitUntilExit(); return process.terminationStatus } catch { return -1 }
        }.value
        // `mcp add` returning non-zero commonly means the named server is
        // already configured; it is safe to keep the existing read-only entry.
        guard result == 0 || result == 1 else { throw HermesError.mcpInstallFailed }
    }

    private func decodeFindings(_ value: String) -> [AICodexAnalyst.CustomAnalysis] {
        struct Output: Decodable { var final_summary: String; var findings: [Finding] }
        struct Finding: Decodable { var title: String; var evidence: String; var confidence: String; var conclusion: String; var status: String }
        guard let start = value.firstIndex(of: "{"), let end = value.lastIndex(of: "}"), let output = try? JSONDecoder().decode(Output.self, from: Data(value[start...end].utf8)) else {
            return [.init(question: "Hermes independent audit", reasonForAnalysis: "Agent-led investigation using ShareSpider MCP tools.", sourceData: "Overview, Issues, URLs, GSC, backlinks, schema and page weight", modelUsed: "Hermes", rawResult: value, codexVerification: "Hermes returned a non-structured response.", finalConclusion: value, confidence: "Medium", status: "Probable")]
        }
        var findings = output.findings.prefix(10).map { finding in
            AICodexAnalyst.CustomAnalysis(question: finding.title, reasonForAnalysis: "Hermes independent investigation", sourceData: "ShareSpider MCP", modelUsed: "Hermes", rawResult: finding.evidence, codexVerification: finding.evidence, finalConclusion: finding.conclusion, confidence: finding.confidence, status: finding.status)
        }
        findings.append(.init(question: "Hermes final summary", reasonForAnalysis: "Agent-led synthesis after independent research.", sourceData: "ShareSpider MCP", modelUsed: "Hermes", rawResult: output.final_summary, codexVerification: "Hermes final summary.", finalConclusion: output.final_summary, confidence: "High", status: "Confirmed"))
        return Array(findings)
    }

    private enum HermesError: LocalizedError {
        case invalidEndpoint, gatewayStopped, apiServerUnavailable, authenticationRequired, unavailable, invalidResponse, notInstalled, mcpInstallFailed
        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: "Hermes Endpoint must be a local HTTP URL."
            case .gatewayStopped: "Hermes Desktop is open, but its agent gateway is not running. Start the gateway in Hermes, then test again."
            case .apiServerUnavailable: "Hermes Agent API is not available at this endpoint. Start Hermes' local API server and enter its endpoint (normally http://127.0.0.1:8642)."
            case .authenticationRequired: "Hermes Agent API requires its local API key. Enter the API key in ShareSpider settings and test again."
            case .unavailable: "Hermes gateway did not accept the request."
            case .invalidResponse: "Hermes returned an unreadable session response."
            case .notInstalled: "Hermes CLI was not found on this Mac."
            case .mcpInstallFailed: "ShareSpider MCP could not be registered in Hermes."
            }
        }
    }
}
