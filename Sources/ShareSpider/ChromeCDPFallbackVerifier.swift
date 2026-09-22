import Foundation

struct ChromeCDPVerification: Sendable {
    var status: Int?
    var finalURL = ""
    var contentLength = 0
    var contentType = ""
    var html = ""
    var error = ""
    var succeeded: Bool { guard let status else { return false }; return (200...299).contains(status) && contentLength > 0 }
    var hasParseableHTML: Bool { contentType.localizedCaseInsensitiveContains("text/html") && !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// One long-lived connection to the user's local Chrome profile. Reusing this
/// context preserves ordinary browser cookies, but never attempts to solve a
/// challenge or obtain access the user does not already have.
actor ChromeCDPSession {
    static let shared = ChromeCDPSession()
    private var process: Process?
    private var input: FileHandle?
    private var pending: [String: CheckedContinuation<ChromeCDPVerification, Never>] = [:]
    private var outputBuffer = Data()
    private let requestTimeout: Duration = .seconds(35)

    private func helperURL() -> URL? {
        if let resources = Bundle.main.resourceURL {
            let installed = resources.appendingPathComponent("SEOSpiderAgent_ShareSpider.bundle/chrome-cdp-bridge.mjs")
            if FileManager.default.fileExists(atPath: installed.path) { return installed }
        }
        return AppResources.url(forResource: "chrome-cdp-bridge", withExtension: "mjs")
    }

    func verify(_ url: URL) async -> ChromeCDPVerification {
        guard let helper = helperURL() else {
            return ChromeCDPVerification(status: nil, error: "Chrome fallback helper is unavailable.")
        }
        do { try startIfNeeded(helper: helper) }
        catch { return ChromeCDPVerification(status: nil, error: error.localizedDescription) }

        let id = UUID().uuidString
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: self?.requestTimeout ?? .seconds(35))
                await self?.expireRequest(id)
            }
            let payload: [String: String] = ["id": id, "url": url.absoluteString]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
                pending.removeValue(forKey: id)?.resume(returning: ChromeCDPVerification(status: nil, error: "Unable to encode Chrome request.")); return
            }
            do { try input?.write(contentsOf: data + Data([0x0A])) }
            catch {
                pending.removeValue(forKey: id)?.resume(returning: ChromeCDPVerification(status: nil, error: error.localizedDescription))
            }
        }
    }

    /// The Node helper enforces a shorter per-tab deadline. This actor-level
    /// guard also releases a crawler worker if the helper itself stops writing.
    private func expireRequest(_ id: String) {
        pending.removeValue(forKey: id)?.resume(returning: ChromeCDPVerification(status: nil, error: "Chrome CDP request timed out."))
    }

    private func startIfNeeded(helper: URL) throws {
        if process?.isRunning == true { return }
        let process = Process(); let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", helper.path]
        process.environment = ChromeGSCPageIndexingSync.playwrightEnvironment()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.receive(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.terminationHandler = { [weak self] _ in Task { await self?.didTerminate() } }
        try process.run()
        self.process = process; self.input = stdin.fileHandleForWriting
    }

    private func receive(_ data: Data) {
        outputBuffer.append(data)
        while let end = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: end)
            outputBuffer.removeSubrange(...end)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = value["id"] as? String,
                  let continuation = pending.removeValue(forKey: id) else { continue }
            let html = (value["htmlBase64"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            continuation.resume(returning: ChromeCDPVerification(status: value["status"] as? Int, finalURL: value["url"] as? String ?? "", contentLength: value["contentLength"] as? Int ?? 0, contentType: value["contentType"] as? String ?? "", html: html, error: value["error"] as? String ?? ""))
        }
    }

    private func didTerminate() {
        process = nil; input = nil; outputBuffer = Data()
        let waiting = pending; pending.removeAll()
        for continuation in waiting.values { continuation.resume(returning: ChromeCDPVerification(status: nil, error: "Local Chrome CDP session ended.")) }
    }
}

actor ChromeFallbackQueue {
    private var records: [CrawlRecord] = []
    private var cursor = 0
    private var closed = false

    func enqueue(_ record: CrawlRecord) { records.append(record) }
    func close() { closed = true }
    private func next() -> CrawlRecord? {
        guard cursor < records.count else { return nil }
        defer { cursor += 1 }
        return records[cursor]
    }
    private func finished() -> Bool { closed && cursor == records.count }

    func run(onRecord: @escaping @Sendable (CrawlRecord, ChromeCDPVerification) async -> Void, onProgress: @escaping @Sendable (Bool) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    while true {
                        guard let original = await self.next() else {
                            if await self.finished() { return }
                            try? await Task.sleep(for: .milliseconds(180)); continue
                        }
                        let check = await ChromeCDPSession.shared.verify(original.url)
                        var verified = original
                        verified.cdpStatus = check.status
                        if check.status != nil { verified.transportUsed = "cdp" }
                        if check.succeeded {
                            verified.statusCode = check.status
                            verified.contentType = check.contentType
                            verified.error = ""
                            verified.verificationResult = check.hasParseableHTML ? "Verified via Chrome" : "Chrome content unavailable"
                        } else {
                            verified.verificationResult = check.status == nil ? "Chrome verification unavailable" : "Chrome confirmed server error"
                        }
                        await onRecord(verified, check)
                        await onProgress(check.succeeded)
                    }
                }
            }
        }
    }
}
