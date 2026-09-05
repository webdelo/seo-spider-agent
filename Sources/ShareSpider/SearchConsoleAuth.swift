import AppKit
import CryptoKit
import Foundation
import Network

/// OAuth connection for Google Search Console. Credentials and refresh tokens
/// stay in ShareSpider's private local Application Support file.  This avoids
/// repeated macOS Keychain password prompts during automatic checks.
@MainActor
final class SearchConsoleAuth: ObservableObject {
    static let shared = SearchConsoleAuth()

    /// Existing desktop OAuth client in the `Fedorov` Google Cloud project.
    static let webdeloDesktopClientID = "1054924384113-9tn0vqkdsp655eqg5liaa96mdhj8mlpf.apps.googleusercontent.com"
    private static let clientIDAccount = "oauth-client-id"
    private static let clientSecretAccount = "oauth-client-secret"
    private static let refreshTokenAccount = "refresh-token"

    @Published private(set) var isAuthorizing = false
    @Published private(set) var status = "Not connected"

    private init() { refreshStatus() }

    var clientID: String { Self.load(Self.clientIDAccount).isEmpty ? Self.webdeloDesktopClientID : Self.load(Self.clientIDAccount) }
    var clientSecret: String { Self.load(Self.clientSecretAccount) }
    var isConnected: Bool { !Self.load(Self.refreshTokenAccount).isEmpty }

    func refreshStatus() {
        setStatus(isConnected ? "Connected to Google Search Console" : "Not connected")
    }

    func saveClient(clientID: String, clientSecret: String) {
        Self.save(clientID.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.clientIDAccount)
        Self.save(clientSecret.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.clientSecretAccount)
        refreshStatus()
    }

    func disconnect() {
        Self.save("", account: Self.refreshTokenAccount)
        refreshStatus()
    }

    /// Exchanges the locally stored refresh token for a short-lived access token.
    /// It is intentionally not persisted outside the current request.
    func accessToken() async throws -> String {
        let refreshToken = Self.load(Self.refreshTokenAccount)
        guard !refreshToken.isEmpty else { throw AuthError.notConnected }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        // Do not let a stalled OAuth endpoint hold the entire automatic GSC
        // measurement forever.  The caller turns this into a visible journal
        // status instead of leaving an endless "Checking…" state.
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var values = ["client_id": clientID, "refresh_token": refreshToken, "grant_type": "refresh_token"]
        if !clientSecret.isEmpty { values["client_secret"] = clientSecret }
        request.httpBody = values.map { "\($0.key.urlEncoded)=\($0.value.urlEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await SearchConsoleHTTP.data(for: request, deadline: 20)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String ?? "Google refresh-token request failed."
            // A saved token can become invalid when the OAuth client is
            // replaced, access is removed in the Google account, or Google
            // revokes the session.  Leaving it in place made the UI say
            // "Connected" while every crawl silently produced GSC zeroes.
            // Clear only this invalid refresh token and make the required
            // action explicit; client settings remain untouched.
            let normalized = message.lowercased()
            if normalized.contains("expired") || normalized.contains("revoked") || normalized.contains("invalid_grant") {
                Self.save("", account: Self.refreshTokenAccount)
                setStatus("Google authorization expired. Reconnect Search Console in Settings → Integrations.")
            }
            throw AuthError.request(message)
        }
        return try JSONDecoder().decode(AccessTokenResponse.self, from: data).accessToken
    }

    func authorize() async {
        // The Settings sheet can receive repeated clicks while macOS is opening
        // the browser. Do not create parallel loopback listeners or duplicate
        // consent windows for the same OAuth attempt.
        guard !isAuthorizing else { return }
        guard !clientID.isEmpty else { setStatus("Enter an OAuth client ID first."); return }
        // Google issues a client secret for desktop OAuth clients too. Without
        // it the token endpoint rejects the authorization-code exchange, which
        // previously looked like a successful browser connection followed by
        // empty GSC data in the project journal.
        guard !clientSecret.isEmpty else {
            setStatus("OAuth client secret is missing. Download the OAuth client JSON in Google Cloud and paste its client_secret in Settings → Integrations.")
            return
        }
        isAuthorizing = true
        defer { isAuthorizing = false }
        do {
            let server = try OAuthLoopbackServer()
            try await server.start()
            let redirectURI = "http://127.0.0.1:\(server.port)/oauth2callback"
            let verifier = Self.randomVerifier()
            let challenge = Self.codeChallenge(for: verifier)
            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/webmasters.readonly"),
                URLQueryItem(name: "access_type", value: "offline"),
                // Google otherwise may return an authorization code without a
                // refresh token when this client was approved previously.  The
                // explicit Connect action is the only time we request consent,
                // and it makes subsequent automatic crawls possible locally.
                URLQueryItem(name: "prompt", value: "consent"),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256")
            ]
            guard let authURL = components.url else { throw AuthError.invalidURL }
            // The native app starts the browser, while the local MCP bridge can
            // also surface the same pending OAuth URL if macOS does not bring a
            // browser tab to the front.  It contains only a one-time PKCE
            // challenge, never an access or refresh token.
            Self.persistPendingAuthorizationURL(authURL)
            setStatus("Waiting for Google authorization…")
            NSWorkspace.shared.open(authURL)
            let code = try await server.waitForCode()
            let token = try await Self.exchange(code: code, redirectURI: redirectURI, verifier: verifier, clientID: clientID, clientSecret: clientSecret)
            guard !token.refreshToken.isEmpty else { throw AuthError.noRefreshToken }
            Self.save(token.refreshToken, account: Self.refreshTokenAccount)
            setStatus("Connected to Google Search Console")
        } catch {
            setStatus("Authorization failed: \(error.localizedDescription)")
        }
    }

    /// A harmless local status mirror lets the MCP launcher and support checks
    /// diagnose OAuth without reading an access token or provoking Keychain UI.
    private func setStatus(_ value: String) {
        status = value
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("search-console-status.txt")
        try? value.data(using: .utf8)?.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func exchange(code: String, redirectURI: String, verifier: String, clientID: String, clientSecret: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var values = [
            "code": code, "client_id": clientID, "redirect_uri": redirectURI,
            "grant_type": "authorization_code", "code_verifier": verifier
        ]
        if !clientSecret.isEmpty { values["client_secret"] = clientSecret }
        request.httpBody = values.map { "\($0.key.urlEncoded)=\($0.value.urlEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await SearchConsoleHTTP.data(for: request, deadline: 25)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String ?? "Google token request failed."
            throw AuthError.request(message)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func randomVerifier() -> String { Data((0..<64).map { _ in UInt8.random(in: 0...255) }).base64URLEncoded }
    private static func codeChallenge(for verifier: String) -> String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded }

    private static var credentialsFile: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("search-console-credentials.json")
    }

    private static var pendingAuthorizationURLFile: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("search-console-authorization-url.txt")
    }

    private static func persistPendingAuthorizationURL(_ url: URL) {
        try? url.absoluteString.data(using: .utf8)?.write(to: pendingAuthorizationURLFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingAuthorizationURLFile.path)
    }

    private static func load(_ account: String) -> String {
        guard let data = try? Data(contentsOf: credentialsFile),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return "" }
        return values[account] ?? ""
    }

    private static func save(_ value: String, account: String) {
        var values: [String: String] = [:]
        if let data = try? Data(contentsOf: credentialsFile), let existing = try? JSONDecoder().decode([String: String].self, from: data) {
            values = existing
        }
        if value.isEmpty { values.removeValue(forKey: account) } else { values[account] = value }
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: credentialsFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsFile.path)
    }
}

private struct TokenResponse: Decodable {
    let refreshToken: String
    enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token" }
}

private struct AccessTokenResponse: Decodable {
    let accessToken: String
    enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
}

private enum AuthError: LocalizedError {
    case invalidURL, noRefreshToken, notConnected, request(String)
    var errorDescription: String? {
        switch self { case .invalidURL: "Invalid OAuth URL."; case .noRefreshToken: "Google did not return a refresh token. Remove the app access in your Google account and try again."; case .notConnected: "Connect Google Search Console in Settings → Integrations first."; case .request(let message): message }
    }
}

/// `URLRequest.timeoutInterval` is not a hard deadline for every DNS/TLS
/// failure on macOS.  The integration must finish a journal measurement even
/// when Google's endpoint or the network stack stalls, so race every request
/// against an explicit Swift-concurrency timeout.
private enum SearchConsoleHTTP {
    static func data(for request: URLRequest, deadline: TimeInterval) async throws -> (Data, URLResponse) {
        let state = RequestState()
        return try await withCheckedThrowingContinuation { continuation in
            state.continuation = continuation
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    state.finish(.failure(error))
                } else if let data, let response {
                    state.finish(.success((data, response)))
                } else {
                    state.finish(.failure(AuthError.request("Google Search Console did not return a response.")))
                }
            }
            state.task = task
            task.resume()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline) {
                state.timeout(after: deadline)
            }
        }
    }

    private final class RequestState: @unchecked Sendable {
        private let lock = NSLock()
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        private var completed = false

        func timeout(after deadline: TimeInterval) {
            task?.cancel()
            finish(.failure(AuthError.request("Google Search Console request timed out after \(Int(deadline)) seconds.")))
        }

        func finish(_ result: Result<(Data, URLResponse), Error>) {
            lock.lock()
            guard !completed, let continuation else { lock.unlock(); return }
            completed = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        }
    }
}

private final class OAuthLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let codeLock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    /// Google can redirect immediately for an already signed-in browser. Keep a
    /// callback that arrives between `start()` and `waitForCode()` rather than
    /// silently dropping it and leaving the connection marked as incomplete.
    private var pendingCode: String?
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
    }

    deinit { listener.cancel() }
    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = OAuthContinuationGate()
            listener.stateUpdateHandler = { state in
                guard gate.take() else { return }
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    gate.release()
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "com.sharespider.search-console.oauth"))
        }
    }
    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            codeLock.lock()
            if let pendingCode {
                self.pendingCode = nil
                codeLock.unlock()
                continuation.resume(returning: pendingCode)
            } else {
                self.continuation = continuation
                codeLock.unlock()
            }
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "com.sharespider.search-console.oauth.connection"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let path = request.split(separator: "\n").first?.split(separator: " ").dropFirst().first,
                  let components = URLComponents(string: "http://localhost\(path)"),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value else { return }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<html><body><h2>ShareSpider connected.</h2><p>You may close this browser tab and return to the app.</p></body></html>"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            self.listener.cancel()
            self.codeLock.lock()
            let continuation = self.continuation
            self.continuation = nil
            if continuation == nil { self.pendingCode = code }
            self.codeLock.unlock()
            continuation?.resume(returning: code)
        }
    }
}

private final class OAuthContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; guard !consumed else { return false }; consumed = true; return true }
    func release() { lock.lock(); consumed = false; lock.unlock() }
}

private extension String {
    var urlEncoded: String { addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self }
}

private extension Data {
    var base64URLEncoded: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

struct SearchConsoleInspection: Sendable {
    var indexStatus = "Unknown"
    var fetchStatus = "—"
    var coverage = ""
    var googleCanonical = ""
    var lastCrawl = ""
    var robotsStatus = ""
    var noindexStatus = ""
    var sitemaps: [String] = []
    var richResultErrors: [String] = []
    var mobileIssues: [String] = []
}

enum SearchConsoleInspectionService {
    /// Returns the properties the signed-in Google account can actually use.
    /// URL Inspection rejects a request when `siteUrl` is guessed as a URL
    /// prefix while the account owns only an `sc-domain:` property (or the
    /// opposite www variant).  Resolve the real property before inspecting.
    static func accessibleProperties(accessToken: String) async throws -> Set<String> {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/webmasters/v3/sites")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await SearchConsoleHTTP.data(for: request, deadline: 25)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            throw SearchConsoleError.request(message?["message"] as? String ?? "Could not read Google Search Console properties.")
        }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = root?["siteEntry"] as? [[String: Any]] ?? []
        return Set(entries.compactMap { $0["siteUrl"] as? String })
    }

    /// Finds the narrowest accessible GSC property for a crawled URL. An exact
    /// prefix property wins; a domain property is a valid fallback for any
    /// matching subdomain.
    static func siteProperty(for url: URL, accessibleProperties: Set<String>) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let exact = "\(scheme)://\(host)/"
        if let match = accessibleProperties.first(where: { $0.caseInsensitiveCompare(exact) == .orderedSame || $0.caseInsensitiveCompare(String(exact.dropLast())) == .orderedSame }) {
            return match
        }
        let domainProperties = accessibleProperties.filter { $0.lowercased().hasPrefix("sc-domain:") }
        if let match = domainProperties.first(where: { property in
            let domain = String(property.dropFirst("sc-domain:".count)).lowercased()
            return host == domain || host.hasSuffix("." + domain)
        }) {
            return match
        }
        return nil
    }

    static func inspect(url: URL, siteURL: String, accessToken: String) async throws -> SearchConsoleInspection {
        var request = URLRequest(url: URL(string: "https://searchconsole.googleapis.com/v1/urlInspection/index:inspect")!)
        request.httpMethod = "POST"
        // A stalled request must not leave the project journal in “Checking…” indefinitely.
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["inspectionUrl": url.absoluteString, "siteUrl": siteURL])
        let (data, response) = try await SearchConsoleHTTP.data(for: request, deadline: 25)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            let detail = message?["message"] as? String ?? "Search Console inspection failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))."
            throw SearchConsoleError.request(detail)
        }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let inspection = root?["inspectionResult"] as? [String: Any]
        let index = inspection?["indexStatusResult"] as? [String: Any]
        let verdict = (index?["verdict"] as? String ?? "UNKNOWN").uppercased()
        let indexingState = (index?["indexingState"] as? String ?? "").uppercased()
        let coverage = index?["coverageState"] as? String ?? ""
        let fetch = (index?["pageFetchState"] as? String ?? "").uppercased()
        let robots = (index?["robotsTxtState"] as? String ?? "").uppercased()
        let googleCanonical = index?["googleCanonical"] as? String ?? ""
        let lastCrawl = index?["lastCrawlTime"] as? String ?? ""
        let sitemaps = index?["sitemap"] as? [String] ?? []
        let rich = inspection?["richResultsResult"] as? [String: Any]
        var richErrors: [String] = []
        for group in rich?["detectedItems"] as? [[String: Any]] ?? [] {
            let type = group["richResultType"] as? String ?? "Rich result"
            for item in group["items"] as? [[String: Any]] ?? [] {
                for issue in item["issues"] as? [[String: Any]] ?? [] {
                    if let message = issue["issueMessage"] as? String, !message.isEmpty {
                        richErrors.append("\(type): \(message)")
                    }
                }
            }
        }
        let mobile = inspection?["mobileUsabilityResult"] as? [String: Any]
        let mobileIssues = (mobile?["issues"] as? [[String: Any]] ?? []).compactMap { issue in
            let type = issue["issueType"] as? String ?? "Mobile usability issue"
            let message = issue["message"] as? String ?? ""
            return message.isEmpty ? type : "\(type): \(message)"
        }
        let indexed: String
        if verdict == "PASS" && !indexingState.contains("BLOCKED") { indexed = "Indexed" }
        else if verdict == "FAIL" || verdict == "NEUTRAL" || indexingState.contains("BLOCKED") { indexed = "Not indexed" }
        else { indexed = "Unknown" }
        // "Submitted and indexed" is a successful coverage state, so the
        // dedicated issue column stays empty instead of creating noise.
        let normalizedCoverage = coverage.lowercased()
        let coverageIssue = (normalizedCoverage == "submitted and indexed" || normalizedCoverage == "indexed, not submitted in sitemap") ? "" : coverage
        return SearchConsoleInspection(
            indexStatus: indexed,
            fetchStatus: fetchLabel(fetch),
            coverage: coverageIssue,
            googleCanonical: googleCanonical,
            lastCrawl: lastCrawl,
            robotsStatus: robotsLabel(robots),
            noindexStatus: noindexLabel(indexingState),
            sitemaps: sitemaps,
            richResultErrors: richErrors,
            mobileIssues: mobileIssues
        )
    }

    private static func fetchLabel(_ state: String) -> String {
        switch state {
        case "", "SUCCESS": return "No error"
        case "NOT_FOUND": return "HTTP 404 · Not found"
        case "SOFT_404": return "Soft 404"
        case "SERVER_ERROR": return "HTTP 5xx · Server error"
        case "REDIRECT_ERROR": return "Redirect error"
        case "BLOCKED_ROBOTS_TXT": return "Blocked by robots.txt"
        case "ACCESS_DENIED": return "Access denied"
        default: return state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func robotsLabel(_ state: String) -> String {
        switch state {
        case "ALLOWED": return "Allowed"
        case "DISALLOWED": return "Blocked"
        case "": return "Unknown"
        default: return state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func noindexLabel(_ state: String) -> String {
        switch state {
        case "INDEXING_ALLOWED": return "No noindex"
        case "BLOCKED_BY_META_TAG": return "noindex meta robots"
        case "BLOCKED_BY_HTTP_HEADER": return "noindex X-Robots-Tag"
        case "": return "Unknown"
        default: return state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct SearchConsolePagePerformance: Sendable {
    var clicks = 0
    var impressions = 0
    var queryCount = 0
    var queriesTop10 = 0
    var queriesTop20 = 0
}

struct SearchConsoleTrafficCountry: Codable, Hashable, Sendable {
    var code: String
    var clicks: Int
    var share: Double
}

struct SearchConsolePerformanceSnapshot: Sendable {
    var pages: [String: SearchConsolePagePerformance] = [:]
    var countries: [SearchConsoleTrafficCountry] = []
}

/// Search Analytics complements URL Inspection with organic performance for
/// the current crawl's canonical URLs. It never asks Google about images, PDFs
/// or alternate canonical variants.
enum SearchConsolePerformanceService {
    static func fetch(siteURL: String, pageURLs: [URL], accessToken: String) async throws -> SearchConsolePerformanceSnapshot {
        let requested = Set(pageURLs.map(normalize))
        guard !requested.isEmpty else { return SearchConsolePerformanceSnapshot() }
        let dates = reportingDates()
        let pageRows = try await query(siteURL: siteURL, dimensions: ["page", "query"], startDate: dates.start, endDate: dates.end, accessToken: accessToken)
        var pageStats: [String: (clicks: Int, impressions: Int, queries: Set<String>, top10: Set<String>, top20: Set<String>)] = [:]
        for row in pageRows {
            guard row.keys.count >= 2 else { continue }
            let page = normalize(URL(string: row.keys[0]) ?? URL(string: "https://invalid.local/")!)
            guard requested.contains(page) else { continue }
            let query = row.keys[1]
            var value = pageStats[page] ?? (0, 0, [], [], [])
            value.clicks += Int(row.clicks.rounded())
            value.impressions += Int(row.impressions.rounded())
            value.queries.insert(query)
            if row.position <= 10 { value.top10.insert(query) }
            if row.position <= 20 { value.top20.insert(query) }
            pageStats[page] = value
        }
        var pages: [String: SearchConsolePagePerformance] = [:]
        for page in requested {
            let value = pageStats[page] ?? (0, 0, [], [], [])
            pages[page] = SearchConsolePagePerformance(clicks: value.clicks, impressions: value.impressions, queryCount: value.queries.count, queriesTop10: value.top10.count, queriesTop20: value.top20.count)
        }
        let countryRows = try await query(siteURL: siteURL, dimensions: ["country"], startDate: dates.start, endDate: dates.end, accessToken: accessToken)
        let totalClicks = countryRows.reduce(0) { $0 + Int($1.clicks.rounded()) }
        let countries = countryRows
            .map { SearchConsoleTrafficCountry(code: $0.keys.first?.uppercased() ?? "Unknown", clicks: Int($0.clicks.rounded()), share: totalClicks > 0 ? $0.clicks / Double(totalClicks) : 0) }
            .sorted { $0.clicks > $1.clicks }
            .prefix(5)
        return SearchConsolePerformanceSnapshot(pages: pages, countries: Array(countries))
    }

    private struct AnalyticsRow {
        var keys: [String]
        var clicks: Double
        var impressions: Double
        var position: Double
    }

    private static func query(siteURL: String, dimensions: [String], startDate: String, endDate: String, accessToken: String) async throws -> [AnalyticsRow] {
        let encodedSite = siteURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? siteURL
        guard let endpoint = URL(string: "https://searchconsole.googleapis.com/webmasters/v3/sites/\(encodedSite)/searchAnalytics/query") else { throw SearchConsoleError.request("Could not create Search Analytics request.") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["startDate": startDate, "endDate": endDate, "dimensions": dimensions, "rowLimit": 25_000, "dataState": "final"])
        let (data, response) = try await SearchConsoleHTTP.data(for: request, deadline: 30)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            throw SearchConsoleError.request(message?["message"] as? String ?? "Search Analytics request failed.")
        }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (root?["rows"] as? [[String: Any]] ?? []).map { row in
            AnalyticsRow(keys: row["keys"] as? [String] ?? [], clicks: row["clicks"] as? Double ?? 0, impressions: row["impressions"] as? Double ?? 0, position: row["position"] as? Double ?? 0)
        }
    }

    private static func reportingDates() -> (start: String, end: String) {
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        let now = Date()
        return (formatter.string(from: calendar.date(byAdding: .day, value: -8, to: now) ?? now), formatter.string(from: calendar.date(byAdding: .day, value: -2, to: now) ?? now))
    }

    private static func normalize(_ url: URL) -> String { url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() }
}

enum SearchConsoleError: LocalizedError {
    case request(String)
    var errorDescription: String? { if case .request(let text) = self { return text }; return nil }
}
