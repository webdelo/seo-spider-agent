import Foundation

/// Imports the mobile Core Web Vitals property report from the signed-in
/// ShareSpider Chrome profile. It never replaces URL Inspection data.
@MainActor
final class ChromeGSCCoreWebVitalsSync {
    static let shared = ChromeGSCCoreWebVitalsSync(); private init() {}
    private var statusTask: Task<Void, Never>?
    private var root: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ShareSpider/gsc-chrome", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private var output: URL { root.appendingPathComponent("gsc-core-web-vitals-export.csv") }
    private var status: URL { root.appendingPathComponent("gsc-core-web-vitals-status.json") }
    func start(target: String, progress: @escaping @MainActor (String, Int, Int) -> Void, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        guard let resources = Bundle.main.resourceURL else { completion(.failure(Error.unavailable)); return }
        let helper = resources.appendingPathComponent("SEOSpiderAgent_ShareSpider.bundle/gsc-chrome-core-web-vitals-export.mjs")
        guard FileManager.default.fileExists(atPath: helper.path) else { completion(.failure(Error.unavailable)); return }
        try? FileManager.default.removeItem(at: output); try? FileManager.default.removeItem(at: status)
        progress("Opening mobile Core Web Vitals in Chrome", 1, 3)
        let process = Process()
        let node = ChromeGSCPageIndexingSync.nodeLaunch()
        process.executableURL = node.executableURL
        process.arguments = node.argumentsPrefix + [helper.path, "--target", target, "--output", output.path, "--status", status.path]
        process.environment = ChromeGSCPageIndexingSync.playwrightEnvironment()
        let stderr = Pipe(); process.standardError = stderr
        do { try process.run() } catch { completion(.failure(Error.failed(error.localizedDescription))); return }
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let current = self?.readStatus() {
                    progress(current.message, current.state == "completed" ? 3 : 2, 3)
                }
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
        process.terminationHandler = { [weak self] task in
            let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusTask?.cancel()
                self.statusTask = nil
                guard task.terminationStatus == 0, let csv = try? String(contentsOf: self.output), !csv.isEmpty else { completion(.failure(Error.failed(error.isEmpty ? self.statusText : error))); return }
                progress("Mobile Core Web Vitals report received", 3, 3); completion(.success(csv))
            }
        }
    }
    private var statusText: String { readStatus()?.message ?? "Chrome did not return a Core Web Vitals report." }
    private func readStatus() -> (state: String, message: String)? {
        guard let data = try? Data(contentsOf: status),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String else { return nil }
        return (object["state"] as? String ?? "running", message)
    }
    enum Error: LocalizedError { case unavailable, failed(String); var errorDescription: String? { switch self { case .unavailable: "The local Chrome Core Web Vitals helper is unavailable."; case .failed(let message): message } } }
}
