import Foundation

package enum ResourceReference {
    package static func isSafePath(_ path: String, directory: Bool = false) -> Bool {
        let path = directory && path.hasSuffix("/") ? String(path.dropLast()) : path
        return !path.isEmpty && !path.contains("\\") && !path.contains(":") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    /// Resolve local EPUB references with a synthetic origin; escape the archive root only by failing.
    package static func resolve(_ href: String, relativeTo path: String) throws -> String {
        guard let decoded = href.removingPercentEncoding, !decoded.contains("\\"),
              !decoded.contains("\0"), !decoded.hasPrefix("/"),
              URLComponents(string: href)?.scheme == nil,
              URLComponents(string: href)?.query == nil else { throw EPUBPublicationError.unsafePath(href) }
        let rawParts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let parts = rawParts.map { String($0).removingPercentEncoding! }
        var stack = path.split(separator: "/").dropLast().map(String.init)
        if parts[0].isEmpty { stack.append(String(path.split(separator: "/").last!)) }
        else {
            for part in parts[0].split(separator: "/") {
                if part == "." { continue }
                if part == ".." {
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
           let written = fullPath.removingPercentEncoding?.split(separator: "/", omittingEmptySubsequences: false),
           !written.contains(""), written.last != ".", written.last != ".." {
            url = reference.removingPercentEncoding
        }
        if let url, isEntry(url) { return url }
        if isSafePath(fullPath), isEntry(fullPath) { return fullPath }
        return url
    }
}
