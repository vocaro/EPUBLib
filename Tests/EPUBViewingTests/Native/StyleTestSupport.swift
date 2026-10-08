import EPUBCore
import EPUBReading
import EPUBTestSupport
@testable import EPUBViewing
import Foundation

/// A content document styled the way the builder styles it: every element in document order,
/// parents first.
struct StyledDocument {
    let document: ContentDocument
    let resolver: StyleResolver
    let report: SectionReport
    let sheets: [CSSStyleSheet]
    let styles: [Int: ComputedStyle]

    func style(_ id: String) -> ComputedStyle {
        guard let node = document.element(id: id), let style = styles[node.order] else { fatalError("No element #\(id)") }
        return style
    }
}

enum StyleTestSupport {
    static func xhtml(body: String, head: String = "", css: String = "") -> String {
        """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xmlns:m="http://www.w3.org/1998/Math/MathML" lang="en"><head><title>T</title>\(head)\(css.isEmpty ? "" : "<style><![CDATA[\(css)]]></style>")</head><body>\(body)</body></html>
        """
    }

    /// A book whose first section is `section`, with extra archive files under `OPS/`.
    static func publication(section: String, files: [String: Data] = [:]) throws -> EPUBPublication {
        var archive = try Fixture.files()
        archive["OPS/one.xhtml"] = Data(section.utf8)
        for (path, data) in files { archive["OPS/" + path] = data }
        return try EPUBPublication.open(data: Fixture.archive(archive))
    }

    static func styled(_ body: String, css: String = "", head: String = "", files: [String: String] = [:],
                       typography: NativeTypography = NativeTypography(fontSize: 16)) throws -> StyledDocument {
        try styled(section: xhtml(body: body, head: head, css: css), files: files.mapValues { Data($0.utf8) }, typography: typography)
    }

    static func styled(section: String, files: [String: Data], typography: NativeTypography) throws -> StyledDocument {
        let book = try publication(section: section, files: files)
        let document = try ContentDocument.parse(Data(section.utf8), path: "OPS/one.xhtml")
        var report = SectionReport()
        let sheets = SectionStyles.load(for: document, publication: book, report: &report)
        let resolver = StyleResolver(document: document, stylesheets: sheets, typography: typography)
        return StyledDocument(document: document, resolver: resolver, report: report, sheets: sheets,
                              styles: styleAll(document, resolver))
    }

    static func styleAll(_ document: ContentDocument, _ resolver: StyleResolver) -> [Int: ComputedStyle] {
        var styles: [Int: ComputedStyle] = [:]
        for node in document.nodes where node.isElement {
            let parent = node.parent.flatMap { styles[$0.order] } ?? resolver.initialStyle
            styles[node.order] = resolver.style(for: node, parent: parent)
        }
        return styles
    }

    static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> ComputedStyle.Color {
        ComputedStyle.Color(red: red, green: green, blue: blue, alpha: alpha)
    }
}
