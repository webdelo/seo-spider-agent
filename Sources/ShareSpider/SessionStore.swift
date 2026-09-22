import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Durable, per-crawl storage. Large crawls are stored as self-contained
/// folders, instead of being accumulated in a single application-wide file.
@MainActor
final class SessionStore {
    static let shared = SessionStore()

    private struct RunManifest: Codable {
        var startURL: String
        var createdAt: Date
        var finishedAt: Date?
        var formatVersion = 1
    }

    private struct LatestRun: Codable { var directory: String }

    private var db: OpaquePointer?
    private(set) var activeRunDirectory: URL?

    private var applicationSupportDirectory: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShareSpider", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Every crawl gets an easily recognisable date-and-time folder in Downloads.
    private var runsDirectory: URL {
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShareSpider Crawls", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var latestRunFile: URL { applicationSupportDirectory.appendingPathComponent("latest-crawl-run.json") }

    private init() {
        if let data = try? Data(contentsOf: latestRunFile),
           let pointer = try? JSONDecoder().decode(LatestRun.self, from: data) {
            let directory = URL(fileURLWithPath: pointer.directory, isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("crawl.sqlite").path) {
                activeRunDirectory = directory
            }
        }
    }

    /// Starts durable storage before the first request. A partial crawl can then
    /// be opened after a crash or a manual Stop.
    @discardableResult
    func beginRun(startURL: String, date: Date = Date()) -> URL? {
        closeDatabase()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let baseName = formatter.string(from: date)
        var directory = runsDirectory.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory.path) {
            directory = runsDirectory.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let manifest = RunManifest(startURL: startURL, createdAt: date)
            try JSONEncoder.pretty.encode(manifest).write(to: directory.appendingPathComponent("run.json"), options: .atomic)
        } catch {
            return nil
        }

        guard openDatabase(at: directory.appendingPathComponent("crawl.sqlite")) else { return nil }
        activeRunDirectory = directory
        if let data = try? JSONEncoder().encode(LatestRun(directory: directory.path)) {
            try? data.write(to: latestRunFile, options: .atomic)
        }
        return directory
    }

    /// Records are written in the same short batches used by the UI. The
    /// transaction is intentionally compact so storage does not throttle HTTP.
    func persist(_ records: [CrawlRecord]) {
        guard let db, !records.isEmpty else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil)
        defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }

        let sql = """
        INSERT INTO pages (url, status, title, canonical, depth, response_time, size, redirects, content_type, page_type, ai_bust_category, h1, h1_count, word_count, internal_links, external_links, inlinks, image_count, resource_count, page_weight, weight_status, ai_parsability, transport, original_status, cdp_status, verification_result, error, updated_at, transfer_size, content_encoding)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(url) DO UPDATE SET
          status=excluded.status, title=excluded.title, canonical=excluded.canonical, depth=excluded.depth,
          response_time=excluded.response_time, size=excluded.size, redirects=excluded.redirects,
          content_type=excluded.content_type, page_type=excluded.page_type, ai_bust_category=excluded.ai_bust_category, h1=excluded.h1,
          h1_count=excluded.h1_count, word_count=excluded.word_count, internal_links=excluded.internal_links,
          external_links=excluded.external_links, inlinks=excluded.inlinks, image_count=excluded.image_count,
          resource_count=excluded.resource_count, page_weight=excluded.page_weight, weight_status=excluded.weight_status,
          ai_parsability=excluded.ai_parsability, transport=excluded.transport, original_status=excluded.original_status,
          cdp_status=excluded.cdp_status, verification_result=excluded.verification_result, error=excluded.error,
          updated_at=excluded.updated_at, transfer_size=excluded.transfer_size, content_encoding=excluded.content_encoding
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        for record in records {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, record.url.absoluteString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 2, Int32(record.statusCode ?? 0))
            sqlite3_bind_text(statement, 3, record.title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, record.canonical, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 5, Int32(record.depth))
            sqlite3_bind_double(statement, 6, record.responseTime)
            sqlite3_bind_int64(statement, 7, Int64(record.size))
            sqlite3_bind_text(statement, 8, record.redirectSources.map(\.absoluteString).joined(separator: "|"), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 9, record.contentType, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 10, record.pageType, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 11, record.aiBustCategory, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 12, record.h1, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 13, Int32(record.h1Count))
            sqlite3_bind_int(statement, 14, Int32(record.wordCount))
            sqlite3_bind_int(statement, 15, Int32(record.internalLinks))
            sqlite3_bind_int(statement, 16, Int32(record.externalLinks))
            sqlite3_bind_int(statement, 17, Int32(record.inlinks))
            sqlite3_bind_int(statement, 18, Int32(record.images.count))
            sqlite3_bind_int(statement, 19, Int32(record.resourceRequestCount))
            sqlite3_bind_int64(statement, 20, Int64(record.pageWeight))
            sqlite3_bind_text(statement, 21, record.weightStatus, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 22, record.aiParsability, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 23, record.transportUsed, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 24, Int32(record.originalStatus ?? 0))
            sqlite3_bind_int(statement, 25, Int32(record.cdpStatus ?? 0))
            sqlite3_bind_text(statement, 26, record.verificationResult, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 27, record.error, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 28, Date().timeIntervalSince1970)
            sqlite3_bind_int64(statement, 29, Int64(record.transferredSize))
            sqlite3_bind_text(statement, 30, record.contentEncoding, -1, SQLITE_TRANSIENT)
            sqlite3_step(statement)
        }
    }

    func writeProgress(_ data: Data) {
        guard let activeRunDirectory else { return }
        try? data.write(to: activeRunDirectory.appendingPathComponent("progress.json"), options: .atomic)
    }

    func finishRun() {
        guard let activeRunDirectory else { return }
        let manifestURL = activeRunDirectory.appendingPathComponent("run.json")
        if let data = try? Data(contentsOf: manifestURL), var manifest = try? JSONDecoder().decode(RunManifest.self, from: data) {
            manifest.finishedAt = Date()
            if let updated = try? JSONEncoder.pretty.encode(manifest) {
                try? updated.write(to: manifestURL, options: .atomic)
            }
        }
        // Flush the small WAL file so the folder remains portable immediately.
        if let db { sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) }
    }

    /// Restores the last durable crawl. The old private sessions file remains
    /// a read-only fallback for crawls created by earlier app versions.
    func latestSession() -> (startURL: String, records: [CrawlRecord])? {
        if let pointerData = try? Data(contentsOf: latestRunFile),
           let pointer = try? JSONDecoder().decode(LatestRun.self, from: pointerData),
           let restored = loadRun(at: URL(fileURLWithPath: pointer.directory, isDirectory: true)) {
            return restored
        }
        return loadLegacySession()
    }

    private func openDatabase(at url: URL) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            return false
        }
        db = handle
        sqlite3_busy_timeout(handle, 1_500)
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY;", nil, nil, nil)
        sqlite3_exec(handle, """
        CREATE TABLE IF NOT EXISTS pages (
          url TEXT PRIMARY KEY, status INTEGER, title TEXT, canonical TEXT, depth INTEGER,
          response_time REAL, size INTEGER, redirects TEXT, content_type TEXT, page_type TEXT, ai_bust_category TEXT,
          h1 TEXT, h1_count INTEGER, word_count INTEGER, internal_links INTEGER, external_links INTEGER,
          inlinks INTEGER, image_count INTEGER, resource_count INTEGER, page_weight INTEGER,
          weight_status TEXT, ai_parsability TEXT, transport TEXT, original_status INTEGER,
          cdp_status INTEGER, verification_result TEXT, error TEXT, updated_at REAL,
          transfer_size INTEGER, content_encoding TEXT
        );
        CREATE INDEX IF NOT EXISTS pages_status_idx ON pages(status);
        """, nil, nil, nil)
        // Existing crawl folders remain readable after adding the subcategory.
        sqlite3_exec(handle, "ALTER TABLE pages ADD COLUMN ai_bust_category TEXT", nil, nil, nil)
        sqlite3_exec(handle, "ALTER TABLE pages ADD COLUMN transfer_size INTEGER", nil, nil, nil)
        sqlite3_exec(handle, "ALTER TABLE pages ADD COLUMN content_encoding TEXT", nil, nil, nil)
        return true
    }

    private func closeDatabase() {
        guard let db else { return }
        sqlite3_close(db)
        self.db = nil
    }

    private func tableHasColumn(_ handle: OpaquePointer?, table: String, column: String) -> Bool {
        guard let handle else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 1), String(cString: value) == column { return true }
        }
        return false
    }

    private func loadRun(at directory: URL) -> (startURL: String, records: [CrawlRecord])? {
        let manifestURL = directory.appendingPathComponent("run.json")
        let databaseURL = directory.appendingPathComponent("crawl.sqlite")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(RunManifest.self, from: manifestData),
              FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else { return nil }
        defer { sqlite3_close(handle) }
        let aiCategory = tableHasColumn(handle, table: "pages", column: "ai_bust_category") ? "ai_bust_category" : "''"
        let transferSize = tableHasColumn(handle, table: "pages", column: "transfer_size") ? "transfer_size" : "0"
        let contentEncoding = tableHasColumn(handle, table: "pages", column: "content_encoding") ? "content_encoding" : "''"
        let sql = "SELECT url, status, title, canonical, depth, response_time, size, redirects, content_type, page_type, \(aiCategory), h1, h1_count, word_count, internal_links, external_links, inlinks, page_weight, weight_status, ai_parsability, transport, original_status, cdp_status, verification_result, error, \(transferSize), \(contentEncoding) FROM pages ORDER BY rowid"
        return (manifest.startURL, loadRecords(from: handle, sql: sql))
    }

    private func loadLegacySession() -> (startURL: String, records: [CrawlRecord])? {
        let url = applicationSupportDirectory.appendingPathComponent("sessions.sqlite")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else { return nil }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT id, start_url FROM sessions ORDER BY id DESC LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let start = sqlite3_column_text(statement, 1) else { return nil }
        let sessionID = sqlite3_column_int64(statement, 0)
        var pages: OpaquePointer?
        let sql = "SELECT url, status, title, canonical, depth, response_time, size, redirects, content_type FROM pages WHERE session_id = ? ORDER BY rowid"
        guard sqlite3_prepare_v2(handle, sql, -1, &pages, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(pages) }
        sqlite3_bind_int64(pages, 1, sessionID)
        return (String(cString: start), loadRecords(from: pages))
    }

    private func loadRecords(from handle: OpaquePointer?, sql: String) -> [CrawlRecord] {
        var statement: OpaquePointer?
        guard let handle, sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        return decodeRecords(from: statement, detailed: true)
    }

    private func loadRecords(from statement: OpaquePointer?) -> [CrawlRecord] {
        decodeRecords(from: statement, detailed: false)
    }

    private func decodeRecords(from statement: OpaquePointer?, detailed: Bool) -> [CrawlRecord] {
        guard let statement else { return [] }
        var records: [CrawlRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(statement, 0), let url = URL(string: String(cString: pointer)) else { continue }
            var record = CrawlRecord(url: url)
            let status = Int(sqlite3_column_int(statement, 1)); record.statusCode = status == 0 ? nil : status
            if let value = sqlite3_column_text(statement, 2) { record.title = String(cString: value) }
            if let value = sqlite3_column_text(statement, 3) { record.canonical = String(cString: value) }
            record.depth = Int(sqlite3_column_int(statement, 4)); record.responseTime = sqlite3_column_double(statement, 5); record.size = Int(sqlite3_column_int64(statement, 6))
            if let value = sqlite3_column_text(statement, 7) { record.redirectSources = String(cString: value).split(separator: "|").compactMap { URL(string: String($0)) } }
            if let value = sqlite3_column_text(statement, 8), !String(cString: value).isEmpty { record.contentType = String(cString: value) }
            guard detailed else { records.append(record); continue }
            if let value = sqlite3_column_text(statement, 9) { record.pageType = String(cString: value) }
            if let value = sqlite3_column_text(statement, 10) { record.aiBustCategory = String(cString: value) }
            if let value = sqlite3_column_text(statement, 11) { record.h1 = String(cString: value) }
            record.h1Count = Int(sqlite3_column_int(statement, 12)); record.wordCount = Int(sqlite3_column_int(statement, 13))
            record.internalLinks = Int(sqlite3_column_int(statement, 14)); record.externalLinks = Int(sqlite3_column_int(statement, 15)); record.inlinks = Int(sqlite3_column_int(statement, 16))
            record.pageWeight = Int(sqlite3_column_int64(statement, 17))
            if let value = sqlite3_column_text(statement, 18) { record.weightStatus = String(cString: value) }
            if let value = sqlite3_column_text(statement, 19) { record.aiParsability = String(cString: value) }
            if let value = sqlite3_column_text(statement, 20) { record.transportUsed = String(cString: value) }
            let originalStatus = Int(sqlite3_column_int(statement, 21)); record.originalStatus = originalStatus == 0 ? nil : originalStatus
            let cdpStatus = Int(sqlite3_column_int(statement, 22)); record.cdpStatus = cdpStatus == 0 ? nil : cdpStatus
            if let value = sqlite3_column_text(statement, 23) { record.verificationResult = String(cString: value) }
            if let value = sqlite3_column_text(statement, 24) { record.error = String(cString: value) }
            record.transferredSize = Int(sqlite3_column_int64(statement, 25))
            if let value = sqlite3_column_text(statement, 26) { record.contentEncoding = String(cString: value) }
            records.append(record)
        }
        return records
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
