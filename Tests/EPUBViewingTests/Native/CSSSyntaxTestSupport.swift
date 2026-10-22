import EPUBCore
import EPUBReading
@testable import EPUBViewing
import Foundation

/// Entry points for the CSS syntax coverage tests: tokens, raw sheets, selector lists and the
/// elements a selector matches in a styled document.
enum CSSSyntaxSupport {
    static func tokens(_ text: String) -> [CSSToken] {
        var tokenizer = CSSTokenizer(text)
        return tokenizer.tokens()
    }

    static func integer(_ value: Double, signed: Bool = false) -> CSSToken { .number(value, isInteger: true, signed: signed) }
    static func real(_ value: Double, signed: Bool = false) -> CSSToken { .number(value, isInteger: false, signed: signed) }
    static func dimension(_ value: Double, _ unit: String, integer: Bool = true, signed: Bool = false) -> CSSToken {
        .dimension(value, unit: unit, isInteger: integer, signed: signed)
    }

    static func components(_ text: String) -> [CSSComponent] {
        var truncated = false
        return CSSParser.components(text, truncated: &truncated)
    }

    static func sheet(_ css: String, path: String = "OPS/css/main.css") -> CSSStyleSheet { CSSStyleSheet.parse(css, path: path) }

    /// Each rule's first subject: its type name, or `*`.
    static func subjects(_ sheet: CSSStyleSheet) -> [String] { sheet.rules.map { $0.selectors[0].compounds[0].name?.string ?? "*" } }

    /// The longhands a declaration list yields, in order.
    static func properties(_ declarations: String) -> [CSSProperty] { CSSStyleSheet.declarations(declarations).map(\.property) }

    /// nil when the list is invalid.
    static func selectors(_ text: String, namespaces: CSSNamespaces = CSSNamespaces()) -> [CSSComplexSelector]? {
        try? CSSSelectorParser(namespaces: namespaces).parseList(components(text).trimmingWhitespace)
    }

    /// (ids, classes, types) of the first selector; nil when the list is invalid.
    static func specificity(_ text: String, namespaces: CSSNamespaces = CSSNamespaces()) -> [UInt32]? {
        selectors(text, namespaces: namespaces)?.first.map { [$0.specificity >> 20, $0.specificity >> 10 & 1023, $0.specificity & 1023] }
    }

    /// The marker the matching tests apply: `clear` is not inherited and no default sets it.
    static let marker = "clear: both"

    /// Ids of the elements carrying the marker, in document order.
    static func marked(_ result: StyledDocument) -> [String] {
        result.document.nodes.compactMap { node in
            guard node.isElement, let id = node.id, result.styles[node.order]?.clear == .both else { return nil }
            return id
        }
    }

    /// Ids of the elements `selector` matches in an XHTML document with this body.
    static func matched(_ selector: String, in body: String, prelude: String = "") throws -> [String] {
        marked(try StyleTestSupport.styled(body, css: "\(prelude)\n\(selector) { \(marker) }"))
    }

    /// A whole section styled with archive files given as bytes.
    static func styled(section: String, files: [String: Data] = [:], dark: Bool = false) throws -> StyledDocument {
        try StyleTestSupport.styled(section: section, files: files, typography: NativeTypography(fontSize: 16, isDark: dark))
    }

    static func styled(section: String, files: [String: String], dark: Bool = false) throws -> StyledDocument {
        try styled(section: section, files: files.mapValues { Data($0.utf8) }, dark: dark)
    }
}
