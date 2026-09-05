import Foundation

/// Google does not expose the Search Console **Links** report through its
/// public API.  This small importer keeps that report separate from
/// DataForSEO: a CSV exported from Search Console is evidence that Google has
/// observed a donor, while DataForSEO remains the source of active/lost link
/// status and page-level facts.
struct GSCBacklinkImport: Codable, Hashable, Sendable {
    var target = ""
    var importedAt = Date()
    var donors: [GSCBacklinkDonor] = []
}

struct GSCBacklinkDonor: Codable, Hashable, Identifiable, Sendable {
    var sourceDomain = ""
    var sourceURL = ""
    var targetURL = ""
    var links = 0
    var id: String { "\(sourceDomain)|\(sourceURL)|\(targetURL)" }
}

struct GSCBacklinkComparison: Sendable {
    var gscDomains = 0
    var dataForSEOActiveDomains = 0
    var confirmedDomains = 0
    var gscOnlyDomains: [String] = []
    var dataForSEOOnlyDomains: [String] = []

    var confirmationPercent: Int {
        guard dataForSEOActiveDomains > 0 else { return 0 }
        return Int((Double(confirmedDomains) / Double(dataForSEOActiveDomains) * 100).rounded())
    }
}

enum GSCBacklinkImportService {
    private static var directory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShareSpider/gsc-backlinks", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func load(target: String) -> GSCBacklinkImport? {
        guard let data = try? Data(contentsOf: cacheURL(target: target)) else { return nil }
        return try? JSONDecoder().decode(GSCBacklinkImport.self, from: data)
    }

    static func importCSV(_ source: String, target: String) throws -> GSCBacklinkImport {
        let rows = parseCSV(source).filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        guard let header = rows.first else { throw ImportError.emptyFile }
        let keys = header.map(normalizeHeader)
        guard let domainIndex = firstIndex(in: keys, containing: ["linking site", "source domain", "source site", "referring domain", "ссылающийся сайт", "домен"])
                ?? firstIndex(in: keys, containing: ["source page", "source url", "linking page", "ссылающаяся страница", "страница-источник"]) else {
            throw ImportError.unsupportedFormat
        }
        let sourceIndex = firstIndex(in: keys, containing: ["source page", "source url", "linking page", "ссылающаяся страница", "страница-источник"])
        let targetIndex = firstIndex(in: keys, containing: ["target page", "target url", "linked page", "целевая страница", "целевой url"])
        let countIndex = firstIndex(in: keys, containing: ["links", "link count", "количество ссылок", "ссылки"])
        var donors: [GSCBacklinkDonor] = []
        var unique = Set<String>()
        for row in rows.dropFirst() {
            func value(_ index: Int?) -> String { guard let index, row.indices.contains(index) else { return "" }; return row[index].trimmingCharacters(in: .whitespacesAndNewlines) }
            let sourceURL = value(sourceIndex)
            let rawDomain = value(domainIndex)
            let domain = normalizedDomain(rawDomain.isEmpty ? sourceURL : rawDomain)
            guard !domain.isEmpty else { continue }
            let targetURL = value(targetIndex)
            let links = Int(value(countIndex).replacingOccurrences(of: ",", with: "")) ?? 0
            let donor = GSCBacklinkDonor(sourceDomain: domain, sourceURL: sourceURL, targetURL: targetURL, links: links)
            guard unique.insert(donor.id).inserted else { continue }
            donors.append(donor)
        }
        guard !donors.isEmpty else { throw ImportError.noDonors }
        let result = GSCBacklinkImport(target: target, importedAt: Date(), donors: donors)
        let data = try JSONEncoder().encode(result)
        try data.write(to: cacheURL(target: target), options: .atomic)
        return result
    }

    static func comparison(gsc: GSCBacklinkImport?, dataForSEO: [BacklinkSourceDetail]) -> GSCBacklinkComparison {
        let gscDomains = Set((gsc?.donors ?? []).map(\.sourceDomain).filter { !$0.isEmpty })
        let activeDomains = Set(dataForSEO.filter { !$0.isLost }.map { normalizedDomain($0.sourceDomain) }.filter { !$0.isEmpty })
        let confirmed = gscDomains.intersection(activeDomains)
        return GSCBacklinkComparison(
            gscDomains: gscDomains.count,
            dataForSEOActiveDomains: activeDomains.count,
            confirmedDomains: confirmed.count,
            gscOnlyDomains: gscDomains.subtracting(activeDomains).sorted(),
            dataForSEOOnlyDomains: activeDomains.subtracting(gscDomains).sorted()
        )
    }

    static func normalizedDomain(_ raw: String) -> String {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = URL(string: candidate.contains("://") ? candidate : "https://\(candidate)")?.host ?? candidate
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    enum ImportError: LocalizedError {
        case emptyFile, unsupportedFormat, noDonors
        var errorDescription: String? {
            switch self {
            case .emptyFile: "The Google Search Console export is empty."
            case .unsupportedFormat: "This is not a recognised Google Search Console Links CSV. Export either “Top linking sites” or “More sample links” from Search Console."
            case .noDonors: "No donor domains were found in this Search Console export."
            }
        }
    }

    private static func cacheURL(target: String) -> URL {
        let host = URL(string: target)?.host ?? target
        let name = host.lowercased().replacingOccurrences(of: "[^a-z0-9.-]", with: "_", options: .regularExpression)
        return directory.appendingPathComponent("\(name).json")
    }

    private static func normalizeHeader(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "\u{feff}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func firstIndex(in values: [String], containing options: [String]) -> Int? {
        values.firstIndex { value in options.contains { value.localizedCaseInsensitiveContains($0) } }
    }

    /// Handles quoted values and doubled quotes used by Search Console CSVs.
    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [[]]
        var value = ""
        var quoted = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted, index + 1 < characters.count, characters[index + 1] == "\"" {
                    value.append("\"")
                    index += 1
                } else {
                    quoted.toggle()
                }
            } else if character == "," && !quoted {
                rows[rows.count - 1].append(value); value = ""
            } else if (character == "\n" || character == "\r") && !quoted {
                if character == "\r" && index + 1 < characters.count && characters[index + 1] == "\n" { index += 1 }
                rows[rows.count - 1].append(value); value = ""
                if !rows.last!.isEmpty { rows.append([]) }
            } else { value.append(character) }
            index += 1
        }
        if !value.isEmpty || !(rows.last?.isEmpty ?? true) { rows[rows.count - 1].append(value) }
        return rows
    }
}
