import Foundation
import ZIPFoundation

/// EPUBCheck's own test corpus (`src/test/resources` of w3c/epubcheck), read as data: which
/// fixtures are whole publications or single documents, and what the Gherkin scenarios beside
/// them say EPUBCheck reports for each. Nothing from the corpus is ever executed.
public enum EPUBCheckCorpus {
    /// Names the corpus root; the opt-in runners skip without it.
    public static let environmentKey = "EPUBLIB_EPUBCHECK_FIXTURES"

    /// What EPUBCheck's scenarios expect of a fixture: `valid` when every scenario checking it
    /// ends with no errors or warnings, `invalid` when one names a fatal error, error or warning,
    /// `unclassified` when no scenario checks it that way (report and CLI fixtures).
    public enum Verdict: String, Codable, Sendable { case valid, invalid, unclassified }

    public struct Scenario: Equatable, Sendable {
        /// The feature file, relative to the corpus root.
        public let feature: String
        public let name: String
        /// The checked fixture, relative to the corpus root.
        public let path: String
        public let verdict: Verdict
        /// The message ids the scenario expects, such as `OPF-030`, whatever their severity.
        public let ids: [String]
    }

    public struct Item: Equatable, Sendable {
        /// Relative to the corpus root.
        public let path: String
        public let url: URL
        public let isDirectory: Bool
        public let verdict: Verdict
        public let ids: [String]
        public let scenarios: [String]
    }

    public static func root(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        environment[environmentKey].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
    }

    // MARK: Scenarios

    /// The scenarios of one feature file. A scenario is `Scenario:` or `Example:`; its fixture
    /// is the path of `checking EPUB|file|document '…'` under the nearest
    /// `test files located at '…'`, the feature's `Background` one unless it names its own.
    public static func scenarios(in text: String, feature: String) -> [Scenario] {
        var result: [Scenario] = []
        var backgroundBase = "", inBackground = false
        var open = false, name = "", base = "", paths: [String] = [], ids: [String] = []
        var severe = false, clean = false, table = false
        func flush() {
            defer { open = false }
            guard open else { return }
            let verdict: Verdict = severe ? .invalid : clean ? .valid : .unclassified
            for path in paths {
                result.append(Scenario(feature: feature, name: name, path: normalized(base + "/" + path),
                                       verdict: verdict, ids: ids))
            }
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("@") { continue }
            if line.hasPrefix("|") {
                // A row of `Then the following errors are reported`.
                if table, let id = line.firstMatch(of: #/[A-Z]{3}-\d+[a-z]?/#) { ids.append(String(id.output)) }
                continue
            }
            if let header = line.firstMatch(of: #/^(Scenario Outline|Scenario Template|Scenario|Example|Background|Rule|Feature):\s*(.*)$/#) {
                table = false
                switch header.output.1 {
                case "Background": flush(); inBackground = true
                case "Rule", "Feature": break
                default:
                    flush()
                    inBackground = false; open = true
                    name = String(header.output.2); base = backgroundBase; paths = []; ids = []
                    severe = false; clean = false
                }
                continue
            }
            guard let step = line.firstMatch(of: #/^(Given|When|Then|And|But)\s+(.*)$/#) else { continue }
            let text = String(step.output.2)
            table = false
            if let location = text.firstMatch(of: #/^(?:EPUB )?test files located at '([^']*)'/#) {
                if inBackground || !open { backgroundBase = String(location.output.1) } else { base = String(location.output.1) }
                continue
            }
            guard open else { continue }
            if let check = text.firstMatch(of: #/^checking (?:EPUB|file set|file|document|directory) '([^']*)'/#) {
                paths.append(String(check.output.1))
            } else if let message = text.firstMatch(of: #/^(?:the )?(fatal error|error|warning|usage|info) ([A-Z]{3}-\d+[a-z]?) is reported/#) {
                ids.append(String(message.output.2))
                if ["fatal error", "error", "warning"].contains(String(message.output.1)) { severe = true }
            } else if let listed = text.firstMatch(of: #/^(?:the )?following (fatal error|error|warning|usage|info)s?(?: IDs?)? (?:are|is) reported/#) {
                if ["fatal error", "error", "warning"].contains(String(listed.output.1)) { severe = true }
                table = true
            } else if text.firstMatch(of: #/^no (?:other )?(?:errors?|warnings?) or (?:errors?|warnings?) (?:are|is) reported/#) != nil {
                clean = true
            }
        }
        flush()
        return result
    }

    /// Every scenario of every `.feature` file under `root`.
    public static func scenarios(under root: URL) -> [Scenario] {
        files(under: root).filter { $0.url.pathExtension == "feature" }.flatMap { file in
            (try? String(contentsOf: file.url, encoding: .utf8)).map { scenarios(in: $0, feature: file.path) } ?? []
        }
    }

    // MARK: Fixtures

    /// Every whole publication under `root`: a directory holding `mimetype` or
    /// `META-INF/container.xml`, and every `.epub` file outside one.
    public static func publications(under root: URL) -> [Item] {
        let verdicts = Dictionary(grouping: scenarios(under: root), by: \.path)
        var items: [Item] = []
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) else { return [] }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let path = relative(url, to: root)
            if values?.isDirectory == true {
                guard manager.fileExists(atPath: url.appending(path: "mimetype").path)
                        || manager.fileExists(atPath: url.appending(path: "META-INF/container.xml").path) else { continue }
                walker.skipDescendants()
                items.append(item(path, url, true, verdicts))
            } else if values?.isRegularFile == true, url.pathExtension.lowercased() == "epub" {
                items.append(item(path, url, false, verdicts))
            }
        }
        return items.sorted { $0.path < $1.path }
    }

    /// Every single document with one of `extensions` (lowercase, without the dot) under `root`
    /// that is not inside an expanded publication.
    public static func documents(under root: URL, extensions: Set<String>) -> [Item] {
        let verdicts = Dictionary(grouping: scenarios(under: root), by: \.path)
        let inside = publications(under: root).filter(\.isDirectory).map { $0.path + "/" }
        return files(under: root)
            .filter { file in extensions.contains(file.url.pathExtension.lowercased()) && !inside.contains { file.path.hasPrefix($0) } }
            .map { item($0.path, $0.url, false, verdicts) }
    }

    private static func item(_ path: String, _ url: URL, _ isDirectory: Bool, _ verdicts: [String: [Scenario]]) -> Item {
        let scenarios = verdicts[path] ?? []
        let verdict: Verdict = scenarios.contains { $0.verdict == .invalid } ? .invalid
            : scenarios.contains { $0.verdict == .valid } ? .valid : .unclassified
        return Item(path: path, url: url, isDirectory: isDirectory, verdict: verdict,
                    ids: Array(Set(scenarios.flatMap(\.ids))).sorted(), scenarios: scenarios.map(\.name))
    }

    /// The regular files under `directory` by relative path, leaving out what EPUBCheck's own
    /// packer leaves out (`.DS_Store`, `Thumbs.db`, `.git`, `.svn`). Symbolic links are not followed.
    public static func files(under directory: URL) -> [(path: String, url: URL)] {
        let ignored: Set<String> = [".DS_Store", "._DS_Store", "Thumbs.db", "ehthumbs.db"]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) else { return [] }
        var files: [(path: String, url: URL)] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if [".git", ".svn"].contains(url.lastPathComponent) { walker.skipDescendants() }
            } else if values?.isRegularFile == true, !ignored.contains(url.lastPathComponent) {
                files.append((relative(url, to: directory), url))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// The publication's bytes: an `.epub` as it is, an expanded directory packed as EPUBCheck
    /// packs one, with `mimetype` first and stored.
    public static func archive(of item: Item) throws -> Data {
        guard item.isDirectory else { return try Data(contentsOf: item.url) }
        var contents: [String: Data] = [:]
        for file in files(under: item.url) { contents[file.path] = try Data(contentsOf: file.url) }
        return try Fixture.archive(contents)
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        let base = root.standardizedFileURL.path, path = url.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }

    private static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return parts.joined(separator: "/")
    }

    // MARK: Containers around single documents

    private static let containerXML = """
        <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles>\
        <rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """

    /// A stub resource of a media type, enough for a package that names it to open.
    public static func stub(mediaType: String, isNavigation: Bool, name: String) -> Data {
        let page = { (body: String) in
            "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>Stub</title></head><body>\(body)</body></html>"
        }
        switch mediaType {
        case "application/xhtml+xml":
            return Data(page(isNavigation ? "<nav epub:type=\"toc\"><ol><li><a href=\"#stub\">Stub</a></li></ol></nav>" : "<p>Stub.</p>").utf8)
        case "application/x-dtbncx+xml":
            return Data("""
                <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap><navPoint id="stub" playOrder="1">\
                <navLabel><text>Stub</text></navLabel><content src="\(name)"/></navPoint></navMap></ncx>
                """.utf8)
        case "image/svg+xml":
            return Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><title>Stub</title><rect width=\"10\" height=\"10\"/></svg>".utf8)
        case "application/smil+xml":
            return Data("<smil xmlns=\"http://www.w3.org/ns/SMIL\" version=\"3.0\"><body><par><text src=\"\(name)\"/></par></body></smil>".utf8)
        case "text/css": return Data()
        default: return Data("stub".utf8)
        }
    }

    /// A minimal container around a lone package document: the document at `EPUB/package.opf`
    /// and a stub for every local manifest item it names, so that opening exercises the package
    /// parser on it. The manifest is read by pattern, so a malformed document gets what stubs it can.
    public static func container(aroundPackageDocument opf: Data) -> Data {
        let wide = opf.starts(with: [0xFE, 0xFF]) || opf.starts(with: [0xFF, 0xFE])
        let text = (wide ? String(data: opf, encoding: .utf16) : nil) ?? String(decoding: opf, as: UTF8.self)
        var files: [String: Data] = [:]
        for tag in text.matches(of: #/<(?:[A-Za-z_][\w.\-]*:)?item\b([^>]*)>/#) {
            var attributes: [String: String] = [:]
            for attribute in tag.output.1.matches(of: #/([\w:.\-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/#) {
                attributes[String(attribute.output.1)] = String(attribute.output.2 ?? attribute.output.3 ?? "")
            }
            guard let href = attributes["href"].map(unescaped), href.firstMatch(of: #/^[A-Za-z][A-Za-z0-9+.\-]*:/#) == nil,
                  let decoded = String(href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                    .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]).removingPercentEncoding,
                  !decoded.isEmpty, !decoded.hasPrefix("/") else { continue }
            var parts = ["EPUB"]
            for part in decoded.split(separator: "/") where part != "." {
                if part == ".." { _ = parts.popLast() } else { parts.append(String(part)) }
            }
            let path = parts.joined(separator: "/")
            guard parts.count > 1, path != "EPUB/package.opf", files[path] == nil else { continue }
            let properties = (attributes["properties"] ?? "").split(whereSeparator: \.isWhitespace)
            files[path] = stub(mediaType: (attributes["media-type"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                               isNavigation: properties.contains("nav"), name: parts.last!)
        }
        files["mimetype"] = Data("application/epub+zip".utf8)
        files["META-INF/container.xml"] = Data(containerXML.utf8)
        files["EPUB/package.opf"] = opf
        return (try? Fixture.archive(files)) ?? Data()
    }

    /// A minimal EPUB 3 container whose only spine item is `document`, with a stub navigation
    /// document beside it.
    public static func container(aroundContentDocument document: Data, name: String, mediaType: String) -> Data {
        let opf = """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\
            <dc:title>Single document</dc:title><dc:language>en</dc:language><dc:identifier id="uid">epubcheck-single-document</dc:identifier></metadata>\
            <manifest><item id="doc" href="\(name)" media-type="\(mediaType)"/>\
            <item id="nav" href="epubcheck-stub-nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest>\
            <spine><itemref idref="doc"/></spine></package>
            """
        return (try? Fixture.archive([
            "mimetype": Data("application/epub+zip".utf8), "META-INF/container.xml": Data(containerXML.utf8),
            "EPUB/package.opf": Data(opf.utf8), "EPUB/" + name: document,
            "EPUB/epubcheck-stub-nav.xhtml": stub(mediaType: "application/xhtml+xml", isNavigation: true, name: name),
        ])) ?? Data()
    }

    private static func unescaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
