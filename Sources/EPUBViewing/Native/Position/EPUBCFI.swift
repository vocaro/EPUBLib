import EPUBCore
import EPUBReading
import Foundation

// SKELETON: API for the Swift port of foliate-js `epubcfi.js` (MIT). The positions workstream
// implements it; the session calls only what is declared here.

/// EPUB Canonical Fragment Identifiers, generated and resolved exactly as foliate-js does, so
/// `epubcfi-v1` bookmarks and highlight locators saved by the WebKit reader keep resolving.
enum EPUBCFI {
    /// A parsed CFI: one path per indirection (`!`), or a range with a common parent.
    struct Expression: Equatable, Sendable {
        struct Step: Equatable, Sendable {
            var index: Int
            var id: String?
            var offset: Int?
            var temporal: Double?
            var spatial: [Double]?
            var text: [String]?
            var side: String?
        }
        /// `paths[0]` is the package path, `paths[1]` the content-document path.
        typealias Path = [[Step]]
        var path: Path?
        var parent: Path?
        var start: Path?
        var end: Path?
        var isRange: Bool { parent != nil }
    }

    static func isCFI(_ string: String) -> Bool { string.hasPrefix("epubcfi(") && string.hasSuffix(")") }
    static func parse(_ string: String) throws -> Expression { throw EPUBReaderError.incompatibleLocation }
    static func string(_ expression: Expression) -> String { "" }
    /// foliate `compare`: -1, 0 or 1 in reading order.
    static func compare(_ a: String, _ b: String) -> Int { 0 }
    /// foliate `collapse`: a range's start (or end) as a position CFI.
    static func collapse(_ string: String, toEnd: Bool = false) -> String { string }

    /// foliate `fromRange` within one content document: a local path (no `epubcfi(` wrapper, no
    /// package step), a position when `start == end`, else a range.
    static func localPath(from start: DOMPosition, to end: DOMPosition, in document: ContentDocument) -> String { "" }
    /// foliate `toRange` for a local path. nil when it names nothing in `document`.
    static func resolve(localPath: String, in document: ContentDocument) -> (start: DOMPosition, end: DOMPosition)? { nil }
}

/// The package half of CFIs: each spine item's step path in the OPF document
/// (`epubcfi(/6/4[itemref-id])`), as foliate's `CFI.fromElements($$itemref)` computes it.
struct SpineCFIs: Sendable {
    /// `bases[i]` is spine item `i`'s CFI, e.g. `epubcfi(/6/4)`.
    let bases: [String]

    /// Parses `META-INF/container.xml` and the OPF from the publication's own bytes.
    init(publication: EPUBPublication) throws {
        bases = publication.spine.indices.map { "epubcfi(/6/\(($0 + 1) * 2))" }
    }

    /// A full CFI for a range in spine item `index` (foliate `getCFI`).
    func cfi(spineIndex: Int, start: DOMPosition, end: DOMPosition, in document: ContentDocument) -> String {
        bases[spineIndex]
    }

    /// The spine index and local path a full CFI names (foliate `resolveCFI`), retrying without
    /// the itemref ID assertion as foliate does. nil when it names no spine item.
    func resolve(_ cfi: String) -> (spineIndex: Int, localPath: String)? { nil }
}
