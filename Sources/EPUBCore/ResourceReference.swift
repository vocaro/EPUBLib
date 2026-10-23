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

    /// A URL path's segments as URL parsing has them: split at each `/` written as one, and only
    /// then decoded, so that an escaped slash (`%2F`) is a character of its segment and `%2E%2E`
    /// is the `..` it spells. Nil when a segment does not decode.
    private static func segments(_ path: some Collection<UInt8>) -> [String]? {
        var names: [String] = []
        for segment in path.split(separator: 0x2F, omittingEmptySubsequences: false) { // /
            guard let name = String(decoding: segment, as: UTF8.self).removingPercentEncoding else { return nil }
            names.append(name)
        }
        return names
    }

    /// The archive path an encoded path names, its segments decoded as `resolve` decodes them
    /// (`segments`). Nil when a segment does not decode, or holds a `/` once decoded, which no
    /// entry's name can: `OPS%2Fone.xhtml` names a file of that name in the container root, not
    /// `OPS/one.xhtml`.
    package static func decodedPath(_ path: some Collection<UInt8>) -> String? {
        guard let names = segments(path), !names.contains(where: { $0.utf8.contains(0x2F) }) else { return nil } // /
        return names.joined(separator: "/")
    }

    /// Resolves a local EPUB reference as EPUB Reading Systems 3.3 §4.1.1 has it parsed against
    /// the container root URL: white space round it is read past (`stripped`), a leading `/` names
    /// the root and `..` stops there, so no reference leaves the container. The reference is
    /// split as URL parsing splits it, at the delimiters written as themselves, before anything
    /// is decoded: the fragment at the first `#`, the query at the first `?` before it, and the
    /// path at each `/` (`segments`). A delimiter written as an escape is a character of its part,
    /// so `a%2Fb.xhtml` is one segment, whose name no entry can have, and is refused as a name
    /// holding a backslash is. An empty segment (a doubled slash), in the reference or its base,
    /// is a segment as URL parsing has it, so a `..` after one removes it and not the name before
    /// it; one that remains, which no entry's path has, is read past. A query is dropped; it
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
        guard !isRemote(href), !strict || query == hash, let target = segments(raw[..<query]),
              target.allSatisfy({ isPlain($0) && !$0.utf8.contains(0x2F) }),
              let fragment = String(decoding: raw[hash...].dropFirst(), as: UTF8.self).removingPercentEncoding,
              isPlain(fragment) else { throw unsafe }
        let absolute = raw[..<query].first == 0x2F
        let base = path.utf8.split(separator: 0x2F, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard !strict || !absolute else { throw unsafe }
        var stack = absolute ? [] : Array(base.dropLast())
        if query == raw.startIndex {
            // The document itself, which a reference from nowhere cannot name.
            guard !path.isEmpty, let document = base.last else { throw unsafe }
            stack.append(document)
        } else {
            // The slash that opens an absolute reference has no segment before it.
            for part in target.dropFirst(absolute ? 1 : 0) {
                if part.utf8.elementsEqual(dot) { continue }
                if part.utf8.elementsEqual(dotDot) {
                    // The root has no parent to step up to.
                    if !stack.isEmpty { stack.removeLast() } else if strict { throw unsafe }
                } else { stack.append(part) }
            }
        }
        // An empty segment no `..` removed names no entry, and is read past.
        let result = stack.filter { !$0.isEmpty }.joined(separator: "/")
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
           let written = segments(value.utf8), !written.contains(where: \.isEmpty), let name = written.last?.utf8,
           !name.elementsEqual(dot), !name.elementsEqual(dotDot) {
            // Every `..` has a folder of the path to step out of.
            var depth = 0
            let inside = written.allSatisfy { segment in
                depth += segment.utf8.elementsEqual(dotDot) ? -1 : segment.utf8.elementsEqual(dot) ? 0 : 1
                return depth >= 0
            }
            if inside { url = reference.removingPercentEncoding }
        }
        if let url, isEntry(url) { return url }
        if isReadablePath(fullPath), isEntry(fullPath) { return fullPath }
        return url
    }

    /// The archive path of the entry a URL in a file of `META-INF` names, such as an encrypted
    /// file's `CipherReference` URI, nil when it names none; `isEntry` says whether the archive
    /// holds a path.
    ///
    /// EPUB 3.3 §4.2.6.2 has such a URL parsed with the container root URL as its base. It is
    /// resolved as a manifest href is, from that root, and judged as an archive path only once
    /// decoded: an escaped slash (`%2F`) is a character of its segment, which no entry's name
    /// can hold, and a dot segment, a leading `/` and a query are resolved as URL parsing
    /// resolves them. A fragment is dropped, as a query is; neither changes which file is meant.
    /// But EPUBCheck before version 5 decoded the whole value and looked that up, so a book may
    /// carry a name's own `#` or `?` unescaped: where the URL reading is refused or names no
    /// entry, the value as written is taken if it is a path an entry can have that names one, as
    /// `rootfilePath` takes a rootfile's. With an entry under each reading, the URL's is meant.
    package static func containerPath(_ url: String, isEntry: (String) -> Bool) -> String? {
        // From the root itself, not a file in it, so that a URL with no path, which names the
        // root, is refused rather than taken for that file.
        if let reference = try? resolve(url, relativeTo: ""),
           let path = String(reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]).removingPercentEncoding,
           isEntry(path) {
            return path
        }
        return isReadablePath(url) && isEntry(url) ? url : nil
    }
}
