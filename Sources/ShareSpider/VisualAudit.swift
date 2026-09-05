import Foundation
import WebKit
import AppKit

struct VisualIssue: Identifiable {
    let id = UUID()
    var type: String
    var detail: String
    var viewport: String
    var selector: String
    /// Coordinates are relative to the complete document, not the visible viewport.
    var x: Double
    var y: Double
    var width: Double = 0
    var height: Double = 0
    var source = "WebKit heuristic"
    var evidencePath = ""
}

struct VisualAuditResult: Identifiable {
    let id = UUID()
    var url: URL
    var viewport: String
    var issues: [VisualIssue]
    var screenshotPath: String
    var previewPath: String = ""
    var error: String
    var screenshotWidth: Double = 0
    var screenshotHeight: Double = 0
    var aiStatus = "AI analysis was not requested"
    var usedLocalModel = false
    var blocks: [VisualBlock] = []
    var comparisonSummary = ""
}

struct VisualBlock: Identifiable {
    let id = UUID()
    var screenshotPath: String
    var index: Int
    var verdict: String
    var detail: String
    var issues: [VisualIssue]
    var source: String
}

/// A human-readable checkpoint emitted while a visual audit is running. Block
/// inference is intentionally serial so Ollama does not run out of memory.
struct VisualAuditProgress: Equatable {
    var pageIndex: Int
    var pageCount: Int
    var url: URL
    var viewport: String
    var stage: String
    var blockIndex: Int? = nil
    var blockCount: Int? = nil

    var description: String {
        var value = "Page \(pageIndex) of \(pageCount) · \(viewport) · \(stage)"
        if let blockIndex, let blockCount { value += " · block \(blockIndex) of \(blockCount)" }
        return value
    }
}

private struct VisualSnapshot {
    var path: String
    var width: Double
    var height: Double
    var segments: [VisualSegment] = []
}

private struct VisualSegment { var top: Int; var path: String; var image: NSImage }

@MainActor
final class WebKitVisualAudit: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var webView: WKWebView?

    private let localVision: LocalVisionSettings
    private let pageLimit: Int
    private let onProgress: (VisualAuditProgress) -> Void

    init(localVision: LocalVisionSettings = .load(), pageLimit: Int = 1, onProgress: @escaping (VisualAuditProgress) -> Void = { _ in }) {
        self.localVision = localVision
        self.pageLimit = max(1, pageLimit)
        self.onProgress = onProgress
        super.init()
    }

    func run(_ records: [CrawlRecord]) async -> [VisualAuditResult] {
        let priority = ["Homepage", "Service", "Product", "Category", "Article", "FAQ", "Legal", "Contact", "Doctor", "Listing"]
        var chosen: [CrawlRecord] = []
        for type in priority {
            if let page = records.first(where: { $0.isSEOPage && $0.pageType == type }) { chosen.append(page) }
        }
        if chosen.isEmpty { chosen = Array(records.filter(\.isSEOPage).prefix(5)) }

        var results: [VisualAuditResult] = []
        let pages = Array(chosen.prefix(pageLimit))
        for (index, page) in pages.enumerated() {
            var desktop = await inspect(page.url, width: 1440, height: 900, label: "Desktop", pageIndex: index + 1, pageCount: pages.count)
            var mobile = await inspect(page.url, width: 390, height: 844, label: "Mobile", pageIndex: index + 1, pageCount: pages.count)
            onProgress(VisualAuditProgress(pageIndex: index + 1, pageCount: pages.count, url: page.url, viewport: "Desktop + Mobile", stage: "comparing the two versions"))
            let comparison = await LocalVisualModel.compare(desktop: desktop.screenshotPath, mobile: mobile.screenshotPath, settings: localVision)
            desktop.comparisonSummary = comparison
            mobile.comparisonSummary = comparison
            results.append(desktop)
            results.append(mobile)
        }
        return results
    }

    private func inspect(_ url: URL, width: CGFloat, height: CGFloat, label: String, pageIndex: Int, pageCount: Int) async -> VisualAuditResult {
        onProgress(VisualAuditProgress(pageIndex: pageIndex, pageCount: pageCount, url: url, viewport: label, stage: "loading and rendering"))
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Start wide, then explicitly reload after switching to the mobile viewport. Some sites
        // initialise responsive components or server-side variants only during a new navigation.
        let initialWidth: CGFloat = label == "Mobile" ? 1440 : width
        let initialHeight: CGFloat = label == "Mobile" ? 900 : height
        let pageView = WKWebView(frame: CGRect(x: 0, y: 0, width: initialWidth, height: initialHeight), configuration: config)
        webView = pageView
        pageView.navigationDelegate = self

        do {
            try await load(url)
            if label == "Mobile" {
                pageView.frame = CGRect(x: 0, y: 0, width: width, height: height)
                pageView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
                try await load(url)
            }
            try? await Task.sleep(for: .seconds(1.5))
            _ = try? await evaluateJSONString("true")

            let script = """
            (() => {
              const w = innerWidth, d = document.documentElement, sy = scrollY, out = [];
              const add = (type, detail, e, r, selector) => out.push({
                type, detail, selector, x: r.left, y: r.top + sy, width: r.width, height: r.height
              });
              if (d.scrollWidth > w + 8) out.push({
                type: 'Horizontal overflow', detail: `Document width ${d.scrollWidth}px exceeds viewport ${w}px`,
                selector: 'html', x: 0, y: 0, width: w, height: 40
              });
              document.querySelectorAll('h1,h2,button,a,input,select,p,nav').forEach((e) => {
                const r = e.getBoundingClientRect(), s = getComputedStyle(e);
                if (s.display === 'none' || s.visibility === 'hidden' || e.getAttribute('aria-hidden') === 'true' || r.width < 1 || r.height < 1) return;
                const selector = e.tagName.toLowerCase() + (e.id ? '#' + e.id : '');
                if ((s.position === 'fixed' || s.position === 'sticky') && r.width * r.height > w * innerHeight * .3) {
                  add('Oversized overlay', 'Fixed/sticky element covers over 30% of viewport', e, r, selector);
                }
              });
              return out.slice(0, 30);
            })()
            """
            let rawJSON = try await evaluateJSONString(script)
            let raw = (try? JSONSerialization.jsonObject(with: Data(rawJSON.utf8))) as? [[String: Any]] ?? []
            let heuristicIssues = raw.map {
                VisualIssue(
                    type: $0["type"] as? String ?? "Layout",
                    detail: $0["detail"] as? String ?? "",
                    viewport: label,
                    selector: $0["selector"] as? String ?? "",
                    x: $0["x"] as? Double ?? 0,
                    y: $0["y"] as? Double ?? 0,
                    width: $0["width"] as? Double ?? 0,
                    height: $0["height"] as? Double ?? 0
                )
            }
            let previewPath = await viewportPreview(url, label: label)
            onProgress(VisualAuditProgress(pageIndex: pageIndex, pageCount: pageCount, url: url, viewport: label, stage: "capturing page blocks"))
            let snapshot = await fullPageSnapshot(url, label: label, viewportWidth: width, viewportHeight: height)
            var blocks: [VisualBlock] = []
            var allIssues: [VisualIssue] = []
            for (index, segment) in snapshot.segments.enumerated() {
                onProgress(VisualAuditProgress(pageIndex: pageIndex, pageCount: pageCount, url: url, viewport: label, stage: "analysing with local AI", blockIndex: index + 1, blockCount: snapshot.segments.count))
                let analysis = await LocalVisualModel.inspect(screenshotPath: segment.path, viewport: label, settings: localVision, pageWidth: segment.image.size.width, pageHeight: segment.image.size.height)
                let modelIssues = analysis.issues.map { issue -> VisualIssue in var copy = issue; copy.y += Double(segment.top); copy.evidencePath = segment.path; return copy }
                let segmentHeuristics = heuristicIssues.filter { $0.y >= Double(segment.top) && $0.y < Double(segment.top) + segment.image.size.height }.map { issue -> VisualIssue in var copy = issue; copy.evidencePath = segment.path; return copy }
                let issues = analysis.usedModel ? modelIssues + segmentHeuristics : segmentHeuristics
                let verdict = analysis.usedModel ? (issues.isEmpty ? "All good" : "Needs review") : "AI unavailable"
                let detail = analysis.usedModel ? (issues.isEmpty ? "The local model found no critical visual issue in this block." : issues.map(\.detail).joined(separator: " ")) : analysis.status
                blocks.append(VisualBlock(screenshotPath: segment.path, index: index + 1, verdict: verdict, detail: detail, issues: issues, source: analysis.usedModel ? "Local AI" : "WebKit fallback"))
                allIssues += issues
            }
            let status = blocks.first?.source == "Local AI" ? "Local AI analysed \(blocks.count) viewport blocks." : "AI unavailable; only reliable WebKit fallback checks are shown."
            return VisualAuditResult(url: url, viewport: label, issues: allIssues, screenshotPath: snapshot.path, previewPath: previewPath, error: "", screenshotWidth: snapshot.width, screenshotHeight: snapshot.height, aiStatus: status, usedLocalModel: blocks.first?.source == "Local AI", blocks: blocks)
        } catch {
            return VisualAuditResult(url: url, viewport: label, issues: [], screenshotPath: "", error: error.localizedDescription)
        }
    }

    private func load(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            guard let webView else {
                continuation.resume(throwing: URLError(.unknown))
                return
            }
            webView.load(URLRequest(url: url, timeoutInterval: 20))
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                if let c = self.continuation {
                    self.continuation = nil
                    c.resume(throwing: URLError(.timedOut))
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    /// The async SDK overlay crashes on macOS 15 when JavaScript evaluates to `undefined`.
    /// JSON serialisation converts WebKit's untyped optional result into a safe Swift String.
    private func evaluateJSONString(_ script: String) async throws -> String {
        guard let webView else { throw URLError(.unknown) }
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript("JSON.stringify((\(script)))") { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value as? String ?? "null")
                }
            }
        }
    }

    /// WKWebView only snapshots its visible viewport. Scroll and stitch every viewport to keep
    /// the screenshot and issue coordinates aligned with the complete document.
    private func fullPageSnapshot(_ url: URL, label: String, viewportWidth: CGFloat, viewportHeight: CGFloat) async -> VisualSnapshot {
        let rawHeight = Double((try? await evaluateJSONString("Math.max(document.body ? document.body.scrollHeight : 0, document.documentElement.scrollHeight, document.documentElement.offsetHeight)")) ?? "") ?? Double(viewportHeight)
        let pageHeight = max(Int(ceil(rawHeight)), Int(viewportHeight))
        let pageWidth = Int(viewportWidth)
        // Do not keep an NSGraphicsContext open across `await`: AppKit drops it while
        // WebKit is snapshotting, which previously produced an all-white PNG.
        var captured: [(top: Int, image: NSImage)] = []
        var top = 0
        while top < pageHeight {
            _ = try? await evaluateJSONString("(() => { window.scrollTo(0, \(top)); return true; })()")
            try? await Task.sleep(for: .milliseconds(100))
            if let webView, let image = try? await webView.takeSnapshot(configuration: nil) {
                captured.append((top, image))
            }
            top += Int(viewportHeight)
        }
        _ = try? await evaluateJSONString("(() => { window.scrollTo(0, 0); return true; })()")

        let canvas = NSImage(size: CGSize(width: pageWidth, height: pageHeight))
        canvas.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)).fill()
        for segment in captured {
            let capturedHeight = min(Int(viewportHeight), pageHeight - segment.top)
            let destination = CGRect(x: 0, y: pageHeight - segment.top - capturedHeight, width: pageWidth, height: capturedHeight)
            let source = CGRect(x: 0, y: max(0, segment.image.size.height - CGFloat(capturedHeight)), width: segment.image.size.width, height: CGFloat(capturedHeight))
            segment.image.draw(in: destination, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        canvas.unlockFocus()

        guard let data = canvas.tiffRepresentation,
              let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
            return VisualSnapshot(path: "", width: Double(pageWidth), height: Double(pageHeight))
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShareSpider/VisualAudit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(url.host ?? "page")-\(label)-\(UUID().uuidString).png")
        try? png.write(to: path)
        let segmentRecords = captured.compactMap { item -> VisualSegment? in
            guard let data = item.image.tiffRepresentation, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return nil }
            let segmentPath = dir.appendingPathComponent("\(url.host ?? "page")-\(label)-segment-\(item.top)-\(UUID().uuidString).png")
            try? png.write(to: segmentPath)
            return VisualSegment(top: item.top, path: segmentPath.path, image: item.image)
        }
        return VisualSnapshot(path: path.path, width: Double(pageWidth), height: Double(pageHeight), segments: segmentRecords)
    }

    /// Compact first-viewport preview for the grid; the full stitched image remains available in details.
    private func viewportPreview(_ url: URL, label: String) async -> String {
        guard let image = try? await webView?.takeSnapshot(configuration: nil),
              let data = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return "" }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShareSpider/VisualAudit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(url.host ?? "page")-\(label)-preview-\(UUID().uuidString).png")
        try? png.write(to: path)
        return path.path
    }

    private func evidence(for issue: VisualIssue, in segments: [VisualSegment]) -> VisualIssue {
        guard let segment = segments.last(where: { Double($0.top) <= issue.y }) ?? segments.first else { return issue }
        let relativeY = max(0, issue.y - Double(segment.top))
        let cropWidth = min(segment.image.size.width, max(260, issue.width + 80))
        let cropHeight = min(segment.image.size.height, max(180, issue.height + 100))
        let originX = max(0, min(segment.image.size.width - cropWidth, issue.x - 40))
        let topY = max(0, min(segment.image.size.height - cropHeight, relativeY - 50))
        let source = CGRect(x: originX, y: segment.image.size.height - topY - cropHeight, width: cropWidth, height: cropHeight)
        let output = NSImage(size: source.size)
        output.lockFocus()
        segment.image.draw(in: CGRect(origin: .zero, size: source.size), from: source, operation: .copy, fraction: 1)
        output.unlockFocus()
        guard let data = output.tiffRepresentation, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return issue }
        let path = URL(fileURLWithPath: segment.path).deletingLastPathComponent().appendingPathComponent("issue-\(UUID().uuidString).png")
        try? png.write(to: path)
        var result = issue
        result.evidencePath = path.path
        return result
    }
}
