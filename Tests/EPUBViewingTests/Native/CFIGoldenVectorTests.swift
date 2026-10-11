import Foundation
import XCTest
@testable import EPUBViewing

/// The Swift CFI, spine and search ports against what the vendored foliate-js produced in WebKit
/// for the same documents (`CFIGoldenVectors`, from `CFIVectorGenerator`).
final class CFIGoldenVectorTests: XCTestCase {
    private static let vectors: Vectors = {
        do { return try JSONDecoder().decode(Vectors.self, from: Data(CFIGoldenVectors.json.utf8)) }
        catch { fatalError("CFIGoldenVectors.json does not decode: \(error)") }
    }()

    /// Compare the native DOM directly with the recorded WebKit DOM. No whitespace
    /// alignment, namespace suppression, or omitted HTML positions may hide a mismatch.
    private struct Subject {
        let vectors: DocumentVectors
        let document: ContentDocument
        let model: [[String]]
        var isHTML: Bool { vectors.parser == "html" }

        init(_ vectors: DocumentVectors) throws {
            self.vectors = vectors
            let fixture = try XCTUnwrap(CFIFixtures.documents.first { $0.name == vectors.name })
            document = try ContentDocument.parse(Data(fixture.xhtml.utf8), path: "\(vectors.name).xhtml")
            model = document.nodes.map { $0.isElement ? ["E", $0.name, $0.namespace] : ["T", $0.text] }
        }

        func position(_ order: Int, _ offset: Int) -> DOMPosition? {
            guard document.nodes.indices.contains(order), offset <= document.nodes[order].utf16Length else { return nil }
            return DOMPosition(document.nodes[order], offset)
        }

        func flattened(_ start: DOMPosition, _ end: DOMPosition) -> [Int]? {
            [start.node.order, start.offset, end.node.order, end.offset]
        }
    }

    private static let subjects: [Subject] = {
        do { return try vectors.documents.map(Subject.init) }
        catch { fatalError("a fixture does not parse: \(error)") }
    }()

    func testTheVectorsCoverEveryFixture() {
        XCTAssertEqual(Self.vectors.documents.map(\.name), CFIFixtures.documents.map(\.name))
        XCTAssertEqual(Self.vectors.packages.map(\.name), CFIFixtures.packages.map(\.name))
        XCTAssertEqual(Self.vectors.strings.map(\.input), CFIFixtures.strings)
        XCTAssertGreaterThan(Self.vectors.documents.map(\.fromRange.count).reduce(0, +), 2_000)
        XCTAssertEqual(Self.subjects.filter(\.isHTML).map(\.vectors.name), ["html5-doctype", "no-namespace"])
    }

    /// `ContentDocument` must be the DOM a CFI sees: the same elements and merged character data
    /// in the same order.
    func testContentDocumentMatchesWebKitsDOM() {
        for subject in Self.subjects {
            let vectors = subject.vectors
            XCTAssertTrue(vectors.serializationStable, "\(vectors.name): foliate's serialize-and-reload changes the DOM")
            XCTAssertEqual(subject.model.count, vectors.model.count, "\(vectors.name): node count")
            for (order, (node, expected)) in zip(subject.model, vectors.model).enumerated() {
                XCTAssertEqual(node, expected,
                               "\(vectors.name) node \(order)")
            }
        }
    }

    func testRangesBecomeTheCFIsFoliateWrote() {
        var checked = 0
        for subject in Self.subjects {
            for vector in subject.vectors.fromRange {
                guard let cfi = vector[4].string, let numbers = vector[0..<4].ints,
                      let start = subject.position(numbers[0], numbers[1]), let end = subject.position(numbers[2], numbers[3])
                else { continue }
                let path = EPUBCFI.localPath(from: start, to: end, in: subject.document)
                XCTAssertEqual(path, EPUBCFI.unwrap(cfi), "\(subject.vectors.name) \(numbers)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 2_500)
    }

    /// Each CFI resolves to the positions foliate's `partsToNode` named (as `EPUBCFI` maps them),
    /// and, where foliate's DOM range has no documented divergence, to the same text offsets.
    func testCFIsResolveWhereFoliateResolvedThem() {
        var checked = 0, compared = 0
        for subject in Self.subjects {
            let vectors = subject.vectors, document = subject.document
            var before: [Int] = [], total = 0
            for node in document.nodes { before.append(total); total += node.utf16Length }
            func reading(_ position: DOMPosition) -> Int { before[position.node.order] + (position.node.isText ? position.offset : 0) }
            for vector in vectors.toRange {
                let resolved = EPUBCFI.resolve(localPath: vector.cfi, in: document)
                XCTAssertEqual(resolved.flatMap { subject.flattened($0.start, $0.end) }, vector.expected,
                               "\(vectors.name) \(vector.cfi) \(vector.flags)")
                checked += 1
                if let resolved, vector.flags.isEmpty, let foliate = vector.reading {
                    XCTAssertEqual([reading(resolved.start), reading(resolved.end)], foliate,
                                   "\(vectors.name) \(vector.cfi): text offsets differ from foliate's range")
                    compared += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 3_000)
        XCTAssertGreaterThan(compared, 2_500)
    }

    func testRangeCFIsRoundTrip() throws {
        for subject in Self.subjects {
            for vector in subject.vectors.fromRange {
                guard let numbers = vector[0..<4].ints, let start = subject.position(numbers[0], numbers[1]),
                      let end = subject.position(numbers[2], numbers[3]) else { continue }
                let path = EPUBCFI.localPath(from: start, to: end, in: subject.document)
                let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: path, in: subject.document), "\(subject.vectors.name) \(path)")
                // An ID assertion names the first element with that ID, as getElementById does.
                let duplicate = [start, end].contains { $0.node.isElement && $0.node.attribute("id") == "dup" }
                if !duplicate {
                    XCTAssertEqual(resolved.start, start, "\(subject.vectors.name) \(path)")
                    XCTAssertEqual(resolved.end, end, "\(subject.vectors.name) \(path)")
                }
            }
        }
    }

    /// Foundation's comparison folds decomposable diacritics before a language's tailoring, so in
    /// a Turkish (or Swedish, Spanish…) document letters like `ö` or `İ` also match their base
    /// letter: the port finds a superset there. Everywhere else the matches are foliate's.
    func testQuotesLocateWhereFoliateFoundThem() {
        var checked = 0
        for subject in Self.subjects {
            let vectors = subject.vectors, document = subject.document
            for vector in vectors.search {
                XCTAssertEqual(TextSearch.normalizeQuote(vector.quote), vector.query, "\(vectors.name): \(vector.quote)")
                let defaultLocale = vector.locale.hasPrefix("default:") ? String(vector.locale.dropFirst(8)) : nil
                XCTAssertEqual(TextSearch.locale(of: document), defaultLocale == nil ? vector.locale : nil, vectors.name)
                let matches = TextSearch.matches(of: vector.query, in: document, locale: defaultLocale ?? vector.locale)
                guard let expected = vector.matches else {
                    // foliate threw: an empty query, or a document without an XHTML body.
                    XCTAssertTrue(vector.query.isEmpty || document.body == nil, "\(vectors.name): \(vector.error ?? "")")
                    if vector.query.isEmpty { XCTAssertEqual(matches, []) }
                    continue
                }
                let found = matches.map { subject.flattened($0.start, $0.end) }
                let foliate = expected.map { $0[0..<4].ints }
                if vector.locale == "tr" {
                    XCTAssertTrue(foliate.allSatisfy(found.contains), "\(vectors.name): \(vector.query) lost a match")
                } else {
                    XCTAssertEqual(found, foliate, "\(vectors.name): \(vector.query.debugDescription)")
                    for (match, foliate) in zip(matches, expected) {
                        XCTAssertEqual(EPUBCFI.localPath(from: match.start, to: match.end, in: document),
                                       foliate[4].string.map(EPUBCFI.unwrap), "\(vectors.name): \(vector.query)")
                    }
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 100)
    }

    func testSpineBasesAndResolutionMatchFoliate() throws {
        for vectors in Self.vectors.packages {
            let fixture = try XCTUnwrap(CFIFixtures.packages.first { $0.name == vectors.name })
            let package = try ContentDocument.parse(Data(fixture.opf.utf8), path: "package.opf", asContent: false)
            guard let bases = vectors.bases else {
                XCTFail("\(vectors.name): foliate could not read the spine: \(vectors.error ?? "")")
                continue
            }
            let spine = SpineCFIs(package: package, spineCount: bases.count)
            XCTAssertEqual(spine.bases, bases, vectors.name)
            for vector in vectors.resolve ?? [] {
                let cfi = try XCTUnwrap(vector[0].string)
                let resolved = spine.resolve(cfi)
                guard let index = vector[1].int else {
                    XCTAssertNil(resolved?.spineIndex, "\(vectors.name) \(cfi)")
                    continue
                }
                XCTAssertEqual(resolved?.spineIndex, index, "\(vectors.name) \(cfi)")
                // A range whose parent is only the package path leaves foliate's anchor nothing to resolve.
                let local = vector[2].string.map { $0.hasPrefix(",") ? "" : $0 }
                XCTAssertEqual(resolved?.localPath, local, "\(vectors.name) \(cfi)")
            }
        }
    }

    func testStringsParseAndPrintAsFoliateDid() {
        for vector in Self.vectors.strings {
            XCTAssertEqual(EPUBCFI.isCFI(vector.input), vector.isCFI, vector.input.debugDescription)
            let parsed = try? EPUBCFI.parse(vector.input)
            // foliate parsed these but could not use them: NaN or inexact steps, or a one-comma range.
            let nan = vector.parsed?.contains("\"index\":null") == true || vector.parsed?.contains("\"offset\":null") == true
            let inexact = vector.input.matches(of: /[\/:]0*(\d+)/).contains { match in
                match.1.count > 16 || (match.1.count == 16 && match.1 > "9007199254740992")
            }
            let refused = vector.parsed == nil || vector.string == nil || nan || inexact
            guard let parsed, !refused else {
                XCTAssertNil(parsed, "\(vector.input.debugDescription) should be refused")
                continue
            }
            XCTAssertEqual(EPUBCFI.string(parsed), vector.string, vector.input.debugDescription)
            XCTAssertEqual(Self.json(parsed), vector.parsed, vector.input.debugDescription)
            if let collapsed = vector.collapsed {
                XCTAssertEqual([EPUBCFI.collapse(vector.input), EPUBCFI.collapse(vector.input, toEnd: true)], collapsed,
                               vector.input.debugDescription)
            }
        }
    }

    func testComparisonAndRangeBuildingMatchFoliate() throws {
        for vector in Self.vectors.pairs {
            let a = try XCTUnwrap(vector[0].string), b = try XCTUnwrap(vector[1].string)
            if let order = vector[2].int {
                XCTAssertEqual(EPUBCFI.compare(a, b), order, "\(a) \(b)")
            }
            if let range = vector[3].string, let from = try? EPUBCFI.parse(a), let to = try? EPUBCFI.parse(b) {
                XCTAssertEqual(EPUBCFI.string(EPUBCFI.buildRange(from: from, to: to)), range, "\(a) \(b)")
            }
        }
    }

    /// The search prefilter may only separate what base-strength collation separates, or a
    /// quote foliate located would be skipped before the comparison runs. Root collation's
    /// equivalences all hold; a language's own merges (Swedish `ü` with `y`) are not found.
    func testPrefilterKeysNeverSeparateCharactersTheCollatorEquates() throws {
        func searchable(_ scalar: UInt32) -> Character? {
            guard let scalar = Unicode.Scalar(scalar), scalar.properties.generalCategory != .format,
                  !EPUBCFI.isJSWhitespace(scalar) else { return nil }
            return Character(scalar)
        }
        let root = try XCTUnwrap(Self.vectors.collation["en"])
        var rootClass: [UInt32: Int] = [:]
        for (index, members) in root.classes.enumerated() { for member in members { rootClass[member] = index } }
        var tailored = 0
        for (locale, collation) in Self.vectors.collation {
            for members in collation.classes {
                guard let first = members.first, let character = searchable(first) else { continue }
                for member in members.dropFirst() {
                    guard let other = searchable(member) else { continue }
                    guard rootClass[member] == rootClass[first] else { tailored += 1; continue }
                    XCTAssertEqual(TextSearch.prefilterKey(of: other), TextSearch.prefilterKey(of: character),
                                   "\(locale): \(character) and \(other) compare equal but have different keys")
                }
            }
        }
        XCTAssertLessThan(tailored, 100, "the other locales' data should mostly agree with root")
    }

    /// A one-character quote finds exactly the characters WebKit's root collator equates with it,
    /// except that Cyrillic `й` also matches `и`.
    func testSingleCharactersMatchTheirCollationClass() throws {
        let root = try XCTUnwrap(Self.vectors.collation["en"])
        let characters = root.classes.joined().compactMap(Unicode.Scalar.init).filter {
            switch $0.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark, .format: false
            default: !EPUBCFI.isJSWhitespace($0)
            }
        }
        let body = characters.map { "&#x\(String($0.value, radix: 16));" }.joined(separator: " ")
        let markup = #"<html xmlns="http://www.w3.org/1999/xhtml"><body><p>"# + body + "</p></body></html>"
        let document = try ContentDocument.parse(Data(markup.utf8), path: "characters.xhtml")
        let text = try XCTUnwrap(document.body?.children.first?.children.first?.text)
        var missing: [String] = [], extra: [String] = []
        // Every class that merges characters, and a sample of the rest for false matches.
        for (index, members) in root.classes.enumerated() where members.count > 1 || index % 4 == 0 {
            let expected = Set(members.compactMap(Unicode.Scalar.init).filter(characters.contains).map(String.init))
            guard let query = expected.first else { continue }
            let found = Set(TextSearch.matches(of: query, in: document, locale: "en").map { match in
                let utf16 = text.utf16
                let start = utf16.index(utf16.startIndex, offsetBy: match.start.offset)
                return String(Substring(utf16[start..<utf16.index(utf16.startIndex, offsetBy: match.end.offset)]))
            })
            missing += expected.subtracting(found).map { "\(query)≠\($0)" }
            extra += found.subtracting(expected).map { "\(query)=\($0)" }
        }
        XCTAssertEqual(missing, [], "quotes foliate located would not be found")
        // Foundation folds the breve of Cyrillic short i, which root collation keeps as a letter.
        XCTAssertEqual(Set(extra.flatMap { $0.unicodeScalars.prefix(1) + $0.unicodeScalars.suffix(1) })
            .subtracting("ЙйИиЍѝӢӣӤӥ".unicodeScalars), [], "extra matches: \(extra)")
    }

    // MARK: - Decoding

    private struct Vectors: Decodable, Sendable {
        let userAgent: String
        let documents: [DocumentVectors]
        let packages: [PackageVectors]
        let strings: [StringVector]
        let pairs: [[JSONValue]]
        let collation: [String: Collation]
    }

    private struct DocumentVectors: Decodable, Sendable {
        let name: String
        let parser: String
        let model: [[String]]
        let serializationStable: Bool
        let fromRange: [[JSONValue]]
        let toRange: [ToRange]
        let search: [SearchVector]
    }

    private struct ToRange: Decodable, Sendable {
        let cfi: String
        let flags: [String]
        let reading: [Int]?
        let expected: [Int]?
    }

    private struct SearchVector: Decodable, Sendable {
        let quote: String
        let query: String
        let locale: String
        let matches: [[JSONValue]]?
        let error: String?
    }

    private struct PackageVectors: Decodable, Sendable {
        let name: String
        let error: String?
        let bases: [String]?
        let resolve: [[JSONValue]]?
    }

    private struct StringVector: Decodable, Sendable {
        let input: String
        let isCFI: Bool
        let parsed: String?
        let string: String?
        let collapsed: [String]?
    }

    private struct Collation: Decodable, Sendable {
        let resolved: String
        let ignorable: [UInt32]
        let classes: [[UInt32]]
    }

    /// `JSON.stringify` of foliate's parse result with sorted keys, for comparison as text.
    private static func json(_ expression: EPUBCFI.Expression) -> String {
        func string(_ value: String) -> String {
            var escaped = "\""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"": escaped += "\\\""
                case "\\": escaped += "\\\\"
                case "\n": escaped += "\\n"
                case "\r": escaped += "\\r"
                case "\t": escaped += "\\t"
                case "\u{8}": escaped += "\\b"
                case "\u{C}": escaped += "\\f"
                case _ where scalar.value < 0x20: escaped += String(format: "\\u%04x", scalar.value)
                default: escaped.unicodeScalars.append(scalar)
                }
            }
            return escaped + "\""
        }
        func number(_ value: Double) -> String { value.isFinite ? EPUBCFI.jsNumber(value) : "null" }
        func step(_ step: EPUBCFI.Expression.Step) -> String {
            var fields: [String] = []
            if let id = step.id { fields.append("\"id\":" + string(id)) }
            fields.append("\"index\":\(step.index)")
            if let offset = step.offset { fields.append("\"offset\":\(offset)") }
            if let side = step.side { fields.append("\"side\":" + string(side)) }
            if let spatial = step.spatial { fields.append("\"spatial\":[" + spatial.map(number).joined(separator: ",") + "]") }
            if let temporal = step.temporal { fields.append("\"temporal\":" + number(temporal)) }
            if let text = step.text { fields.append("\"text\":[" + text.map(string).joined(separator: ",") + "]") }
            return "{" + fields.joined(separator: ",") + "}"
        }
        func path(_ path: EPUBCFI.Expression.Path) -> String {
            "[" + path.map { "[" + $0.map(step).joined(separator: ",") + "]" }.joined(separator: ",") + "]"
        }
        if let parent = expression.parent {
            return "{\"end\":\(path(expression.end ?? [])),\"parent\":\(path(parent)),\"start\":\(path(expression.start ?? []))}"
        }
        return path(expression.path ?? [])
    }
}

private enum JSONValue: Decodable, Equatable, Sendable {
    case number(Double), string(String), bool(Bool), null, array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var int: Int? { if case .number(let value) = self { Int(exactly: value) } else { nil } }
}

private extension ArraySlice where Element == JSONValue {
    var ints: [Int]? {
        let values = compactMap(\.int)
        return values.count == count ? values : nil
    }
}
