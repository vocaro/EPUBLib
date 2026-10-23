import EPUBCore
import EPUBReading
@testable import EPUBText
import EPUBTestSupport
import libxml2
import XCTest

/// The declaration screen of text extraction's recovery (`HTMLRecoverySource`), held to the bytes
/// it returns for libxml2's HTML parser and to what that parser builds of them.
final class RecoveryDeclarationScreenTests: XCTestCase {
    // MARK: A second scan after either refusal (#333)

    // Generated sections built of what closing an abrupt comment changes: a `<` kept as text, the
    // two abrupt comments and comment ends, CDATA sections (one between a keyword's letters, one
    // holding a declaration), DOCTYPEs, declarations, quotes, values and raw text. Before #333 a
    // section whose first scan the declaration check refused was not scanned again.
    func testEitherRefusalAfterAClosedCommentIsFollowedByOneScanWithTheCommentsLeftOpen() {
        let core = ["<", " < ", "<!-->", "<!--->", "<!--", "-->", "<![CDATA[", "]]>", "<!DO", "CTYPE html", " [", ">",
                    "'", "<p title='", "<!EN", "TITY e 'v'>"]
        let pieces = core + ["--!>", "<!DOCTYPE html", " PUBLIC ", " SYSTEM \"", "]", "\"", "&e;", "<p>", "</p>", "<script>",
                             "</script>", "<style>", "<?x", "</body>", " b ", "<!DO<![CDATA[]]>CTYPE html", "<!EN<![CDATA[]]>TITY e 'v'>",
                             "<![CDATA[<!ENTITY e 'v'>]]>", "<![CDATA[<!DOCTYPE html [ ]>]]>", "<![CDATA[ --> ]]>"]
        var bodies: [String] = []
        for a in core { for b in core { for c in core { bodies.append(a + b + c) } } }
        // And a `<` kept as text, then an abrupt comment or none, then what may follow it.
        var random = SeededGenerator(seed: 333)
        for _ in 0..<12_000 {
            bodies.append(["", "<", " < ", "a <", "<<"].randomElement(using: &random)!
                + ["", "<!-->", "<!--->", "<!-->x<!-->"].randomElement(using: &random)!
                + (0..<Int.random(in: 1...6, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined())
        }
        var read = 0, readOnlyNow = 0
        for body in bodies {
            let bytes = Array(("<html><head><title>T</title></head><body><p>a</b>" + body + "</p><p>c --> d</p></body></html>").utf8)
            let map = HTMLRawTextMap(bytes)
            let closing = HTMLRecoverySource.scan(bytes, map, closingAbruptComments: true)
            let open = HTMLRecoverySource.scan(bytes, map, closingAbruptComments: false)
            func checked(_ output: [UInt8]?) -> [UInt8]? { output.flatMap { HTMLRecoverySource.hasDeclarations($0) ? nil : $0 } }
            let prepared = HTMLRecoverySource.prepare(Data(bytes)).map { [UInt8]($0.data) }
            // The rule: the first scan's bytes where they pass, or after a comment it closed, the
            // second's where they pass; nothing else, and nothing that was not just checked.
            XCTAssertEqual(prepared, checked(closing.output) ?? (closing.closedComment ? checked(open.output) : nil), body)
            // What was read before is read as it was. What is read now and was refused is read
            // with the comments left open, as before they were closed (#235).
            if let before = checked(closing.output == nil && closing.closedComment ? open.output : closing.output) {
                XCTAssertEqual(prepared, before, body)
            } else if let prepared {
                XCTAssertEqual(prepared, checked(open.output), body)
                readOnlyNow += 1
            }
            guard let prepared else { continue }
            read += 1
            XCTAssertNil(Self.declarationLibxml2Builds(prepared), body)
        }
        // 13,445 of the 16,096 are read, and 549 only now, `<!DO<![CDATA[]]>CTYPE` among them.
        XCTAssertGreaterThan(read, 10_000)
        XCTAssertGreaterThan(readOnlyNow, 250)
    }

    /// The first entity, declaration or subset that libxml2's HTML parser, with recovery's
    /// options, builds of `bytes`, or `nil`.
    private static func declarationLibxml2Builds(_ bytes: [UInt8]) -> String? {
        let options = Int32(HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
            | HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NODEFDTD.rawValue)
        let parsed = LibXML2Messages.silenced {
            bytes.withUnsafeBufferPointer { buffer in
                htmlReadMemory(UnsafeRawPointer(buffer.baseAddress)?.assumingMemoryBound(to: CChar.self), Int32(buffer.count), nil, "UTF-8", options)
            }
        }
        guard let document = parsed else { return nil }
        defer { xmlFreeDoc(document) }
        if document.pointee.extSubset != nil { return "an external subset" }
        if let dtd = document.pointee.intSubset {
            let subset = dtd.pointee
            if subset.children != nil || subset.entities != nil || subset.pentities != nil || subset.elements != nil
                || subset.attributes != nil || subset.notations != nil { return "an internal subset" }
            for identifier in [subset.ExternalID, subset.SystemID] {
                if let identifier, String(cString: identifier).contains("[") { return "a subset in an identifier" }
            }
        }
        var current = document.pointee.children
        while let node = current {
            switch node.pointee.type {
            case XML_ENTITY_REF_NODE, XML_ENTITY_NODE, XML_ENTITY_DECL, XML_ELEMENT_DECL, XML_ATTRIBUTE_DECL, XML_NOTATION_NODE:
                return "a node of type \(node.pointee.type.rawValue)"
            default: break
            }
            if node.pointee.type == XML_ELEMENT_NODE, let child = node.pointee.children { current = child; continue }
            var finished = node
            while finished.pointee.next == nil {
                guard let parent = finished.pointee.parent, parent.pointee.type == XML_ELEMENT_NODE else { break }
                finished = parent
            }
            current = finished.pointee.next
        }
        return nil
    }

    // MARK: DOCTYPEs checked in one pass (#783)

    // A read through quoted identifiers from a later DOCTYPE opener goes on as an earlier read
    // went only from a byte both reach in the same quote state. Each byte moves a read from
    // each state to a different one, so that is where the later read begins, or nowhere.
    func testALaterDoctypeIsReadOnInItsOwnQuoteState() {
        func refused(_ text: String) -> Bool { HTMLRecoverySource.hasDeclarations(Array(text.utf8)) }
        // The second opener lies in the first one's single-quoted identifier, and its own read
        // opens a double-quoted one: it meets a bracket, or never ends, past the first read's end.
        let first = "<!-- <!DOCTYPE html PUBLIC 'x <!DOCTYPE html PUBLIC \"y'>"
        XCTAssertTrue(refused(first + " [ \"> -->"))
        XCTAssertTrue(refused(first + " -->"))
        XCTAssertFalse(refused(first + " \"> -->"))
        // Outside the first read's quoted identifiers, it is that read from there.
        XCTAssertFalse(refused("<!-- <!DOCTYPE html PUBLIC \"a\" <!DOCTYPE html SYSTEM \"b\"> -->"))
        XCTAssertTrue(refused("<!-- <!DOCTYPE html PUBLIC \"a\" <!DOCTYPE html SYSTEM \"[b\"> -->"))
    }

    // Generated DOCTYPEs against the check as it read each one before #783, from itself to its
    // close: the one pass refuses what that refused, and nothing else.
    func testTheOnePassRefusesWhatEachDoctypeReadFromItselfRefuses() {
        let pieces = ["<!DOCTYPE", "<!doctype", " ", "html", "PUBLIC", "system", "\"", "'", ">", "[", "a", "<!--", "-->", "<", "<!ENTITY"]
        var random = SeededGenerator(seed: 783)
        var refused = 0, passed = 0
        for _ in 0..<40_000 {
            let bytes = Array((0..<Int.random(in: 1...14, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined().utf8)
            let expected = Self.eachDoctypeReadFromItself(bytes)
            XCTAssertEqual(HTMLRecoverySource.hasDeclarations(bytes), expected, String(decoding: bytes, as: UTF8.self))
            if expected { refused += 1 } else { passed += 1 }
        }
        XCTAssertGreaterThan(refused, 1_000)
        XCTAssertGreaterThan(passed, 1_000)
    }

    /// The declaration check as text-extraction.md states it, reading each DOCTYPE from itself.
    private static func eachDoctypeReadFromItself(_ bytes: [UInt8]) -> Bool {
        func matches(_ token: String, at position: Int) -> Bool {
            let token = Array(token.utf8)
            return position + token.count <= bytes.count
                && zip(bytes[position..<position + token.count], token).allSatisfy { ($0 >= 0x61 && $0 <= 0x7A ? $0 - 0x20 : $0) == $1 }
        }
        for index in bytes.indices where bytes[index] == 0x3C {
            if ["<!ENTITY", "<!ATTLIST", "<!ELEMENT", "<!NOTATION"].contains(where: { matches($0, at: index) }) { return true }
            guard matches("<!DOCTYPE", at: index) else { continue }
            guard let greaterThan = bytes[(index + 9)...].firstIndex(of: 0x3E) else { return true }
            let first = greaterThan + 1
            // To its first `>`, unless a `PUBLIC` or `SYSTEM` comes before it.
            if !(index..<first).contains(where: { $0 + 6 <= first && (matches("PUBLIC", at: $0) || matches("SYSTEM", at: $0)) }) {
                if bytes[index..<first].contains(0x5B) { return true }
                continue
            }
            var quote: UInt8?
            var position = index + 9
            var closed = false
            while position < bytes.count, !closed {
                let byte = bytes[position]
                if byte == 0x5B { return true }
                if let delimiter = quote { if byte == delimiter { quote = nil } }
                else if byte == 0x22 || byte == 0x27 { quote = byte }
                else if byte == 0x3E { closed = true }
                position += 1
            }
            if !closed { return true }
        }
        return false
    }

    // Each of these made the check read the rest of the input again from every opener. In an
    // unclosed comment the scan renames no keyword, so each `<!DOCTYPE PUBLIC ` there was read
    // through its quoted identifiers to the one `>` at the end; the checks before #783 made the
    // other two shapes one pass in text (#293).
    func testFourMebibytesOfDoctypeOpenersAreCheckedInOnePass() throws {
        let files = try Fixture.files()
        let section = "<html><body><p>x</b></p>"
        for (open, unit) in [("", "<!DOCTYPE "), ("", "<!DOCTYPE PUBLIC "), ("<!--", "<!DOCTYPE PUBLIC "), ("<!--", "<!DOCTYPE PUBLIC \"\" ")] {
            let start = section + open
            let xml = start + String(repeating: unit, count: (4 * 1024 * 1024 - start.utf8.count - 1) / unit.utf8.count) + ">"
            let bytes = Array(xml.utf8)
            var started = TestCPUClock.seconds()
            XCTAssertFalse(HTMLRecoverySource.hasDeclarations(bytes), open + unit)
            XCTAssertLessThan(TestCPUClock.seconds() - started, 20, open + unit)
            var archive = files
            archive["OPS/one.xhtml"] = Data(bytes)
            let publication = try EPUBPublication.open(data: Fixture.archive(archive))
            started = TestCPUClock.seconds()
            XCTAssertEqual(try publication.textSection(at: 0, recoversMalformedMarkup: true).text, "x", open + unit)
            XCTAssertLessThan(TestCPUClock.seconds() - started, 20, open + unit)
        }
    }
}

/// SplitMix64: the same sequence on every run and platform.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
