import EPUBCore
import EPUBReading
import Foundation

enum SectionStyles {
    static let maximumSheetBytes = 1 << 20
    static let maximumSectionBytes = 4 << 20
    static let maximumImportDepth = 4
    static let maximumSheets = 128

    /// The author stylesheets of a content document in cascade order: those of its
    /// `xml-stylesheet` processing instructions, then of its `<link rel="stylesheet">` and
    /// `<style>` elements in document order, with `@import` followed within the archive and
    /// bounded. Remote references are counted into `report` and never fetched.
    static func load(for document: ContentDocument, publication: EPUBPublication,
                     report: inout SectionReport) -> [CSSStyleSheet] {
        var loader = Loader(publication: publication)
        let candidates = candidates(document)
        let preferred = preferredSet(document, candidates)
        for candidate in candidates where candidate.applies(preferred: preferred) {
            let media = CSSMedia.mask(candidate.media ?? "")
            guard !media.isEmpty else { continue }
            switch candidate.source {
            case .reference(let href):
                switch StyleReference(href, relativeTo: document.path) {
                case .local(let path): loader.load(path: path, media: media, depth: 0, chain: [])
                case .remote: loader.report.remoteResourcesRefused += 1
                case .invalid: loader.report.unreadableResources += 1
                case .data: break
                }
            case .text(let text):
                loader.add(text: text, path: document.path, media: media, depth: 0, chain: [])
            }
        }
        report.formUnion(loader.report)
        return loader.sheets
    }

    /// A style sheet a document associates, before its title decides whether it applies.
    private struct Candidate {
        enum Source { case reference(String), text(String) }
        let source: Source
        let media: String?
        /// "" when untitled.
        let title: String
        let isAlternate: Bool

        /// CSSOM §6.1 "add a CSS style sheet": an untitled sheet is persistent, and a titled one,
        /// alternate or not, belongs to the set its title names, which applies when it is the
        /// preferred one. An untitled alternate sheet is never applied, as browsers leave it.
        func applies(preferred: String) -> Bool {
            title.isEmpty ? !isAlternate : title == preferred
        }
    }

    /// The sheets that `xml-stylesheet` instructions, `link` and `style` elements associate,
    /// in document order. A link that is not to a CSS sheet, that is `disabled` (HTML's
    /// `stylesheet` link type: such a link is not fetched) or that has no `href` associates
    /// none, nor does a `style` that is not CSS, nor an alternate instruction or link without a
    /// title.
    private static func candidates(_ document: ContentDocument) -> [Candidate] {
        var candidates = document.stylesheetInstructions.compactMap { instruction -> Candidate? in
            guard isCSS(instruction.type), !(instruction.isAlternate && instruction.title.isEmpty) else { return nil }
            return Candidate(source: .reference(instruction.href), media: instruction.media, title: instruction.title,
                             isAlternate: instruction.isAlternate)
        }
        for node in document.nodes where node.isElement {
            let title = node.attribute("title") ?? ""
            if node.isHTML("link") {
                let rel = linkTypes(node.attribute("rel"))
                guard rel.contains("stylesheet"), node.attribute("disabled") == nil, isCSS(node.attribute("type")),
                      let href = node.attribute("href") else { continue }
                let alternate = rel.contains("alternate")
                guard !(alternate && title.isEmpty) else { continue }
                candidates.append(Candidate(source: .reference(href), media: node.attribute("media"), title: title, isAlternate: alternate))
            } else if node.isHTML("style") || (node.namespace == ContentNamespace.svg && node.name == "style") {
                guard isCSS(node.attribute("type")) else { continue }
                candidates.append(Candidate(source: .text(node.textContent), media: node.attribute("media"), title: title, isAlternate: false))
            }
        }
        return candidates
    }

    /// The preferred style sheet set's name (CSSOM §6.1): the content of the last `<meta
    /// http-equiv="default-style">` (HTML §4.2.5.3), which changes it whenever it is read, or
    /// else the title of the first titled sheet that is not an alternate.
    private static func preferredSet(_ document: ContentDocument, _ candidates: [Candidate]) -> String {
        let pragma = document.nodes.last { node in
            node.isHTML("meta") && CodeUnits.asciiLowercased(node.attribute("http-equiv") ?? "") == "default-style"
                && !(node.attribute("content") ?? "").isEmpty
        }
        return pragma?.attribute("content") ?? candidates.first { !$0.title.isEmpty && !$0.isAlternate }?.title ?? ""
    }

    /// A `rel` attribute's link types: split at ASCII whitespace, ASCII lowercase (HTML §4.6.1).
    private static func linkTypes(_ rel: String?) -> [String] {
        CodeUnits.asciiLowercased(rel ?? "").utf8.split { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0C || $0 == 0x0D }
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Loads the stylesheets and registers their `@font-face` faces with the book's fonts.
    static func load(for document: ContentDocument, publication: EPUBPublication, fonts: FontRegistry,
                     report: inout SectionReport) -> [CSSStyleSheet] {
        let sheets = load(for: document, publication: publication, report: &report)
        fonts.register(sheets.flatMap(\.fontFaces), report: &report)
        return sheets
    }

    /// `text/css`, or EPUB 2's `text/x-oeb1-css`.
    private static func isCSS(_ type: String?) -> Bool {
        guard let type = type?.trimmingCharacters(in: .whitespaces).lowercased(), !type.isEmpty else { return true }
        let essence = type.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
        return essence == "text/css" || essence == "text/x-oeb1-css"
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

    /// At most the first `limit` bytes of a sheet, ending on a whole character of its encoding,
    /// so that they decode as the whole sheet would: a UTF-16 sheet (by its BOM) on a whole code
    /// unit and no lone high surrogate, any other before a UTF-8 sequence the bound would cut.
    static func prefix(_ data: Data, bytes limit: Int) -> Data {
        guard data.count > limit else { return data }
        let start = data.startIndex
        var end = start + max(0, limit)
        let bigEndian = data.starts(with: [0xFE, 0xFF])
        if bigEndian || data.starts(with: [0xFF, 0xFE]) {
            end -= (end - start) % 2
            if end - start >= 4 {
                let unit = bigEndian ? UInt16(data[end - 2]) << 8 | UInt16(data[end - 1]) : UInt16(data[end - 1]) << 8 | UInt16(data[end - 2])
                if (0xD800...0xDBFF).contains(unit) { end -= 2 }
            }
            return Data(data[start..<end])
        }
        // The lead byte of the last sequence, at most three continuation bytes back.
        var lead = end
        while lead > start, end - lead < 3, data[lead - 1] & 0xC0 == 0x80 { lead -= 1 }
        if lead > start {
            let byte = data[lead - 1]
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            if end - (lead - 1) < length { end = lead - 1 }
        }
        return Data(data[start..<end])
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
            // A sheet over the bound is read as far as the bound, and decoded as a whole one is:
            // its byte order mark is no style text.
            let oversized = data.count > SectionStyles.maximumSheetBytes
            let text = SectionStyles.decode(SectionStyles.prefix(data, bytes: SectionStyles.maximumSheetBytes))
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
