import EPUBCore
import EPUBReading
import Foundation

enum SectionStyles {
    static let maximumSheetBytes = 1 << 20
    static let maximumSectionBytes = 4 << 20
    static let maximumImportDepth = 4
    static let maximumSheets = 128

    /// The author stylesheets of a content document in cascade order: `<link rel="stylesheet">`
    /// to archive resources and `<style>` elements, with `@import` followed within the archive and
    /// bounded. Remote references are counted into `report` and never fetched.
    static func load(for document: ContentDocument, publication: EPUBPublication,
                     report: inout SectionReport) -> [CSSStyleSheet] {
        var loader = Loader(publication: publication)
        for node in document.nodes where node.isElement {
            if node.isHTML("link") {
                let rel = (node.attribute("rel") ?? "").lowercased().split(whereSeparator: \.isWhitespace)
                guard rel.contains("stylesheet"), !rel.contains("alternate"), isCSS(node.attribute("type")),
                      let href = node.attribute("href") else { continue }
                let media = CSSMedia.mask(node.attribute("media") ?? "")
                guard !media.isEmpty else { continue }
                switch StyleReference(href, relativeTo: document.path) {
                case .local(let path): loader.load(path: path, media: media, depth: 0, chain: [])
                case .remote: loader.report.remoteResourcesRefused += 1
                case .invalid: loader.report.unreadableResources += 1
                case .data: break
                }
            } else if node.isHTML("style") || (node.namespace == ContentNamespace.svg && node.name == "style") {
                guard isCSS(node.attribute("type")) else { continue }
                let media = CSSMedia.mask(node.attribute("media") ?? "")
                guard !media.isEmpty else { continue }
                loader.add(text: node.textContent, path: document.path, media: media, depth: 0, chain: [])
            }
        }
        report.formUnion(loader.report)
        return loader.sheets
    }

    /// Loads the stylesheets and registers their `@font-face` faces with the book's fonts.
    static func load(for document: ContentDocument, publication: EPUBPublication, fonts: FontRegistry,
                     report: inout SectionReport) -> [CSSStyleSheet] {
        let sheets = load(for: document, publication: publication, report: &report)
        fonts.register(sheets.flatMap(\.fontFaces), report: &report)
        return sheets
    }

    private static func isCSS(_ type: String?) -> Bool {
        guard let type = type?.trimmingCharacters(in: .whitespaces).lowercased(), !type.isEmpty else { return true }
        return type.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) == "text/css" } ?? false
    }

    /// Stylesheet text from bytes: a BOM wins, then UTF-8, then Windows Latin 1 (what a
    /// `@charset "iso-8859-1"` sheet usually means).
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    private struct Loader {
        let publication: EPUBPublication
        var sheets: [CSSStyleSheet] = []
        var report = SectionReport()
        var bytes = 0
        var rules = 0

        init(publication: EPUBPublication) { self.publication = publication }

        mutating func load(path: String, media: CSSMediaMask, depth: Int, chain: [String]) {
            guard !chain.contains(path) else { return }
            guard let data = try? publication.data(at: path) else { report.unreadableResources += 1; return }
            let oversized = data.count > SectionStyles.maximumSheetBytes
            let text = oversized ? String(decoding: data.prefix(SectionStyles.maximumSheetBytes), as: UTF8.self)
                : SectionStyles.decode(data)
            add(text: text, path: path, media: media, depth: depth, chain: chain + [path], oversized: oversized)
        }

        mutating func add(text: String, path: String, media: CSSMediaMask, depth: Int, chain: [String], oversized: Bool = false) {
            guard sheets.count < SectionStyles.maximumSheets else { report.stylesTruncated = true; return }
            var text = text
            let budget = min(SectionStyles.maximumSheetBytes, SectionStyles.maximumSectionBytes - bytes)
            if oversized || text.utf8.count > budget {
                report.stylesTruncated = true
                text = Self.truncate(text, toBytes: max(0, budget))
            }
            guard !text.isEmpty else { return }
            bytes += text.utf8.count
            var sheet = CSSStyleSheet.parse(text, path: path, media: media)
            report.remoteResourcesRefused += sheet.remoteReferences
            if sheet.truncated { report.stylesTruncated = true }
            for item in sheet.imports {
                guard depth < SectionStyles.maximumImportDepth else { report.stylesTruncated = true; break }
                load(path: item.path, media: item.media, depth: depth + 1, chain: chain)
            }
            let allowed = CSSStyleSheet.maximumRules - rules
            if sheet.rules.count > allowed {
                sheet.rules.removeSubrange(max(0, allowed)...)
                report.stylesTruncated = true
            }
            rules += sheet.rules.count
            sheets.append(sheet)
        }

        /// The longest prefix within `limit` UTF-8 bytes that ends after a `}`, so no rule is cut.
        static func truncate(_ text: String, toBytes limit: Int) -> String {
            let utf8 = Array(text.utf8.prefix(limit))
            guard let end = utf8.lastIndex(of: UInt8(ascii: "}")) else { return "" }
            return String(decoding: utf8[...end], as: UTF8.self)
        }
    }
}
