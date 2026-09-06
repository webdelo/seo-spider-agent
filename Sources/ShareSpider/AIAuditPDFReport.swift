import Foundation
import AppKit
import CoreText

enum AIAuditPDFReport {
    @MainActor static func export(report: AIAuditReport, startURL: String) -> URL? {
        let url = ReportFileNaming.downloadsURL(for: startURL, report: "AI-Audit")
        return AIAuditPDFRenderer(url: url, report: report).render() ? url : nil
    }
}

private final class AIAuditPDFRenderer {
    private let page = CGRect(x: 0, y: 0, width: 595, height: 842), margin: CGFloat = 42
    private let purple = NSColor(calibratedRed: 0.31, green: 0.13, blue: 0.70, alpha: 1), ink = NSColor(calibratedWhite: 0.12, alpha: 1), muted = NSColor(calibratedWhite: 0.42, alpha: 1)
    private let report: AIAuditReport
    private var context: CGContext!, y: CGFloat = 0, pageNumber = 0
    init(url: URL, report: AIAuditReport) { self.report = report; context = CGContext(url as CFURL, mediaBox: nil, nil) }

    func render() -> Bool {
        guard context != nil else { return false }
        beginPage(cover: true)
        draw("SEO SPIDER AGENT", x: margin, y: page.height - 76, width: 400, font: .systemFont(ofSize: 13, weight: .bold), color: .white)
        draw("AI SEO Audit", x: margin, y: page.height - 124, width: 460, font: .systemFont(ofSize: 31, weight: .bold), color: .white)
        y = page.height - 214
        paragraph("Client-ready analysis of crawl, backlink and Search Console data.", font: .systemFont(ofSize: 15, weight: .medium), color: ink)
        paragraph(report.siteURL, font: .systemFont(ofSize: 13, weight: .semibold), color: purple)
        paragraph("Generated \(report.generatedAt.formatted(date: .long, time: .shortened))", font: .systemFont(ofSize: 10.5), color: muted, spacing: 16)
        section("Executive summary"); paragraph(report.overallAssessment, color: ink)
        section("Data source summary"); summaryCards()
        section("Prioritized findings")
        if report.findings.isEmpty { paragraph("No high- or medium-priority findings were generated from the available data.", color: muted) }
        for finding in report.findings.sorted(by: { weight($0.severity) > weight($1.severity) }) { findingCard(finding) }
        footer(); context.endPDFPage(); context.closePDF(); return true
    }

    private func beginPage(cover: Bool = false) { if pageNumber > 0 { context.endPDFPage() }; context.beginPDFPage(nil); pageNumber += 1; y = page.height - margin; if cover { context.setFillColor(purple.cgColor); context.fill(CGRect(x: 0, y: page.height - 178, width: page.width, height: 178)) } }
    private func ensure(_ height: CGFloat) { if y - height < margin + 28 { footer(); beginPage() } }
    private func section(_ title: String) { ensure(34); y -= 9; draw(title, x: margin, y: y - 19, width: page.width - margin * 2, font: .systemFont(ofSize: 17, weight: .bold), color: ink); y -= 31 }
    private func summaryCards() {
        let crawl = report.crawlSummary, backlinks = report.backlinkSummary, gsc = report.searchConsoleSummary
        let cards = [("CRAWL", "\(crawl.totalURLs) URLs · \(crawl.errorCount) errors\n\(crawl.missingTitles) missing titles · \(crawl.missingCanonical) canonicals"), ("BACKLINKS", "DR \(backlinks.domainRank) · \(backlinks.totalBacklinks) links\n\(backlinks.referringDomains) referring domains · \(backlinks.brokenBacklinks) broken"), ("SEARCH CONSOLE", gsc.available ? "\(gsc.indexedPages) indexed · \(gsc.notIndexedPages) not indexed\n\(gsc.clicks7d) clicks · \(gsc.impressions7d) impressions" : "Unavailable\n\(gsc.unavailableReason)")]
        let width = (page.width - margin * 2 - 16) / 3; ensure(88); y -= 3
        for (i, card) in cards.enumerated() { let x = margin + CGFloat(i) * (width + 8); context.setFillColor(NSColor(calibratedRed: 0.95, green: 0.94, blue: 0.98, alpha: 1).cgColor); context.fill(CGRect(x: x, y: y - 68, width: width, height: 68)); draw(card.0, x: x + 9, y: y - 17, width: width - 18, font: .systemFont(ofSize: 8, weight: .bold), color: muted); draw(card.1, x: x + 9, y: y - 34, width: width - 18, font: .systemFont(ofSize: 8.5), color: ink) }
        y -= 80
    }
    private func findingCard(_ finding: AIAuditFinding) {
        let title = "\(finding.severity.uppercased()) · \(finding.category) · \(finding.title)"
        let urls = finding.affectedURLs.isEmpty ? "" : "Examples:\n" + finding.affectedURLs.prefix(5).map { "• \($0)" }.joined(separator: "\n")
        let recommendation = "Recommendation: \(finding.recommendation)"
        let width = page.width - margin * 2 - 28
        let boxHeight = 29 + height(title, width: width, font: .systemFont(ofSize: 12, weight: .bold)) + height(finding.summary, width: width, font: .systemFont(ofSize: 10)) + height(urls, width: width, font: .monospacedSystemFont(ofSize: 8, weight: .regular)) + height(recommendation, width: width, font: .systemFont(ofSize: 9.5, weight: .medium)) + 18
        ensure(boxHeight + 10); let top = y; context.setFillColor(NSColor(calibratedWhite: 0.975, alpha: 1).cgColor); context.fill(CGRect(x: margin, y: top - boxHeight, width: page.width - margin * 2, height: boxHeight)); context.setFillColor(color(finding.severity).cgColor); context.fill(CGRect(x: margin, y: top - boxHeight, width: 5, height: boxHeight))
        var cursor = top - 16
        draw(title, x: margin + 14, y: cursor, width: width, font: .systemFont(ofSize: 12, weight: .bold), color: color(finding.severity)); cursor -= height(title, width: width, font: .systemFont(ofSize: 12, weight: .bold)) + 3
        draw(finding.summary, x: margin + 14, y: cursor, width: width, font: .systemFont(ofSize: 10), color: muted); cursor -= height(finding.summary, width: width, font: .systemFont(ofSize: 10)) + 4
        if !urls.isEmpty { draw(urls, x: margin + 14, y: cursor, width: width, font: .monospacedSystemFont(ofSize: 8, weight: .regular), color: muted); cursor -= height(urls, width: width, font: .monospacedSystemFont(ofSize: 8, weight: .regular)) + 4 }
        draw(recommendation, x: margin + 14, y: cursor, width: width, font: .systemFont(ofSize: 9.5, weight: .medium), color: ink); y -= boxHeight + 9
    }
    private func paragraph(_ text: String, font: NSFont = .systemFont(ofSize: 10.5), color: NSColor, spacing: CGFloat = 7) { let h = height(text, width: page.width - margin * 2, font: font); ensure(h + spacing); draw(text, x: margin, y: y - h, width: page.width - margin * 2, font: font, color: color); y -= h + spacing }
    private func draw(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, font: NSFont, color: NSColor) { var baseline = y; context.saveGState(); context.textMatrix = .identity; for lineText in lines(text, width: width, font: font) { let line = CTLineCreateWithAttributedString(NSAttributedString(string: lineText, attributes: [.font: font, .foregroundColor: color])); var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0; CTLineGetTypographicBounds(line, &ascent, &descent, &leading); baseline -= ascent; context.textPosition = CGPoint(x: x, y: baseline); CTLineDraw(line, context); baseline -= descent + leading + max(2, font.pointSize * 0.16) }; context.restoreGState() }
    private func height(_ text: String, width: CGFloat, font: NSFont) -> CGFloat { CGFloat(lines(text, width: width, font: font).count) * lineHeight(font) }
    private func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading + max(2, font.pointSize * 0.16)) }
    private func lines(_ text: String, width: CGFloat, font: NSFont) -> [String] { func size(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }; return text.components(separatedBy: .newlines).flatMap { paragraph in guard !paragraph.isEmpty else { return [""] }; var result: [String] = [], current = ""; for word in paragraph.split(separator: " ").map(String.init) { let candidate = current.isEmpty ? word : current + " " + word; if size(candidate) <= width { current = candidate } else { if !current.isEmpty { result.append(current) }; current = word } }; if !current.isEmpty { result.append(current) }; return result } }
    private func footer() { draw("ShareSpider · AI SEO Audit · Page \(pageNumber)", x: margin, y: 23, width: page.width - margin * 2, font: .systemFont(ofSize: 8.5), color: muted) }
    private func weight(_ value: String) -> Int { value == "High" ? 3 : value == "Medium" ? 2 : 1 }
    private func color(_ severity: String) -> NSColor { severity == "High" ? .systemRed : severity == "Medium" ? .systemOrange : purple }
}
