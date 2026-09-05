import Foundation
import AppKit
import CoreText

enum TechnicalTaskPDFReport {
    enum Severity: String, CaseIterable, Identifiable, Codable { case high = "High", highMedium = "High + Medium", all = "All"; var id: String { rawValue }
        func includes(_ value: String) -> Bool { switch self { case .high: return value == "High"; case .highMedium: return value == "High" || value == "Medium"; case .all: return true } }
    }

    @MainActor static func export(records: [CrawlRecord], issues: [Issue], startURL: String, severity: Severity) -> URL? {
        let url = ReportFileNaming.downloadsURL(for: startURL, report: "Technical-Tasks")
        return write(to: url, records: records, issues: issues, startURL: startURL, severity: severity) ? url : nil
    }

    @discardableResult static func write(to url: URL, records: [CrawlRecord], issues: [Issue], startURL: String, severity: Severity) -> Bool {
        TechnicalTaskRenderer(url: url, records: records, issues: issues, startURL: startURL, severity: severity).render()
    }
}

private final class TechnicalTaskRenderer {
    private let page = CGRect(x: 0, y: 0, width: 595, height: 842)
    private let margin: CGFloat = 38
    private let records: [CrawlRecord]; private let issues: [Issue]; private let startURL: String; private let severity: TechnicalTaskPDFReport.Severity
    private var context: CGContext!; private var y: CGFloat = 0; private var pageNumber = 0
    private let ink = NSColor(calibratedWhite: 0.10, alpha: 1); private let muted = NSColor(calibratedWhite: 0.40, alpha: 1); private let purple = NSColor(calibratedRed: 0.31, green: 0.13, blue: 0.70, alpha: 1)

    init(url: URL, records: [CrawlRecord], issues: [Issue], startURL: String, severity: TechnicalTaskPDFReport.Severity) {
        self.records = records; self.issues = issues; self.startURL = startURL; self.severity = severity; context = CGContext(url as CFURL, mediaBox: nil, nil)
    }
    func render() -> Bool {
        guard context != nil else { return false }
        newPage(cover: true)
        text("SEO SPIDER AGENT", x: margin, top: page.height - 58, width: 500, font: .systemFont(ofSize: 12, weight: .bold), color: .white)
        text("Technical tasks", x: margin, top: page.height - 106, width: 500, font: .systemFont(ofSize: 30, weight: .bold), color: .white)
        y = page.height - 205
        paragraph("Implementation specification for SEO and development teams", font: .systemFont(ofSize: 15, weight: .medium), color: ink)
        paragraph("Site: \(startURL)", font: .systemFont(ofSize: 11.5, weight: .semibold), color: purple)
        paragraph("Scope: \(severity.rawValue) priority · Generated \(Date().formatted(date: .long, time: .shortened))", color: muted, after: 18)
        let chosen = issues.filter { severity.includes($0.priority) }.sorted { weight($0.priority) > weight($1.priority) }
        heading("Tasks for implementation")
        if chosen.isEmpty { paragraph("No issues match the selected priority filter.", color: muted) }
        for issue in chosen { issueBlock(issue) }
        footer(); context.endPDFPage(); context.closePDF(); return true
    }
    private func newPage(cover: Bool = false) {
        if pageNumber > 0 { context.endPDFPage() }
        context.beginPDFPage(nil); pageNumber += 1; y = page.height - margin
        if cover { context.setFillColor(purple.cgColor); context.fill(CGRect(x: 0, y: page.height - 165, width: page.width, height: 165)) }
    }
    private func heading(_ value: String) { ensure(34); text(value, x: margin, top: y, width: page.width - margin * 2, font: .systemFont(ofSize: 17, weight: .bold), color: ink); y -= 31 }
    private func issueBlock(_ issue: Issue) {
        let affected = records.filter { issue.urlIDs.contains($0.id) }.prefix(10)
        let title = "\(issue.priority.uppercased()) · \(issue.name) · \(issue.count) URL\(issue.count == 1 ? "" : "s")"
        let instruction = instructionFor(issue.name)
        let sampleLines = affected.flatMap { taskLines(for: $0, issue: issue.name) }.joined(separator: "\n")
        let body = instruction + "\n\nExamples (up to 10):\n" + (sampleLines.isEmpty ? "No examples retained." : sampleLines)
        let width = page.width - margin * 2 - 26; let height = measured(title, width: width, font: .systemFont(ofSize: 12.5, weight: .bold)) + measured(body, width: width, font: .systemFont(ofSize: 9.2)) + 35
        ensure(height + 10)
        let tint = issue.priority == "High" ? NSColor.systemRed : issue.priority == "Medium" ? NSColor.systemOrange : purple
        context.setFillColor(NSColor(calibratedWhite: 0.975, alpha: 1).cgColor); context.fill(CGRect(x: margin, y: y - height, width: page.width - margin * 2, height: height))
        context.setFillColor(tint.cgColor); context.fill(CGRect(x: margin, y: y - height, width: 5, height: height))
        text(title, x: margin + 14, top: y - 5, width: width, font: .systemFont(ofSize: 12.5, weight: .bold), color: tint)
        text(body, x: margin + 14, top: y - 26, width: width, font: .systemFont(ofSize: 9.2), color: muted)
        y -= height + 9
    }
    private func taskLines(for record: CrawlRecord, issue: String) -> [String] {
        var lines = ["• Problem URL: \(record.url.absoluteString)"]
        if let source = record.foundOnURLs.first {
            let anchor = records.first(where: { $0.url == source })?.outgoingLinks.first(where: { $0.url == record.url.absoluteString })?.anchor ?? "(anchor not retained)"
            lines.append("  Found on: \(source.absoluteString) · Anchor: \(anchor)")
        }
        if issue.localizedCaseInsensitiveContains("redirect") {
            let chain = record.redirectChain.isEmpty ? [record.url] + (record.redirectURL.map { [$0] } ?? []) : record.redirectChain
            if !chain.isEmpty { lines.append("  Redirect chain: \(chain.map(\.absoluteString).joined(separator: " → "))") }
        }
        if issue.localizedCaseInsensitiveContains("hreflang") && !record.hreflangTargets.isEmpty { lines.append("  Hreflang: \(record.hreflangTargets.map { "\($0.code): \($0.url)" }.joined(separator: "; "))") }
        if issue.localizedCaseInsensitiveContains("image") { let bad = record.images.filter { $0.alt.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(3).map(\.url); if !bad.isEmpty { lines.append("  Image: \(bad.joined(separator: ", "))") } }
        return lines
    }
    private func instructionFor(_ issue: String) -> String {
        if issue.localizedCaseInsensitiveContains("server/client") { return "Action: restore the target page, correct every internal link, or add a relevant 301 redirect. Verify the final destination returns 200." }
        if issue.localizedCaseInsensitiveContains("redirect") { return "Action: replace internal links with the final 200 URL. Remove redirect chains and repair redirects that lead to an error, loop, or wrong destination." }
        if issue.localizedCaseInsensitiveContains("hreflang") { return "Action: use absolute canonical URLs, add a reciprocal hreflang on the target page, and ensure every alternate returns 200 and is indexable." }
        if issue.localizedCaseInsensitiveContains("image") { return "Action: restore or replace the image URL. For missing alt text, add a concise descriptive alt attribute on the source page." }
        if issue.localizedCaseInsensitiveContains("canonical") { return "Action: add one absolute canonical URL in the HTML head pointing to the preferred indexable version." }
        return "Action: correct the affected pages consistently, then re-crawl the site to confirm that the issue count is zero."
    }
    private func paragraph(_ value: String, font: NSFont = .systemFont(ofSize: 10.5), color: NSColor, after: CGFloat = 7) { let h = measured(value, width: page.width - margin * 2, font: font); ensure(h + after); text(value, x: margin, top: y, width: page.width - margin * 2, font: font, color: color); y -= h + after }
    private func ensure(_ height: CGFloat) { if y - height < margin + 25 { footer(); newPage() } }
    private func text(_ string: String, x: CGFloat, top: CGFloat, width: CGFloat, font: NSFont, color: NSColor) {
        var baseline = top
        context.saveGState(); context.textMatrix = .identity
        for item in wrappedLines(string, width: width, font: font) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: item, attributes: [.font: font, .foregroundColor: color]))
            var ascent: CGFloat = 0; var descent: CGFloat = 0; var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            baseline -= ascent; context.textPosition = CGPoint(x: x, y: baseline); CTLineDraw(line, context)
            baseline -= descent + leading + max(2, font.pointSize * 0.16)
        }
        context.restoreGState()
    }
    private func measured(_ value: String, width: CGFloat, font: NSFont) -> CGFloat { CGFloat(wrappedLines(value, width: width, font: font).count) * lineHeight(font) }
    private func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading + max(2, font.pointSize * 0.16)) }
    private func wrappedLines(_ string: String, width: CGFloat, font: NSFont) -> [String] {
        func measure(_ value: String) -> CGFloat { (value as NSString).size(withAttributes: [.font: font]).width }
        func ellipsize(_ value: String) -> String { var result = ""; for character in value { if measure(result + String(character) + "…") > width { break }; result.append(character) }; return result.isEmpty ? "…" : result + "…" }
        return string.components(separatedBy: .newlines).flatMap { paragraph in
            guard !paragraph.isEmpty else { return [""] }
            var output: [String] = []; var current = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
                let candidate = current.isEmpty ? word : current + " " + word
                if measure(candidate) <= width { current = candidate }
                else { if !current.isEmpty { output.append(current) }; current = measure(word) <= width ? word : ellipsize(word) }
            }
            if !current.isEmpty { output.append(current) }; return output
        }
    }
    private func footer() { text("ShareSpider · Technical task · Page \(pageNumber)", x: margin, top: 23, width: page.width - margin * 2, font: .systemFont(ofSize: 8.5), color: muted) }
    private func weight(_ value: String) -> Int { value == "High" ? 3 : value == "Medium" ? 2 : 1 }
}
