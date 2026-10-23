import EPUBCore
import Foundation

/// Reads `EPUBAccessibilityMetadata` from the `meta` and `link` children of a package's `metadata`.
enum AccessibilityMetadataReader {
    /// A `meta` or `link` element as the package parser gives it.
    struct Element {
        var isLink: Bool
        /// The `id`, read as an XML ID.
        var id: String?
        var refines: String?
        /// A `meta`'s EPUB 3 `property`.
        var property: String?
        /// A `meta`'s EPUB 2 `name`, and its `content` read as a metadata value is.
        var name: String?
        var content: String?
        /// A `link`'s `rel` and `href`, as written.
        var rel: String?
        var href: String?
        /// A `meta`'s text, read as a metadata value is.
        var text: String
    }

    static let accessMode = "schema:accessMode", sufficientAccessMode = "schema:accessModeSufficient"
    static let feature = "schema:accessibilityFeature", hazard = "schema:accessibilityHazard"
    static let summary = "schema:accessibilitySummary", conformsTo = "dcterms:conformsTo"
    static let certifiedBy = "a11y:certifiedBy", credential = "a11y:certifierCredential", report = "a11y:certifierReport"
    /// The properties whose values are text, never read from a `link`. EPUB Accessibility 1.1
    /// writes the others as a `link` as well as a `meta`: a claim to a standard named by its URL
    /// (§4, Example 10) and a report (§3.5.3.4), and EPUBCheck allows a credential so.
    static let textual: Set = [accessMode, sufficientAccessMode, feature, hazard, summary, certifiedBy]

    /// One property an element expresses, with its value.
    private struct Expression {
        let property: String
        let value: EPUBMetadataValue
        let id: EPUBElementID?
        /// Whether the element has a `refines`, and the ID it names when that is a fragment.
        let refines: Bool
        let target: EPUBElementID?
        let isEPUB3: Bool
    }

    /// `resolve` gives the archive-relative reference a local `href` resolves to, nil when none.
    static func read(_ elements: [Element], resolve: (String) -> String?) -> EPUBAccessibilityMetadata {
        var expressions: [Expression] = []
        for element in elements {
            let refines = stripped(element.refines ?? "")
            let target = refines.utf8.first == 0x23 ? fragmentID(refines.utf8.dropFirst()) : nil // #
            func add(_ property: String, _ value: EPUBMetadataValue, isEPUB3: Bool) {
                guard !value.string.isEmpty, !(value.isLink && textual.contains(property)) else { return }
                expressions.append(Expression(property: property, value: value, id: element.id.map { EPUBElementID($0) },
                                              refines: !refines.isEmpty, target: target, isEPUB3: isEPUB3))
            }
            if element.isLink {
                // A remote URL is kept as written. A link whose `href` names no path an entry can
                // have is not read, as a landmark is not.
                let href = stripped(element.href ?? "")
                guard !href.isEmpty, let url = ResourceReference.isRemote(href) ? href : resolve(href) else { continue }
                for property in words(element.rel ?? "") { add(property, EPUBMetadataValue(url, isLink: true), isEPUB3: true) }
            } else if let property = element.property.map(stripped), !property.isEmpty {
                add(property, EPUBMetadataValue(element.text), isEPUB3: true)
            } else if let name = element.name.map(stripped), !name.isEmpty {
                add(name, EPUBMetadataValue(element.content ?? ""), isEPUB3: false)
            }
        }
        // A property the package gives in EPUB 3's form is read from that form alone: a package
        // that repeats it as an EPUB 2 `meta` for older readers would otherwise list it twice.
        let written = Set(expressions.filter(\.isEPUB3).map(\.property))
        expressions.removeAll { !$0.isEPUB3 && written.contains($0.property) }

        func primary(_ property: String) -> [Expression] { expressions.filter { !$0.refines && $0.property == property } }
        func refining(_ expression: Expression) -> [Expression] {
            guard let id = expression.id else { return [] }
            return expressions.filter { $0.target == id }
        }
        func others(_ parts: [Expression], besides properties: Set<String>) -> [EPUBMetadataRefinement] {
            parts.filter { !properties.contains($0.property) }.map { EPUBMetadataRefinement(property: $0.property, value: $0.value) }
        }
        func certifier(_ expression: Expression) -> EPUBAccessibilityCertifier {
            let parts = refining(expression)
            return EPUBAccessibilityCertifier(name: expression.value.string,
                                              credentials: parts.filter { $0.property == credential }.map(\.value),
                                              reports: parts.filter { $0.property == report }.map(\.value),
                                              refinements: others(parts, besides: [credential, report]))
        }
        return EPUBAccessibilityMetadata(
            accessModes: primary(accessMode).map(\.value.string),
            sufficientAccessModes: primary(sufficientAccessMode).map { modes($0.value.string) }.filter { !$0.isEmpty },
            features: primary(feature).map(\.value.string),
            hazards: primary(hazard).map(\.value.string),
            summaries: primary(summary).map(\.value.string),
            conformance: primary(conformsTo).map { claim in
                let parts = refining(claim)
                return EPUBConformanceClaim(claim.value, certifiers: parts.filter { $0.property == certifiedBy }.map(certifier),
                                            refinements: others(parts, besides: [certifiedBy]))
            },
            certifiers: primary(certifiedBy).map(certifier),
            certifierCredentials: primary(credential).map(\.value),
            certifierReports: primary(report).map(\.value))
    }

    /// A set of sufficient access modes: the value split at each comma, each part without the
    /// spaces round it (the value's ASCII whitespace is already one space), empty ones left out.
    /// Both are found by byte, so a mark after a comma or a space stays, as a value keeps it.
    private static func modes(_ value: String) -> [String] {
        value.utf8.split(separator: 0x2C, omittingEmptySubsequences: false) // ,
            .map { trimmed($0) { $0 == 0x20 } }.filter { !$0.isEmpty }
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
    }

    /// An attribute value without the ASCII whitespace round it.
    private static func stripped(_ value: String) -> String { trimmed(value.utf8, isASCIIWhitespace) }

    private static func trimmed(_ bytes: some Collection<UInt8>, _ isSpace: (UInt8) -> Bool) -> String {
        let bytes = Array(bytes)
        guard let first = bytes.firstIndex(where: { !isSpace($0) }), let last = bytes.lastIndex(where: { !isSpace($0) }) else { return "" }
        return String(decoding: bytes[first...last], as: UTF8.self)
    }

    /// A list of property values, separated by ASCII whitespace.
    private static func words(_ value: String) -> [String] {
        value.utf8.split(whereSeparator: isASCIIWhitespace).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The ID a `refines` fragment names, percent-decoded as a fragment names an element.
    private static func fragmentID(_ fragment: some Collection<UInt8>) -> EPUBElementID? {
        let written = String(decoding: Array(fragment), as: UTF8.self)
        let id = written.removingPercentEncoding ?? written
        return id.isEmpty ? nil : EPUBElementID(id)
    }
}
