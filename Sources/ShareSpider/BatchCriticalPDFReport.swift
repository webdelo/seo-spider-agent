import Foundation
import AppKit
import CoreText

/// One final document for a batch: one site heading followed by its High
/// priority problems. Individual audits retain all of the supporting detail.
enum BatchCriticalPDFReport {
    @discardableResult
    static func write(to url: URL, summaries: [BatchSiteCriticalSummary]) -> Bool {
        BatchCriticalRenderer(url: url, summaries: summaries).render()
    }
}

private final class BatchCriticalRenderer {
    private let page = CGRect(x: 0, y: 0, width: 595, height: 842)
    private let margin: CGFloat = 42
    private let purple = NSColor(calibratedRed: 0.31, green: 0.13, blue: 0.70, alpha: 1)
    private let ink = NSColor(calibratedWhite: 0.12, alpha: 1)
    private let muted = NSColor(calibratedWhite: 0.42, alpha: 1)
    private let summaries: [BatchSiteCriticalSummary]
    private var context: CGContext!
    private var y: CGFloat = 0
    private var pageNumber = 0

    init(url: URL, summaries: [BatchSiteCriticalSummary]) {
        self.summaries = summaries
        context = CGContext(url as CFURL, mediaBox: nil, nil)
    }

    func render() -> Bool {
        guard context != nil else { return false }
        newPage(cover: true)
        draw("SEO SPIDER AGENT", x: margin, top: page.height - 58, width: 500, font: .systemFont(ofSize: 12, weight: .bold), color: .white)
        draw("Batch critical issues", x: margin, top: page.height - 106, width: 500, font: .systemFont(ofSize: 29, weight: .bold), color: .white)
        y = page.height - 205
        paragraph("Consolidated priority list across \(summaries.count) site\(summaries.count == 1 ? "" : "s"). Only High priority crawl and technical-audit findings are included.", font: .systemFont(ofSize: 14, weight: .medium), color: ink)
        paragraph("Generated \(Date().formatted(date: .long, time: .shortened))", color: muted, after: 18)
        for site in summaries.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { siteBlock(site) }
        footer(); context.endPDFPage(); context.closePDF()
        return true
    }

    private func newPage(cover: Bool = false) {
        if pageNumber > 0 { context.endPDFPage() }
        context.beginPDFPage(nil); pageNumber += 1; y = page.height - margin
        if cover { context.setFillColor(purple.cgColor); context.fill(CGRect(x: 0, y: page.height - 165, width: page.width, height: 165)) }
    }

    private func siteBlock(_ site: BatchSiteCriticalSummary) {
        let title = site.name
        let siteURL = site.url
        let issueLines: String
        if site.issues.isEmpty {
            issueLines = "No High priority issues were found in this completed crawl."
        } else {
            issueLines = site.issues.map { issue in
                let sample = issue.examples.isEmpty ? "" : "\nExamples: \(issue.examples.prefix(3).joined(separator: ", "))"
                return "• \(issue.title) — \(issue.count) URL\(issue.count == 1 ? "" : "s")\(sample)"
            }.joined(separator: "\n\n")
        }
        let width = page.width - margin * 2 - 26
        let bodyHeight = measured(issueLines, width: width, font: .systemFont(ofSize: 9.5))
        let height = 56 + bodyHeight + 20
        ensure(height + 14)
        context.setFillColor(NSColor(calibratedWhite: 0.975, alpha: 1).cgColor)
        context.fill(CGRect(x: margin, y: y - height, width: page.width - margin * 2, height: height))
        context.setFillColor((site.issues.isEmpty ? NSColor.systemGreen : NSColor.systemRed).cgColor)
        context.fill(CGRect(x: margin, y: y - height, width: 5, height: height))
        draw(title, x: margin + 14, top: y - 7, width: width, font: .systemFont(ofSize: 14, weight: .bold), color: ink)
        draw(siteURL, x: margin + 14, top: y - 29, width: width, font: .systemFont(ofSize: 9.8), color: purple)
        draw(issueLines, x: margin + 14, top: y - 52, width: width, font: .systemFont(ofSize: 9.5), color: muted)
        y -= height + 10
    }

    private func paragraph(_ value: String, font: NSFont = .systemFont(ofSize: 10.5), color: NSColor, after: CGFloat = 7) {
        let h = measured(value, width: page.width - margin * 2, font: font)
        ensure(h + after)
        draw(value, x: margin, top: y, width: page.width - margin * 2, font: font, color: color)
        y -= h + after
    }

    private func ensure(_ height: CGFloat) { if y - height < margin + 25 { footer(); newPage() } }
    private func footer() { draw("ShareSpider · Batch critical issues · Page \(pageNumber)", x: margin, top: 23, width: page.width - margin * 2, font: .systemFont(ofSize: 8.5), color: muted) }
    private func measured(_ string: String, width: CGFloat, font: NSFont) -> CGFloat {
        CGFloat(wrappedLines(string, width: width, font: font).count) * lineHeight(font)
    }
    private func draw(_ string: String, x: CGFloat, top: CGFloat, width: CGFloat, font: NSFont, color: NSColor) {
        var baseline = top
        context.saveGState(); context.textMatrix = .identity
        for value in wrappedLines(string, width: width, font: font) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color]))
            var ascent: CGFloat = 0; var descent: CGFloat = 0; var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            baseline -= ascent; context.textPosition = CGPoint(x: x, y: baseline); CTLineDraw(line, context)
            baseline -= descent + leading + max(2, font.pointSize * 0.16)
        }
        context.restoreGState()
    }
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
}
