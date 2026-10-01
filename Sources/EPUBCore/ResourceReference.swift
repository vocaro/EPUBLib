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
}
