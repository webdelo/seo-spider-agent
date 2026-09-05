import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@MainActor
final class SessionStore {
    static let shared = SessionStore(); private var db: OpaquePointer?
    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("ShareSpider", isDirectory: true); try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); sqlite3_open(directory.appendingPathComponent("sessions.sqlite").path, &db)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS sessions(id INTEGER PRIMARY KEY, created REAL, start_url TEXT); CREATE TABLE IF NOT EXISTS pages(session_id INTEGER, url TEXT, status INTEGER, title TEXT, canonical TEXT, depth INTEGER, response_time REAL, size INTEGER, redirects TEXT, content_type TEXT);", nil, nil, nil)
        // Existing installations have the original compact table.  Retain its
        // rows and add the response type needed to safely resume GSC checks.
        sqlite3_exec(db, "ALTER TABLE pages ADD COLUMN content_type TEXT", nil, nil, nil)
    }
    func save(startURL: String, records: [CrawlRecord]) {
        guard let db else { return }; var session: OpaquePointer?; sqlite3_prepare_v2(db, "INSERT INTO sessions(created,start_url) VALUES(?,?)", -1, &session, nil); sqlite3_bind_double(session, 1, Date().timeIntervalSince1970); sqlite3_bind_text(session, 2, startURL, -1, SQLITE_TRANSIENT); sqlite3_step(session); sqlite3_finalize(session); let id = sqlite3_last_insert_rowid(db)
        var page: OpaquePointer?; sqlite3_prepare_v2(db, "INSERT INTO pages(session_id,url,status,title,canonical,depth,response_time,size,redirects,content_type) VALUES(?,?,?,?,?,?,?,?,?,?)", -1, &page, nil)
        for r in records { sqlite3_reset(page); sqlite3_bind_int64(page, 1, id); sqlite3_bind_text(page, 2, r.url.absoluteString, -1, SQLITE_TRANSIENT); sqlite3_bind_int(page, 3, Int32(r.statusCode ?? 0)); sqlite3_bind_text(page, 4, r.title, -1, SQLITE_TRANSIENT); sqlite3_bind_text(page, 5, r.canonical, -1, SQLITE_TRANSIENT); sqlite3_bind_int(page, 6, Int32(r.depth)); sqlite3_bind_double(page, 7, r.responseTime); sqlite3_bind_int64(page, 8, Int64(r.size)); sqlite3_bind_text(page, 9, r.redirectSources.map(\.absoluteString).joined(separator: "|"), -1, SQLITE_TRANSIENT); sqlite3_bind_text(page, 10, r.contentType, -1, SQLITE_TRANSIENT); sqlite3_step(page) }; sqlite3_finalize(page)
    }

    /// A Search Console request must not force the user to crawl a site again
    /// after ShareSpider has been restarted. The stored fields are intentionally
    /// limited to the data needed to present the existing rows and inspect URLs.
    func latestSession() -> (startURL: String, records: [CrawlRecord])? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, start_url FROM sessions ORDER BY id DESC LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let startPointer = sqlite3_column_text(statement, 1) else { return nil }
        let sessionID = sqlite3_column_int64(statement, 0)
        let startURL = String(cString: startPointer)
        var pages: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT url, status, title, canonical, depth, response_time, size, redirects, content_type FROM pages WHERE session_id = ? ORDER BY rowid", -1, &pages, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(pages) }
        sqlite3_bind_int64(pages, 1, sessionID)
        var records: [CrawlRecord] = []
        while sqlite3_step(pages) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(pages, 0), let url = URL(string: String(cString: pointer)) else { continue }
            var record = CrawlRecord(url: url)
            let status = Int(sqlite3_column_int(pages, 1)); record.statusCode = status == 0 ? nil : status
            if let value = sqlite3_column_text(pages, 2) { record.title = String(cString: value) }
            if let value = sqlite3_column_text(pages, 3) { record.canonical = String(cString: value) }
            record.depth = Int(sqlite3_column_int(pages, 4)); record.responseTime = sqlite3_column_double(pages, 5); record.size = Int(sqlite3_column_int64(pages, 6))
            if let value = sqlite3_column_text(pages, 7) { record.redirectSources = String(cString: value).split(separator: "|").compactMap { URL(string: String($0)) } }
            if let value = sqlite3_column_text(pages, 8), !String(cString: value).isEmpty {
                record.contentType = String(cString: value)
            } else if record.statusCode.map({ (200..<300).contains($0) }) == true {
                // Historic sessions did not persist response type. Infer only
                // unmistakable binary files; successful extensionless URLs
                // with a canonical are the same HTML rows crawled earlier.
                let fileExtension = url.pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "ico", "bmp", "tif", "tiff"].contains(fileExtension) {
                    record.contentType = "image/\(fileExtension)"
                } else if fileExtension == "pdf" {
                    record.contentType = "application/pdf"
                } else if !record.canonical.isEmpty {
                    record.contentType = "text/html; restored-session"
                }
            }
            records.append(record)
        }
        return records.isEmpty ? nil : (startURL, records)
    }
}
