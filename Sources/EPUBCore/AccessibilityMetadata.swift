import Foundation

/// The accessibility metadata a package declares: EPUB Accessibility 1.1's discovery metadata
/// (§2.2) and its conformance and evaluator metadata (§3.5), for a host to show as the W3C
/// Accessibility Metadata Display Guide 2.0 and its EPUB techniques describe.
///
/// Each value is read as a Dublin Core value is, with ASCII whitespace stripped from its ends and
/// collapsed, and is kept as written: in document order, in its own case, repeats included, and
/// whether or not the vocabulary defines it. Nothing here says what a value means or words it
/// for a reader. A property is read from EPUB 3's `meta property=` (and, where the property names
/// a link, `link rel=`) and from EPUB 2's `meta name= content=`, in a package of either version;
/// a property the package writes in EPUB 3's form is read from that form alone, so that one
/// repeated in EPUB 2's form for older readers is listed once.
///
/// A property is known by its name as written with its reserved prefix (`schema:`, `dcterms:`,
/// `a11y:`), as the display guide's techniques match it. Each list holds the package's primary
/// expressions, those without a `refines`; one that refines something is read as part of what it
/// refines, when that is a conformance claim or a certifier, and is not read otherwise.
public struct EPUBAccessibilityMetadata: Hashable, Sendable {
    /// `schema:accessMode`: a sense or faculty the content needs, such as `textual`, `visual`,
    /// `auditory` or `tactile`.
    public let accessModes: [String]
    /// `schema:accessModeSufficient`: each set of access modes enough to read the whole book, its
    /// comma-separated modes in the order written, each without the spaces round it, so
    /// `textual, visual` is `["textual", "visual"]`. An empty item, and a set with none, is left out.
    public let sufficientAccessModes: [[String]]
    /// `schema:accessibilityFeature`, such as `alternativeText`, `displayTransformability` or
    /// `synchronizedAudioText`.
    public let features: [String]
    /// `schema:accessibilityHazard`, such as `flashing`, `noSoundHazard`, `none` or `unknown`.
    public let hazards: [String]
    /// `schema:accessibilitySummary`. EPUB Accessibility expects at most one; every one written is
    /// listed.
    public let summaries: [String]
    /// `dcterms:conformsTo`: what the book claims to meet, such as
    /// `EPUB Accessibility 1.1 - WCAG 2.2 Level AA`, a URL that names a standard, or `none`.
    public let conformance: [EPUBConformanceClaim]
    /// `a11y:certifiedBy` that refines no conformance claim: the party that evaluated the book,
    /// where the package does not say for which claim, as EPUB 2 cannot.
    public let certifiers: [EPUBAccessibilityCertifier]
    /// `a11y:certifierCredential` that refines no certifier.
    public let certifierCredentials: [EPUBMetadataValue]
    /// `a11y:certifierReport` that refines no certifier.
    public let certifierReports: [EPUBMetadataValue]

    /// Whether the package declares none of it, where the display guide shows that no information
    /// is available.
    public var isEmpty: Bool {
        accessModes.isEmpty && sufficientAccessModes.isEmpty && features.isEmpty && hazards.isEmpty && summaries.isEmpty
            && conformance.isEmpty && certifiers.isEmpty && certifierCredentials.isEmpty && certifierReports.isEmpty
    }

    public init(accessModes: [String] = [], sufficientAccessModes: [[String]] = [], features: [String] = [],
                hazards: [String] = [], summaries: [String] = [], conformance: [EPUBConformanceClaim] = [],
                certifiers: [EPUBAccessibilityCertifier] = [], certifierCredentials: [EPUBMetadataValue] = [],
                certifierReports: [EPUBMetadataValue] = []) {
        self.accessModes = accessModes; self.sufficientAccessModes = sufficientAccessModes; self.features = features
        self.hazards = hazards; self.summaries = summaries; self.conformance = conformance; self.certifiers = certifiers
        self.certifierCredentials = certifierCredentials; self.certifierReports = certifierReports
    }
}

/// A `dcterms:conformsTo` the package declares, with what refines it.
public struct EPUBConformanceClaim: Hashable, Sendable {
    /// The `meta`'s text, or the `link`'s `href` (`EPUBMetadataValue`).
    public let value: EPUBMetadataValue
    /// The `a11y:certifiedBy` that refine it: who evaluated the book against it.
    public let certifiers: [EPUBAccessibilityCertifier]
    /// The other properties that refine it, such as a `dcterms:date`, in document order.
    public let refinements: [EPUBMetadataRefinement]
    public init(_ value: EPUBMetadataValue, certifiers: [EPUBAccessibilityCertifier] = [],
                refinements: [EPUBMetadataRefinement] = []) {
        self.value = value; self.certifiers = certifiers; self.refinements = refinements
    }
}

/// An `a11y:certifiedBy` the package declares: the name of the party that evaluated the book,
/// with what refines it.
public struct EPUBAccessibilityCertifier: Hashable, Sendable {
    public let name: String
    /// The `a11y:certifierCredential` that refine it: a credential or badge, as text or a link.
    public let credentials: [EPUBMetadataValue]
    /// The `a11y:certifierReport` that refine it: the party's report on the book, usually a link.
    public let reports: [EPUBMetadataValue]
    /// The other properties that refine it, such as the `dcterms:date` of the evaluation, in
    /// document order.
    public let refinements: [EPUBMetadataRefinement]
    public init(name: String, credentials: [EPUBMetadataValue] = [], reports: [EPUBMetadataValue] = [],
                refinements: [EPUBMetadataRefinement] = []) {
        self.name = name; self.credentials = credentials; self.reports = reports; self.refinements = refinements
    }
}

/// A metadata value: a `meta` element's text, an EPUB 2 `meta`'s `content`, or a `link`'s `href`.
public struct EPUBMetadataValue: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// Text read as a Dublin Core value is, or a link's URL. A link to a file in the book is the
    /// archive-relative URL reference it resolves to, as a landmark's is, which a reader session
    /// navigates to; a remote one is as written, without the white space round it. A link whose
    /// `href` does not resolve inside the archive is not read.
    public let string: String
    /// Whether the value is a `link`'s `href`.
    public let isLink: Bool
    public init(_ string: String, isLink: Bool = false) { self.string = string; self.isLink = isLink }
    public init(stringLiteral string: String) { self.init(string) }
    public var description: String { string }
}

/// A property that refines a conformance claim or a certifier.
public struct EPUBMetadataRefinement: Hashable, Sendable {
    /// The property as written: a `meta`'s `property` or EPUB 2 `name`, or a `link`'s `rel` value.
    public let property: String
    public let value: EPUBMetadataValue
    public init(property: String, value: EPUBMetadataValue) { self.property = property; self.value = value }
}
