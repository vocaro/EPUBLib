import Foundation

/// Paths and references are read here by Unicode scalar, as an archive and a file system read
/// them, and never by `Character`: a "/", "\", ":", "#" or "." shares its `Character` with a
/// combining mark, variation selector or joiner that follows it and with a prepended mark such
/// as U+0600 before it. `"../\u{301}x"` is then one name with no "/" in it.
package enum ResourceReference {
    private static let dot = ".".unicodeScalars, dotDot = "..".unicodeScalars

    package static func isSafePath(_ path: String, directory: Bool = false) -> Bool {
        let path = directory && path.unicodeScalars.last == "/" ? path.unicodeScalars.dropLast() : path.unicodeScalars[...]
        return !path.isEmpty && !path.contains(where: { $0 == "\\" || $0 == ":" || $0 == "\0" })
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && !$0.elementsEqual(dot) && !$0.elementsEqual(dotDot)
            }
    }

    /// Resolve local EPUB references with a synthetic origin; escape the archive root only by failing.
    /// The result is ASCII, where a `Character` is one scalar, so it may be cut at its "#" either way.
    package static func resolve(_ href: String, relativeTo path: String) throws -> String {
        guard let decoded = href.removingPercentEncoding?.unicodeScalars,
              !decoded.contains(where: { $0 == "\\" || $0 == "\0" }), decoded.first != "/",
              URLComponents(string: href)?.scheme == nil,
              URLComponents(string: href)?.query == nil else { throw EPUBPublicationError.unsafePath(href) }
        let rawParts = href.unicodeScalars.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let parts = rawParts.map { String($0).removingPercentEncoding! }
        let base = path.unicodeScalars.split(separator: "/")
        var stack = base.dropLast().map { String($0) }
        if parts[0].isEmpty { stack.append(String(base.last!)) }
        else {
            for part in parts[0].unicodeScalars.split(separator: "/") {
                if part.elementsEqual(dot) { continue }
                if part.elementsEqual(dotDot) {
                    guard !stack.isEmpty else { throw EPUBPublicationError.unsafePath(href) }
                    stack.removeLast()
                } else { stack.append(String(part)) }
            }
        }
        let result = stack.joined(separator: "/")
        guard isSafePath(result) else { throw EPUBPublicationError.unsafePath(href) }
        let encoded = result.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "#%?")))!
        let fragment = parts.count == 2 ? "#" + parts[1].addingPercentEncoding(
            withAllowedCharacters: .urlFragmentAllowed.subtracting(CharacterSet(charactersIn: "#%")))! : ""
        return encoded + fragment
    }

    /// The archive path of the package document a container rootfile's `full-path` names, nil when
    /// it names none; `isEntry` says whether the archive holds a path.
    ///
    /// The value has two readings. It is a URL from the container root (EPUB 3.3 §4.2.6.3.1.3),
    /// so it is first resolved as a manifest href is, from a file in that root, and judged as an
    /// archive path only once percent-decoded. It names a file, so that reading refuses a query, a
    /// fragment, and a path that is a folder's or no archive name: an empty segment (a doubled or
    /// closing slash) or a closing dot segment. But older validators looked the value up as
    /// written and refused the escaped form, so books carry a name's own "%", "#" or "?"
    /// unescaped: where the URL reading is refused or names no entry, the value as written is
    /// taken if it is a safe path that names one. It is a key into the archive read into memory,
    /// and no other entry's. Failing both, the URL reading's path is returned for the caller to
    /// report as missing.
    package static func rootfilePath(_ fullPath: String, isEntry: (String) -> Bool) -> String? {
        var url: String?
        // An empty value would resolve to the base itself.
        if !fullPath.isEmpty, let reference = try? resolve(fullPath, relativeTo: "mimetype"), !reference.contains("#"),
           let written = fullPath.removingPercentEncoding?.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false),
           let last = written.last, !written.contains(where: \.isEmpty), !last.elementsEqual(dot), !last.elementsEqual(dotDot) {
            url = reference.removingPercentEncoding
        }
        if let url, isEntry(url) { return url }
        if isSafePath(fullPath), isEntry(fullPath) { return fullPath }
        return url
    }
}
