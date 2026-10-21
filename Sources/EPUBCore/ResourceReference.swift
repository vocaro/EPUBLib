import Foundation

/// Archive paths and the URL references that name them. A delimiter is its byte wherever it
/// stands: as a `Character`, `/` or `:` before a combining mark is another character and would
/// go unseen.
package enum ResourceReference {
    /// Whether a path may be written into an archive: relative, without empty or dot segments, and
    /// free of what other systems read as a separator (`\`, `:`) or a terminator (NUL).
    package static func isSafePath(_ path: String, directory: Bool = false) -> Bool {
        !path.utf8.contains(0x3A) && isReadablePath(path, directory: directory) // :
    }

    /// Whether an archive being read may name an entry by this path. As `isSafePath`, except that a
    /// colon is an ordinary character, like the others OCF forbids in a file name (`?`, `*`): the
    /// snapshot is looked up by key and never written to a file system.
    package static func isReadablePath(_ path: String, directory: Bool = false) -> Bool {
        var bytes = path.utf8[...]
        if directory, bytes.last == 0x2F { bytes = bytes.dropLast() } // /
        return !bytes.isEmpty && !bytes.contains(0x5C) && !bytes.contains(0) // \
            && bytes.split(separator: 0x2F, omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && !$0.elementsEqual(dot) && !$0.elementsEqual(dotDot)
            }
    }

    /// Whether a reference names something outside the container, as URL parsing reads it: past
    /// the tabs, newlines and leading spaces it drops, the reference starts with a scheme
    /// (`https:`, `data:`) or, written `//host/…`, with an authority. Nothing it names is ever
    /// fetched.
    package static func isRemote(_ href: String) -> Bool {
        let bytes = href.utf8.filter { $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }.drop { $0 <= 0x20 }
        if bytes.starts(with: [0x2F, 0x2F]) { return true }
        func isLetter(_ byte: UInt8) -> Bool { byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7A }
        guard let first = bytes.first, isLetter(first), let colon = bytes.firstIndex(of: 0x3A) else { return false }
        return bytes[..<colon].allSatisfy { isLetter($0) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2B || $0 == 0x2D || $0 == 0x2E } // + - .
    }

    /// A decoded archive path as a URL reference that resolves to itself from the container root.
    /// A colon is escaped, so that a first segment holding one is not read as a scheme.
    package static func encoded(path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: pathAllowed)!
    }
    private static let pathAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "#%?:"))
    private static let dot: [UInt8] = [0x2E], dotDot: [UInt8] = [0x2E, 0x2E]

    /// A reference without the white space round it, which URL parsing strips: the C0 controls and
    /// spaces at its ends. An HTML `href` is a URL "potentially surrounded by spaces", and tools
    /// that wrap attributes leave them. White space outside ASCII (a no-break space), white space
    /// written as an escape (`%20`), and a tab or newline inside the reference are characters of
    /// it, as they are of one about to be written.
    private static func stripped(_ href: String) -> String {
        let bytes = href.utf8
        guard let first = bytes.firstIndex(where: { $0 > 0x20 }), let last = bytes.lastIndex(where: { $0 > 0x20 }) else { return "" }
        return String(decoding: bytes[first...last], as: UTF8.self)
    }

    /// Resolves a local EPUB reference as EPUB Reading Systems 3.3 §4.1.1 has it parsed against
    /// the container root URL: white space round it is read past (`stripped`), a leading `/` names
    /// the root and `..` stops there, so no reference leaves the container. A query is dropped; it
    /// cannot change which entry is meant. A remote reference, and one that does not decode to a
    /// path an entry can have, throw.
    ///
    /// `strict` is for a reference about to be written. What EPUB forbids its author (white space
    /// round it, a leading `/`, `..` beyond the root, a query, a colon in the path) is then
    /// refused, not read past.
    package static func resolve(_ href: String, relativeTo path: String, strict: Bool = false) throws -> String {
        let unsafe = EPUBPublicationError.unsafePath(href)
        let reference = stripped(href)
        guard !strict || reference.utf8.elementsEqual(href.utf8) else { throw unsafe }
        let raw = reference.utf8
        let hash = raw.firstIndex(of: 0x23) ?? raw.endIndex // #
        let query = raw[..<hash].firstIndex(of: 0x3F) ?? hash // ?
        func isPlain(_ text: String) -> Bool { !text.utf8.contains(0x5C) && !text.utf8.contains(0) }
        guard !isRemote(href), !strict || query == hash,
              let target = String(decoding: raw[..<query], as: UTF8.self).removingPercentEncoding,
              let fragment = String(decoding: raw[hash...].dropFirst(), as: UTF8.self).removingPercentEncoding,
              isPlain(target), isPlain(fragment) else { throw unsafe }
        let absolute = target.utf8.first == 0x2F
        let base = path.utf8.split(separator: 0x2F).map { String(decoding: $0, as: UTF8.self) }
        guard !strict || !absolute else { throw unsafe }
        var stack = absolute ? [] : Array(base.dropLast())
        if target.isEmpty {
            // The document itself, which a reference from nowhere cannot name.
            guard let document = base.last else { throw unsafe }
            stack.append(document)
        } else {
            for part in target.utf8.split(separator: 0x2F) {
                if part.elementsEqual(dot) { continue }
                if part.elementsEqual(dotDot) {
                    // The root has no parent to step up to.
                    if !stack.isEmpty { stack.removeLast() } else if strict { throw unsafe }
                } else { stack.append(String(decoding: part, as: UTF8.self)) }
            }
        }
        let result = stack.joined(separator: "/")
        guard strict ? isSafePath(result) : isReadablePath(result) else { throw unsafe }
        return encoded(path: result) + (hash == raw.endIndex ? "" : "#" + fragment.addingPercentEncoding(
            withAllowedCharacters: .urlFragmentAllowed.subtracting(CharacterSet(charactersIn: "#%")))!)
    }

    /// The archive path of the package document a container rootfile's `full-path` names, nil when
    /// it names none; `isEntry` says whether the archive holds a path.
    ///
    /// The value has two readings. It is a URL from the container root (EPUB 3.3 §4.2.6.3.1.3),
    /// so it is first resolved as a manifest href is, from a file in that root, and judged as an
    /// archive path only once percent-decoded. It names a file, so that reading refuses a
    /// fragment and a path that is a folder's or no archive name: an empty segment (a doubled,
    /// leading or closing slash) or a closing dot segment. Nor is it read past what a manifest
    /// href is: a query and a step above the container root were refused in a rootfile before and
    /// still are. But older validators looked the value up as written and refused the escaped
    /// form, so books carry a name's own "%", "#" or "?" unescaped: where the URL reading is
    /// refused or names no entry, the value as written is taken if it is a path an entry can
    /// have that names one. It is a key into the archive read into memory, and no other entry's.
    /// Failing both, the URL reading's path is returned for the caller to report as missing.
    package static func rootfilePath(_ fullPath: String, isEntry: (String) -> Bool) -> String? {
        var url: String?
        // Judged past the white space round it, as it is resolved. An empty value, or one of white
        // space alone, would resolve to the base itself.
        let value = stripped(fullPath)
        if !value.isEmpty, !value.utf8.contains(0x3F), // ?
           let reference = try? resolve(value, relativeTo: "mimetype"), !reference.contains("#"),
           let written = value.removingPercentEncoding?.utf8.split(separator: 0x2F, omittingEmptySubsequences: false),
           !written.contains(where: \.isEmpty), let name = written.last, !name.elementsEqual(dot), !name.elementsEqual(dotDot) {
            // Every `..` has a folder of the path to step out of.
            var depth = 0
            let inside = written.allSatisfy { segment in
                depth += segment.elementsEqual(dotDot) ? -1 : segment.elementsEqual(dot) ? 0 : 1
                return depth >= 0
            }
            if inside { url = reference.removingPercentEncoding }
        }
        if let url, isEntry(url) { return url }
        if isReadablePath(fullPath), isEntry(fullPath) { return fullPath }
        return url
    }
}
