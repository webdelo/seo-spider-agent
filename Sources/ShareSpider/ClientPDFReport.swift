import Foundation
import AppKit
import CoreText

enum ClientPDFReport {
    /// A client-facing PDF with a branded cover, concise summary cards and
    /// actionable URL samples. Technical source data stays in the CSV exports.
    @MainActor static func export(report: AuditReport, records: [CrawlRecord], issues: [Issue], approvedVisualIDs: Set<UUID>, startURL: String) -> URL? {
        let url = ReportFileNaming.downloadsURL(for: startURL, report: "Audit")
        let changes = ProjectJournalStore.shared.materialChanges(startURL: startURL)
        return write(to: url, report: report, records: records, issues: issues, approvedVisualIDs: approvedVisualIDs, startURL: startURL, historyChanges: changes) ? url : nil
    }
    @discardableResult static func write(to url: URL, report: AuditReport, records: [CrawlRecord], issues: [Issue], approvedVisualIDs: Set<UUID> = [], startURL: String, historyChanges: [ProjectRunChange] = []) -> Bool {
        PDFRenderer(url: url, report: report, records: records, issues: issues, approvedVisualIDs: approvedVisualIDs, startURL: startURL, historyChanges: historyChanges).render()
    }
}

private final class PDFRenderer {
    private let page = CGRect(x: 0, y: 0, width: 595, height: 842)
    private let margin: CGFloat = 42
    private let purple = NSColor(calibratedRed: 0.31, green: 0.13, blue: 0.70, alpha: 1)
    private let ink = NSColor(calibratedWhite: 0.12, alpha: 1)
    private let muted = NSColor(calibratedWhite: 0.42, alpha: 1)
    private let pale = NSColor(calibratedRed: 0.95, green: 0.94, blue: 0.98, alpha: 1)
    private let report: AuditReport
    private let records: [CrawlRecord]
    private let issues: [Issue]
    private let approvedVisualIDs: Set<UUID>
    private let startURL: String
    private let historyChanges: [ProjectRunChange]
    private var context: CGContext!
    private var y: CGFloat = 0
    private var pageNumber = 0

    init(url: URL, report: AuditReport, records: [CrawlRecord], issues: [Issue], approvedVisualIDs: Set<UUID>, startURL: String, historyChanges: [ProjectRunChange]) {
        self.report = report; self.records = records; self.issues = issues
        self.approvedVisualIDs = approvedVisualIDs; self.startURL = startURL; self.historyChanges = historyChanges
        self.context = CGContext(url as CFURL, mediaBox: nil, nil)
    }

    func render() -> Bool {
        guard context != nil else { return false }
        beginPage(cover: true)
        cover()
        section("Technical overview")
        profileCards()
        if !historyChanges.isEmpty {
            section("Changes since previous check")
            for change in historyChanges.prefix(12) {
                let direction = change.current > change.previous ? "increased" : "decreased"
                paragraph("\(change.issue): \(change.previous) → \(change.current) (\(direction) \(abs(change.percentage))%).", color: change.current > change.previous ? .systemRed : .systemGreen)
            }
        }
        section("Priority findings")
        let findings = report.findings.sorted { severityWeight($0.severity) > severityWeight($1.severity) }
        if findings.isEmpty { paragraph("No critical configuration findings were generated for this crawl.", color: muted) }
        for finding in findings { findingCard(finding) }
        section("Crawl findings")
        if issues.isEmpty { paragraph("No crawl issues were found in the analysed URL set.", color: muted) }
        for issue in issues.sorted(by: { severityWeight($0.priority) > severityWeight($1.priority) }) { issueCard(issue) }
        section("Review status")
        paragraph("Confirmed visual findings selected for the future visual appendix: \(approvedVisualIDs.count).", color: muted)
        footer()
        context.endPDFPage(); context.closePDF()
        return true
    }

    private func beginPage(cover: Bool = false) {
        if pageNumber > 0 { context.endPDFPage() }
        context.beginPDFPage(nil); pageNumber += 1; y = page.height - margin
        if cover {
            context.setFillColor(purple.cgColor)
            context.fill(CGRect(x: 0, y: page.height - 178, width: page.width, height: 178))
        }
    }

    private func ensure(_ height: CGFloat) {
        if y - height < margin + 26 { footer(); beginPage() }
    }

    private func cover() {
        draw("SEO SPIDER AGENT", at: CGPoint(x: margin, y: page.height - 76), width: 380, font: .systemFont(ofSize: 13, weight: .bold), color: .white)
        draw("Technical Audit", at: CGPoint(x: margin, y: page.height - 124), width: 460, font: .systemFont(ofSize: 31, weight: .bold), color: .white)
        y = page.height - 214
        paragraph("Client-ready technical SEO assessment", font: .systemFont(ofSize: 15, weight: .medium), color: ink)
        paragraph(startURL, font: .systemFont(ofSize: 13, weight: .semibold), color: purple)
        paragraph("Generated \(Date().formatted(date: .long, time: .shortened)) · \(records.count) URLs analysed", font: .systemFont(ofSize: 10.5), color: muted, spacing: 16)
    }

    private func section(_ title: String) {
        ensure(34)
        y -= 9
        draw(title, at: CGPoint(x: margin, y: y - 19), width: page.width - margin * 2, font: .systemFont(ofSize: 17, weight: .bold), color: ink)
        y -= 31
    }

    private func profileCards() {
        let cards: [(String, String)] = [
            ("CMS", report.siteProfile.cmsName),
            ("IP address", report.siteProfile.ipAddresses.isEmpty ? "Not resolved" : report.siteProfile.ipAddresses.joined(separator: ", ")),
            ("Ahrefs DR", report.siteProfile.domainRating.map { String(format: "%.1f / 100", $0) } ?? "Unavailable")
        ]
        let width = (page.width - margin * 2 - 16) / 3
        ensure(82); y -= 4
        for (index, item) in cards.enumerated() {
            let x = margin + CGFloat(index) * (width + 8)
            context.setFillColor(pale.cgColor); context.fill(CGRect(x: x, y: y - 62, width: width, height: 62).insetBy(dx: 0, dy: 0))
            draw(item.0.uppercased(), at: CGPoint(x: x + 10, y: y - 18), width: width - 20, font: .systemFont(ofSize: 8.5, weight: .bold), color: muted)
            draw(item.1, at: CGPoint(x: x + 10, y: y - 43), width: width - 20, font: .systemFont(ofSize: 11.5, weight: .semibold), color: ink)
        }
        y -= 76
    }

    private func findingCard(_ finding: AuditFinding) {
        let title = "\(finding.severity.uppercased()) · \(finding.title)"
        let textHeight = height(title, width: page.width - margin * 2 - 28, font: .systemFont(ofSize: 12.5, weight: .bold)) + height(finding.detail, width: page.width - margin * 2 - 28, font: .systemFont(ofSize: 10.5)) + 30
        ensure(textHeight + 10)
        let tint = severityColor(finding.severity)
        context.setFillColor(NSColor(calibratedWhite: 0.975, alpha: 1).cgColor)
        context.fill(CGRect(x: margin, y: y - textHeight, width: page.width - margin * 2, height: textHeight))
        context.setFillColor(tint.cgColor); context.fill(CGRect(x: margin, y: y - textHeight, width: 5, height: textHeight))
        draw(title, at: CGPoint(x: margin + 15, y: y - 18), width: page.width - margin * 2 - 28, font: .systemFont(ofSize: 12.5, weight: .bold), color: tint)
        draw(finding.detail, at: CGPoint(x: margin + 15, y: y - 37), width: page.width - margin * 2 - 28, font: .systemFont(ofSize: 10.5), color: muted)
        y -= textHeight + 9
    }

    private func issueCard(_ issue: Issue) {
        let examples = records.filter { issue.urlIDs.contains($0.id) }.prefix(10).map(\.url.absoluteString)
        let intro = "\(issue.priority.uppercased()) · \(issue.name) · \(issue.count) URL\(issue.count == 1 ? "" : "s")"
        let explanation = issueExplanation(issue.name)
        let exampleText = examples.isEmpty ? "No representative URLs recorded." : examples.map { "• \($0)" }.joined(separator: "\n")
        let boxHeight = 46 + height(explanation, width: page.width - margin * 2 - 30, font: .systemFont(ofSize: 9.5)) + height(exampleText, width: page.width - margin * 2 - 30, font: .monospacedSystemFont(ofSize: 8.5, weight: .regular)) + 14
        ensure(boxHeight + 10)
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: margin, y: y - boxHeight, width: page.width - margin * 2, height: boxHeight))
        context.setStrokeColor(NSColor(calibratedWhite: 0.87, alpha: 1).cgColor); context.stroke(CGRect(x: margin, y: y - boxHeight, width: page.width - margin * 2, height: boxHeight))
        draw(intro, at: CGPoint(x: margin + 12, y: y - 19), width: page.width - margin * 2 - 24, font: .systemFont(ofSize: 11, weight: .bold), color: severityColor(issue.priority))
        draw(explanation, at: CGPoint(x: margin + 12, y: y - 35), width: page.width - margin * 2 - 24, font: .systemFont(ofSize: 9.5), color: muted)
        let explanationHeight = height(explanation, width: page.width - margin * 2 - 24, font: .systemFont(ofSize: 9.5))
        draw(exampleText, at: CGPoint(x: margin + 12, y: y - 40 - explanationHeight), width: page.width - margin * 2 - 24, font: .monospacedSystemFont(ofSize: 8.5, weight: .regular), color: muted)
        y -= boxHeight + 9
    }

    private func issueExplanation(_ name: String) -> String {
        switch name {
        case "Internal server/client errors": return "Why it matters: 4xx and 5xx pages cannot reliably serve visitors or search engines. Fix the source link, restore the page, or use a relevant 301 redirect when a replacement exists."
        case "Internal redirects (3xx)": return "Why it matters: internal links that first redirect waste crawl budget and slow navigation. Replace them with direct links to the final 200 URL."
        case "Broken image resources": return "Why it matters: broken images reduce user trust and can harm image search visibility. Restore the file or replace the image URL in the page template."
        case "Heavy image resources": return "Why it matters: oversized images slow page loading and can negatively affect Core Web Vitals. Resize, compress, and prefer WebP or AVIF where appropriate."
        case "Missing page title": return "Why it matters: a missing title gives search engines little information about the page topic. Add a unique, concise title for every indexable page."
        case "Missing meta description": return "Why it matters: a description helps control the search-result snippet. Add a useful, unique summary for indexable pages where it is absent."
        case "Title too long": return "Why it matters: long titles can be truncated in search results. Keep the main topic and make the title more concise."
        case "Title too short": return "Why it matters: a very short title may not communicate the page topic. Expand it with a unique, descriptive phrase."
        case "Missing H1": return "Why it matters: an H1 clarifies the primary topic and page structure. Add one descriptive H1 that matches the user intent."
        case "Missing canonical": return "Why it matters: without a canonical, duplicate versions can compete in indexing. Declare the preferred absolute URL in the HTML head."
        case "Images without alt text": return "Why it matters: missing alternative text harms accessibility and reduces image-search context. Add concise, meaningful alt text for informative images."
        case "Orphan pages", "Pages without internal inlinks": return "Why it matters: pages without internal links are difficult for visitors and crawlers to discover. Add relevant navigational or contextual links where appropriate."
        default: return "Why it matters: review the affected URLs and apply a consistent technical SEO fix before including this item in the client action plan."
        }
    }

    private func paragraph(_ text: String, font: NSFont = .systemFont(ofSize: 10.5), color: NSColor, spacing: CGFloat = 7) {
        let h = height(text, width: page.width - margin * 2, font: font)
        ensure(h + spacing)
        draw(text, at: CGPoint(x: margin, y: y - h), width: page.width - margin * 2, font: font, color: color)
        y -= h + spacing
    }

    private func draw(_ string: String, at point: CGPoint, width: CGFloat, font: NSFont, color: NSColor) {
        var baseline = point.y
        context.saveGState()
        context.textMatrix = .identity
        for item in wrappedLines(string, width: width, font: font) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: item, attributes: [.font: font, .foregroundColor: color]))
            var ascent: CGFloat = 0; var descent: CGFloat = 0; var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            baseline -= ascent
            context.textPosition = CGPoint(x: point.x, y: baseline)
            CTLineDraw(line, context)
            baseline -= descent + leading + max(2, font.pointSize * 0.16)
        }
        context.restoreGState()
    }

    private func height(_ string: String, width: CGFloat, font: NSFont) -> CGFloat {
        CGFloat(wrappedLines(string, width: width, font: font).count) * lineHeight(font)
    }

    private func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading + max(2, font.pointSize * 0.16)) }
    /// URLs and identifiers remain a single visual line. Overlong tokens are
    /// truncated with an ellipsis instead of being split in the middle.
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

    private func footer() {
        let text = "ShareSpider · Technical SEO Audit · Page \(pageNumber)"
        draw(text, at: CGPoint(x: margin, y: 23), width: page.width - margin * 2, font: .systemFont(ofSize: 8.5), color: muted)
    }

    private func severityWeight(_ value: String) -> Int { value == "High" ? 3 : value == "Medium" ? 2 : 1 }
    private func severityColor(_ value: String) -> NSColor { value == "High" ? .systemRed : value == "Medium" ? .systemOrange : purple }
}
