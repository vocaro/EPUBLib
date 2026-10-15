/// Where the HTML Standard reads script and style content as raw text, for text extraction's
/// recovery scan (`HTMLRecoverySource` in TextExtraction.swift, #255).
///
/// libxml2's HTML parser opens raw text at every start tag whose name it reads as `script` or
/// `style`, wherever that tag stands, and reads a name only as far as a letter, digit, `:`, `-`,
/// `_` or `.` goes: `<script"q>` and `<script=x>` are scripts to it, and so is a `<script>` in a
/// `textarea` or a title, or in what HTML reads as a comment, a DOCTYPE or an attribute value.
/// The HTML Standard opens raw text at none of those, and shows what follows. This map runs the
/// Standard's tokenizer (13.2.5) over the bytes, with the part of tree construction that
/// switches its state: script data, RAWTEXT and RCDATA, PLAINTEXT, and SVG and MathML content
/// (13.2.6.5), where a `<title>` or `<textarea>` is no RCDATA. It departs from the Standard in
/// one place, as libxml2 and the scan do: a start tag written `<…/>` opens no raw text, as
/// XHTML has it.
///
/// What the scan writes from it changes no byte that libxml2 reads, only how libxml2 reads a
/// name: one letter of the name is written as its numeric character reference. Where libxml2 is
/// reading a tag there, the tag's name ends at the reference's `&`, and the rest of the tag ends
/// where it ended before, as libxml2 passes over what no attribute name can begin to the same
/// white space or `>`. Wherever libxml2 is not reading a tag there, the reference is inert: text
/// and attribute values decode it to the letter, and a comment, a processing instruction, a
/// DOCTYPE and raw text show none of it. It holds no byte that begins or ends anything in any of
/// those, so it cannot move where any of them ends; and no declaration keyword can come of it.
/// - The last letter of a `<script` or `<style` that libxml2 would read as a start tag where the
///   Standard opens no raw text: libxml2 then reads an element named `scrip` or `styl`, whose
///   content it reads as markup and the walk as text. So the scan enters raw text where the
///   Standard does and nowhere else. This is done only where libxml2 has surely left the head
///   (in a title, at its first tag), and nowhere inside SVG and MathML.
/// - In script or style raw text, the last letter of a `</script` or `</style` whose name goes
///   on (`</scriptx`) where its `>` lies in or beyond the Standard's end tag of that raw text:
///   libxml2 would read it as an end tag that closes nothing, skip to that `>` and take the end
///   tag with it, and the raw text would run on past it.
///
/// Where the map cannot tell the Standard's context (a `select` or a `frameset`, markup inside an
/// SVG or MathML integration point, an end tag in SVG or MathML content that closes no element
/// of it), it stops, and renames nothing from there.
struct HTMLRawTextMap {
    /// The `<` of each start tag after which the Standard reads script or style raw text. Inside
    /// SVG and MathML, where it reads them as markup, a script or style is read as raw text, as
    /// libxml2 reads it; the walk hides their content either way.
    private(set) var rawText: Set<Int> = []
    /// Ascending indices of the letters to write as numeric character references.
    private(set) var renamed: [Int] = []

    private struct Foreign {
        var name: [UInt8]
        var mathML: Bool
        var integrationPoint: Bool
    }

    private struct Tag {
        var end: Int
        var closing: Bool
        var name: [UInt8]
        var selfClosing: Bool
        var attributes: [([UInt8], [UInt8])]
    }

    init(_ bytes: [UInt8]) {
        var foreign: [Foreign] = [] // Open SVG and MathML elements; empty in HTML content.
        // Whether libxml2 has surely left the head: at `</head>`, or at a start tag it leaves the
        // head for. Until then nothing is renamed but a title's first tag: libxml2 keeps an
        // element it does not know in the head, with all that follows up to `</head>`, where the
        // walk reads none of it.
        var body = false
        var index = 0
        scan: while index < bytes.count {
            guard let open = bytes[index...].firstIndex(of: 0x3C) else { break }
            guard open + 1 < bytes.count else { break }
            let next = bytes[open + 1]
            if next == 0x21 { // <!
                let end: Int
                if Self.starts(bytes, Self.commentOpen, at: open) {
                    end = Self.commentEnd(bytes, from: open)
                } else if Self.matches(bytes, Self.doctype, at: open + 2) {
                    end = Self.greaterThan(bytes, from: open + 2)
                } else if !foreign.isEmpty, Self.starts(bytes, Self.cdataOpen, at: open) {
                    end = Self.find(bytes, Self.cdataClose, from: open + Self.cdataOpen.count).map { $0 + Self.cdataClose.count } ?? bytes.count
                } else {
                    end = Self.greaterThan(bytes, from: open + 2) // A bogus comment.
                }
                if body, foreign.isEmpty { markShown(bytes, open + 1..<end) }
                index = end
                continue
            }
            if next == 0x3F { // <? is a bogus comment.
                let end = Self.greaterThan(bytes, from: open + 1)
                if body, foreign.isEmpty { markShown(bytes, open + 1..<end) }
                index = end
                continue
            }
            if next == 0x2F, open + 2 < bytes.count, !Self.letter(bytes[open + 2]) { // </
                if bytes[open + 2] == 0x3E { index = open + 3; continue }
                let end = Self.greaterThan(bytes, from: open + 2)
                if body, foreign.isEmpty { markShown(bytes, open + 1..<end) }
                index = end
                continue
            }
            guard next == 0x2F ? open + 2 < bytes.count : Self.letter(next) else { index = open + 1; continue }
            // A tag the input ends inside is not a tag, and HTML shows nothing of it.
            guard let tag = Self.tag(bytes, at: open) else { break }
            if body, foreign.isEmpty { markShown(bytes, open + 1..<tag.end) }
            index = tag.end
            if tag.closing {
                if Self.equals(tag.name, "head") { body = true }
                if !foreign.isEmpty, !Self.closeForeign(&foreign, tag.name) { stop(at: open); break scan }
                continue
            }
            let candidate = Self.libxml2RawText(bytes, at: open)
            if let current = foreign.last {
                if current.integrationPoint { stop(at: open); break scan }
                if Self.breaksOut(tag) {
                    foreign.removeAll()
                } else {
                    // Nothing is renamed in SVG and MathML: there the walk hides a script or
                    // style libxml2 reads, and writes the name of any other MathML element.
                    guard !tag.selfClosing else { continue }
                    let mathML = current.mathML && !(Self.equals(current.name, "annotation-xml") && Self.equals(tag.name, "svg"))
                    foreign.append(Foreign(name: tag.name, mathML: mathML, integrationPoint: Self.integrationPoint(tag, mathML: mathML)))
                    if let candidate, tag.name == candidate.name {
                        // HTML reads a foreign script or style as markup and the walk hides it;
                        // read to its end tag as libxml2 does.
                        let end = Self.rawTextEnd(bytes, candidate.name, from: tag.end)
                        force(bytes, candidate.name, tag.end..<end)
                        rawText.insert(open)
                        index = end
                    }
                    continue
                }
            }
            if Self.leavesHead.contains(String(decoding: tag.name, as: UTF8.self)) { body = true }
            if body, let candidate, tag.name != candidate.name { renamed.append(candidate.letter) }
            if Self.equals(tag.name, "select") || Self.equals(tag.name, "frameset") { stop(at: open); break scan }
            guard !tag.selfClosing else { continue }
            switch String(decoding: tag.name, as: UTF8.self) {
            case "script":
                let end = Self.scriptDataEnd(bytes, from: tag.end)
                force(bytes, Self.script, tag.end..<end)
                rawText.insert(open)
                index = end
            case "style":
                let end = Self.rawTextEnd(bytes, Self.style, from: tag.end)
                force(bytes, Self.style, tag.end..<end)
                rawText.insert(open)
                index = end
            case "title", "textarea", "xmp", "iframe", "noembed", "noframes", "plaintext":
                // RCDATA, RAWTEXT and PLAINTEXT, which libxml2 reads as markup: up to its first
                // tag, libxml2 is surely in the element; after it, the element may have been
                // closed, and the Standard reads on to the end tag, or to the input's end.
                let end = Self.equals(tag.name, "plaintext") ? bytes.count : Self.rawTextEnd(bytes, tag.name, from: tag.end)
                if body || Self.equals(tag.name, "title"),
                   let first = Self.markup(bytes, tag.end..<end), let candidate = Self.libxml2RawText(bytes, at: first) {
                    renamed.append(candidate.letter)
                }
                index = end
            case "svg":
                foreign.append(Foreign(name: tag.name, mathML: false, integrationPoint: false))
            case "math":
                foreign.append(Foreign(name: tag.name, mathML: true, integrationPoint: false))
            default:
                break
            }
        }
        renamed.sort()
    }

    /// Whether the letter at `index` is to be written as a reference.
    func renames(_ index: Int) -> Bool {
        var low = 0, high = renamed.count
        while low < high {
            let middle = (low + high) / 2
            if renamed[middle] < index { low = middle + 1 } else { high = middle }
        }
        return low < renamed.count && renamed[low] == index
    }

    /// Renames each `<script` and `<style` that libxml2 would read as a start tag in `range`,
    /// which the Standard reads as something other than such a tag.
    private mutating func markShown(_ bytes: [UInt8], _ range: Range<Int>) {
        var index = range.lowerBound
        while index < range.upperBound, let open = bytes[index..<range.upperBound].firstIndex(of: 0x3C) {
            if let candidate = Self.libxml2RawText(bytes, at: open) { renamed.append(candidate.letter) }
            index = open + 1
        }
    }

    /// The first `<` in `range` that libxml2 reads as markup: one before a letter, `/`, `!` or `?`.
    private static func markup(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        var index = range.lowerBound
        while index < range.upperBound, let open = bytes[index..<range.upperBound].firstIndex(of: 0x3C) {
            if open + 1 < bytes.count, letter(bytes[open + 1]) || [0x2F, 0x21, 0x3F].contains(bytes[open + 1]) { return open }
            index = open + 1
        }
        return nil
    }

    /// Renames each `</name` in the raw text `range` that would take the Standard's end tag of
    /// that raw text with it. libxml2 leaves raw text at any `</name`; where its name goes on
    /// (`</scriptx`), it reads an end tag that closes nothing, skips to the next `>` and goes on
    /// in the raw text. When that `>` is the end tag's own, or beyond it, the raw text runs on
    /// past the Standard's end. Renamed, the `</name` stays in the raw text, which ends where
    /// the Standard ends it. Where the name ends at once (`</script"x>`), libxml2 closes the
    /// element there, before the Standard does, and that is left as it is.
    private mutating func force(_ bytes: [UInt8], _ name: [UInt8], _ range: Range<Int>) {
        guard range.upperBound < bytes.count else { return }
        var greaterThan = -1 // The next `>` at or after the last `</name` looked at, found once.
        var index = range.lowerBound
        while index < range.upperBound, let open = bytes[index..<range.upperBound].firstIndex(of: 0x3C) {
            let after = open + 2 + name.count
            if bytes[open + 1] == 0x2F, Self.matches(bytes, name, at: open + 2), after < bytes.count, Self.libxml2NameByte(bytes[after]) {
                if greaterThan < after { greaterThan = bytes[after...].firstIndex(of: 0x3E) ?? bytes.count }
                if greaterThan >= range.upperBound { renamed.append(after - 1) }
            }
            index = open + 1
        }
    }

    private mutating func stop(at position: Int) {
        renamed.removeAll { $0 >= position }
    }

    private static let script = Array("script".utf8), style = Array("style".utf8)
    /// The start tags at which libxml2 2.9.13 (this Mac's) leaves the head for the body, measured
    /// with each element after a title in a head; it keeps any other element in the head.
    private static let leavesHead: Set<String> = [
        "a", "abbr", "acronym", "address", "b", "bdo", "big", "blockquote", "body", "br", "center", "cite", "code",
        "dd", "dfn", "dir", "div", "dl", "dt", "em", "fieldset", "font", "form", "frameset", "h1", "h2", "h3", "h4",
        "h5", "h6", "hr", "i", "iframe", "img", "kbd", "li", "listing", "map", "menu", "ol", "p", "pre", "q", "s",
        "samp", "small", "span", "strike", "strong", "sub", "sup", "table", "tt", "u", "ul", "var", "xmp"]
    private static let commentOpen = Array("<!--".utf8), doctype = Array("doctype".utf8)
    private static let cdataOpen = Array("<![CDATA[".utf8), cdataClose = Array("]]>".utf8)

    /// A `<script` or `<style` at `position` that libxml2 reads as such a start tag, its name
    /// ending where no letter, digit, `:`, `-`, `_` or `.` follows; and the index of its last letter.
    static func libxml2RawText(_ bytes: [UInt8], at position: Int) -> (name: [UInt8], letter: Int)? {
        guard bytes[position] == 0x3C, position + 1 < bytes.count else { return nil }
        for name in [script, style] where matches(bytes, name, at: position + 1) {
            let after = position + 1 + name.count
            guard after == bytes.count || !libxml2NameByte(bytes[after]) else { return nil }
            return (name, after - 1)
        }
        return nil
    }

    static func libxml2NameByte(_ byte: UInt8) -> Bool {
        letter(byte) || (byte >= 0x30 && byte <= 0x39) || [0x3A, 0x2D, 0x5F, 0x2E].contains(byte)
    }

    /// HTML Standard, comment start state through comment end bang state: a comment ends at
    /// `<!-->`, `<!--->`, the first `-->` or `--!>`, or the input's end.
    private static func commentEnd(_ bytes: [UInt8], from open: Int) -> Int {
        let start = open + 4
        if start < bytes.count, bytes[start] == 0x3E { return start + 1 }
        if start + 1 < bytes.count, bytes[start] == 0x2D, bytes[start + 1] == 0x3E { return start + 2 }
        var index = start
        while index + 2 < bytes.count {
            if bytes[index] == 0x2D, bytes[index + 1] == 0x2D {
                if bytes[index + 2] == 0x3E { return index + 3 }
                if bytes[index + 2] == 0x21, index + 3 < bytes.count, bytes[index + 3] == 0x3E { return index + 4 }
            }
            index += 1
        }
        return bytes.count
    }

    /// The index after the first `>` at or after `position`, or the input's end: where a bogus
    /// comment, a DOCTYPE (quoted identifiers included) and an end tag's skipped part end.
    private static func greaterThan(_ bytes: [UInt8], from position: Int) -> Int {
        guard position < bytes.count else { return bytes.count }
        return bytes[position...].firstIndex(of: 0x3E).map { $0 + 1 } ?? bytes.count
    }

    /// HTML Standard, tag open state through the attribute states: a start or end tag at
    /// `position`, or `nil` where the input ends inside it (the tag is then not emitted).
    private static func tag(_ bytes: [UInt8], at position: Int) -> Tag? {
        let closing = bytes[position + 1] == 0x2F
        var index = position + (closing ? 2 : 1)
        var name: [UInt8] = []
        while index < bytes.count, !space(bytes[index]), bytes[index] != 0x2F, bytes[index] != 0x3E {
            name.append(lower(bytes[index])); index += 1
        }
        var attributes: [([UInt8], [UInt8])] = []
        var selfClosing = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3E { return Tag(end: index + 1, closing: closing, name: name, selfClosing: selfClosing, attributes: attributes) }
            if space(byte) { selfClosing = false; index += 1; continue }
            if byte == 0x2F { selfClosing = true; index += 1; continue }
            selfClosing = false
            // Attribute name: the first byte, even "=", then up to white space, "/", ">" or "=".
            var attribute = [lower(byte)]
            index += 1
            while index < bytes.count, !space(bytes[index]), ![0x2F, 0x3E, 0x3D].contains(bytes[index]) {
                attribute.append(lower(bytes[index])); index += 1
            }
            var after = index
            while after < bytes.count, space(bytes[after]) { after += 1 }
            guard after < bytes.count, bytes[after] == 0x3D else { attributes.append((attribute, [])); continue }
            index = after + 1
            while index < bytes.count, space(bytes[index]) { index += 1 }
            var value: [UInt8] = []
            if index < bytes.count, bytes[index] == 0x22 || bytes[index] == 0x27 {
                let quote = bytes[index]
                guard let close = bytes[(index + 1)...].firstIndex(of: quote) else { return nil }
                value = Array(bytes[(index + 1)..<close])
                index = close + 1
            } else {
                while index < bytes.count, !space(bytes[index]), bytes[index] != 0x3E { value.append(bytes[index]); index += 1 }
            }
            attributes.append((attribute, value))
        }
        return nil
    }

    /// HTML Standard, script data states with their escapes: the index of the `<` of the end tag
    /// that ends script data begun at `position`, or the input's end. Inside `<!--` a `<script`
    /// begins a double escape, where `</script>` ends only that escape.
    private static func scriptDataEnd(_ bytes: [UInt8], from position: Int) -> Int {
        enum State { case data, escaped, escapedDash, escapedDashDash, doubleEscaped, doubleEscapedDash, doubleEscapedDashDash }
        var state = State.data
        var index = position
        while index < bytes.count {
            let byte = bytes[index]
            switch state {
            case .data:
                if byte == 0x3C {
                    if endTag(bytes, script, at: index) { return index }
                    if starts(bytes, commentOpen, at: index) { state = .escapedDashDash; index += 4; continue }
                }
            case .escaped, .escapedDash, .escapedDashDash:
                if byte == 0x2D {
                    state = state == .escaped ? .escapedDash : .escapedDashDash
                } else if byte == 0x3C {
                    if endTag(bytes, script, at: index) { return index }
                    state = .escaped
                    if let after = doubleEscape(bytes, at: index + 1) { state = .doubleEscaped; index = after; continue }
                } else if byte == 0x3E, state == .escapedDashDash {
                    state = .data
                } else {
                    state = .escaped
                }
            case .doubleEscaped, .doubleEscapedDash, .doubleEscapedDashDash:
                if byte == 0x2D {
                    state = state == .doubleEscaped ? .doubleEscapedDash : .doubleEscapedDashDash
                } else if byte == 0x3C {
                    state = .doubleEscaped
                    if index + 1 < bytes.count, bytes[index + 1] == 0x2F, let after = doubleEscape(bytes, at: index + 2) {
                        state = .escaped; index = after; continue
                    }
                } else if byte == 0x3E, state == .doubleEscapedDashDash {
                    state = .data
                } else {
                    state = .doubleEscaped
                }
            }
            index += 1
        }
        return bytes.count
    }

    /// Script data double escape start and end states: `script` (any case) at `position`, then
    /// white space, `/` or `>`; the index of that last byte, which is read in the new state.
    private static func doubleEscape(_ bytes: [UInt8], at position: Int) -> Int? {
        let after = position + script.count
        guard matches(bytes, script, at: position), after < bytes.count,
              space(bytes[after]) || bytes[after] == 0x2F || bytes[after] == 0x3E else { return nil }
        return after
    }

    /// RAWTEXT and RCDATA: the `<` of the first end tag named `name` followed by white space,
    /// `/` or `>`, or the input's end.
    private static func rawTextEnd(_ bytes: [UInt8], _ name: [UInt8], from position: Int) -> Int {
        var index = position
        while index < bytes.count, let open = bytes[index...].firstIndex(of: 0x3C) {
            if endTag(bytes, name, at: open) { return open }
            index = open + 1
        }
        return bytes.count
    }

    /// An appropriate end tag: `</name`, any case, then white space, `/` or `>`.
    private static func endTag(_ bytes: [UInt8], _ name: [UInt8], at position: Int) -> Bool {
        let after = position + 2 + name.count
        return bytes[position] == 0x3C && position + 1 < bytes.count && bytes[position + 1] == 0x2F
            && matches(bytes, name, at: position + 2) && after < bytes.count
            && (space(bytes[after]) || bytes[after] == 0x2F || bytes[after] == 0x3E)
    }

    /// HTML Standard, parsing tokens in foreign content, an end tag: `</p>` and `</br>` leave
    /// SVG and MathML content; another end tag closes the nearest open element of its name.
    /// `false` where the tag reaches HTML content, whose effect the map does not follow.
    private static func closeForeign(_ foreign: inout [Foreign], _ name: [UInt8]) -> Bool {
        if equals(name, "p") || equals(name, "br") {
            guard foreign.last?.integrationPoint == false else { return false }
            foreign.removeAll()
            return true
        }
        if let open = foreign.lastIndex(where: { $0.name == name }) {
            foreign.removeSubrange(open...)
            return true
        }
        // In body, `</body>` and `</html>` close nothing.
        return equals(name, "body") || equals(name, "html")
    }

    /// The start tags that end SVG and MathML content.
    private static func breaksOut(_ tag: Tag) -> Bool {
        let name = String(decoding: tag.name, as: UTF8.self)
        if name == "font" {
            return tag.attributes.contains { ["color", "face", "size"].contains(String(decoding: $0.0, as: UTF8.self)) }
        }
        return ["b", "big", "blockquote", "body", "br", "center", "code", "dd", "div", "dl", "dt", "em", "embed",
                "h1", "h2", "h3", "h4", "h5", "h6", "head", "hr", "i", "img", "li", "listing", "menu", "meta",
                "nobr", "ol", "p", "pre", "ruby", "s", "small", "span", "strong", "strike", "sub", "sup",
                "table", "tt", "u", "ul", "var"].contains(name)
    }

    /// HTML and MathML text integration points, where HTML reads start tags as HTML.
    private static func integrationPoint(_ tag: Tag, mathML: Bool) -> Bool {
        let name = String(decoding: tag.name, as: UTF8.self)
        if !mathML { return ["foreignobject", "desc", "title"].contains(name) }
        if ["mi", "mo", "mn", "ms", "mtext"].contains(name) { return true }
        guard name == "annotation-xml" else { return false }
        return tag.attributes.contains { attribute in
            String(decoding: attribute.0, as: UTF8.self) == "encoding"
                && ["text/html", "application/xhtml+xml"].contains(String(decoding: attribute.1.map(lower), as: UTF8.self))
        }
    }

    private static func letter(_ byte: UInt8) -> Bool { byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7A }
    private static func space(_ byte: UInt8) -> Bool { [0x09, 0x0A, 0x0C, 0x0D, 0x20].contains(byte) }
    private static func lower(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte }
    private static func equals(_ name: [UInt8], _ string: String) -> Bool { name.elementsEqual(string.utf8) }
    private static func starts(_ bytes: [UInt8], _ token: [UInt8], at position: Int) -> Bool {
        position + token.count <= bytes.count && bytes[position..<position + token.count].elementsEqual(token)
    }
    /// ASCII case-insensitive; `token` is lowercase.
    private static func matches(_ bytes: [UInt8], _ token: [UInt8], at position: Int) -> Bool {
        position + token.count <= bytes.count
            && zip(bytes[position..<position + token.count], token).allSatisfy { lower($0) == $1 }
    }
    private static func find(_ bytes: [UInt8], _ token: [UInt8], from position: Int) -> Int? {
        var index = position
        while index + token.count <= bytes.count {
            if starts(bytes, token, at: index) { return index }
            index += 1
        }
        return nil
    }
}
