import EPUBCore
import EPUBReading
import Foundation

// Ports foliate-js `epub.js` (MIT License, Copyright (c) 2022 John Factotum): the spine CFIs of
// `Resources` (`CFI.fromElements($$itemref)`), `EPUB.resolveCFI` and `View.getCFI`, as vendored at
// `Sources/EPUBViewing/Resources/epub-reader/lib/`.

/// The package half of CFIs: each spine item's step path in the OPF document
/// (`epubcfi(/6/4[itemref-id])`), as foliate's `CFI.fromElements($$itemref)` computes it.
struct SpineCFIs: Sendable {
    /// `bases[i]` is spine item `i`'s CFI, e.g. `epubcfi(/6/4)`.
    let bases: [String]
    /// The OPF and its spine's `itemref`s, or nil when the bases are foliate's fake `/6/N` ones.
    private let package: (document: ContentDocument, itemrefs: [ContentNode])?

    private static let containerNamespace = "urn:oasis:names:tc:opendocument:xmlns:container"

    /// Parses `META-INF/container.xml` and the OPF from the publication's own bytes. When they
    /// cannot be read as foliate read them, every base is foliate's fake `epubcfi(/6/N)`.
    init(publication: EPUBPublication) throws {
        self.init(package: Self.packageDocument(of: publication), spineCount: publication.spine.count)
    }

    /// `package` is the OPF document; the bases are fake unless its spine has `spineCount` itemrefs.
    init(package: ContentDocument?, spineCount: Int) {
        if let package, let itemrefs = Self.itemrefs(in: package), itemrefs.count == spineCount {
            let bases = EPUBCFI.fromElements(itemrefs)
            if bases.count == itemrefs.count {
                self.bases = bases
                self.package = (package, itemrefs)
                return
            }
        }
        bases = (0..<max(spineCount, 0)).map(Self.fakeBase)
        self.package = nil
    }

    /// foliate `CFI.fake.fromIndex`.
    static func fakeBase(_ index: Int) -> String { "epubcfi(/6/\((index + 1) * 2))" }

    /// foliate `EPUB.init`: the first `rootfile` in the container namespace whose media type is
    /// the package's, parsed as XML.
    private static func packageDocument(of publication: EPUBPublication) -> ContentDocument? {
        let containerPath = "META-INF/container.xml"
        guard let data = try? publication.data(at: containerPath),
              let container = try? ContentDocument.parse(data, path: containerPath), !container.recoveredAsHTML,
              let rootfile = container.nodes.first(where: {
                  $0.isElement && $0.name == "rootfile" && $0.namespace == containerNamespace
                      && $0.attribute("media-type") == "application/oebps-package+xml"
              }),
              let path = rootfile.attribute("full-path"), let opf = try? publication.data(at: path),
              let document = try? ContentDocument.parse(opf, path: path), !document.recoveredAsHTML
        else { return nil }
        return document
    }

    /// foliate `Resources`: the spine is the root's first `spine` child and its `itemref`
    /// children, in the OPF namespace when the package element uses it (`childGetter`'s
    /// `useNS`), else by local name alone.
    private static func itemrefs(in package: ContentDocument) -> [ContentNode]? {
        let useNamespace = package.root.namespace == ContentNamespace.opf
        func matches(_ node: ContentNode, _ name: String) -> Bool {
            node.isElement && node.name == name && (!useNamespace || node.namespace == ContentNamespace.opf)
        }
        guard let spine = package.root.children.first(where: { matches($0, "spine") }) else { return nil }
        let itemrefs = spine.children.filter { matches($0, "itemref") }
        return itemrefs.isEmpty ? nil : itemrefs
    }

    /// A full CFI for a range in spine item `index` (foliate `getCFI`).
    func cfi(spineIndex: Int, start: DOMPosition, end: DOMPosition, in document: ContentDocument) -> String {
        let base = bases.indices.contains(spineIndex) ? bases[spineIndex] : Self.fakeBase(spineIndex)
        return EPUBCFI.joinIndirections(base, EPUBCFI.wrap(EPUBCFI.localPath(from: start, to: end, in: document)))
    }

    /// The spine index and local path a full CFI names (foliate `resolveCFI`), retrying without
    /// the itemref ID assertion as foliate does. nil when it names no spine item.
    ///
    /// foliate's retry compares the found element's `nodeName` with `'idref'`, which never
    /// matches, so the package path always resolves by its indices alone; the element found
    /// names the first spine item with the same `idref`. The local path is empty for a CFI that
    /// names only a spine item, which foliate could not resolve within the section.
    func resolve(_ cfi: String) -> (spineIndex: Int, localPath: String)? {
        guard let expression = try? EPUBCFI.parse(cfi) else { return nil }
        var paths = expression.parent ?? expression.path ?? []
        guard !paths.isEmpty else { return nil }
        let top = paths.removeFirst()
        let index: Int
        if let package {
            guard let element = EPUBCFI.element(at: top, in: package.document) else { return nil }
            let idref = element.attribute("idref")
            guard let found = package.itemrefs.firstIndex(where: { $0.attribute("idref") == idref }) else { return nil }
            index = found
        } else {
            // foliate `CFI.fake.toIndex`.
            guard let last = top.last, last.index % 2 == 0, bases.indices.contains(last.index / 2 - 1) else { return nil }
            index = last.index / 2 - 1
        }
        guard expression.isRange else { return (index, EPUBCFI.pathString(paths)) }
        guard !paths.isEmpty else { return (index, "") }
        return (index, EPUBCFI.innerString(.init(parent: paths, start: expression.start, end: expression.end)))
    }
}
