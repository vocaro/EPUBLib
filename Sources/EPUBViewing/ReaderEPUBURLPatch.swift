import Foundation

/// A small, fail-closed compatibility patch over the pinned, unmodified upstream source.
/// Foliate mixes decoded paths and URL references and decodes TOC references twice. Keep
/// references encoded throughout the renderer; the ZIP adapter decodes once at byte lookup.
enum ReaderEPUBURLPatch {
    static func apply(to data: Data) throws -> Data {
        guard var source = String(data: data, encoding: .utf8) else { throw Failure.sourceChanged }
        let replacements: [(String, String, Int)] = [
            ("decodeURI(obj.href.replace(root, ''))",
             "decodeURIComponent(obj.pathname).slice(1).split('/').map(encodeURIComponent).join('/') + obj.hash", 1),
            ("href ? decodeURI(resolve(href)) : null", "href ? resolve(href) : null", 2),
            ("const opfPath = opfs[0].fullPath", "const opfPath = opfs[0].fullPath.split('/').map(encodeURIComponent).join('/')", 1),
            ("getItemByHref(decodeURI(path))", "getItemByHref(resolveURL(path, ''))", 1),
            ("getHTMLFragment(doc, hash)", "getHTMLFragment(doc, decodeURIComponent(hash))", 1),
            ("getTOCFragment(doc, id) {", "getTOCFragment(doc, id) {\n        id = decodeURIComponent(id)", 1),
        ]
        for (old, new, count) in replacements {
            guard source.components(separatedBy: old).count == count + 1 else { throw Failure.sourceChanged }
            source = source.replacingOccurrences(of: old, with: new)
        }
        return Data(source.utf8)
    }
    enum Failure: Error { case sourceChanged }
}
