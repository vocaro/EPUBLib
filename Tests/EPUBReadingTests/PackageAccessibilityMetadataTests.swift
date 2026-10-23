import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

/// The EPUB Accessibility 1.1 metadata a package declares (#676): the discovery properties of
/// §2.2 and the conformance and evaluator properties of §3.5, in EPUB 3's `meta property=` and
/// `link rel=` forms and EPUB 2's `meta name= content=` form.
final class PackageAccessibilityMetadataTests: XCTestCase {
    /// The plain book with `metadata` added at the end of its package's `metadata`.
    private func book(_ metadata: String, epub2: Bool = false, adding: [String: Data?] = [:]) throws -> EPUBPublication {
        try EPUBPublication.open(data: Fixture.packageVariant(epub2: epub2, opf: {
            $0.replacingOccurrences(of: "</metadata>", with: metadata + "</metadata>")
        }, adding: adding))
    }

    private func link(_ string: String) -> EPUBMetadataValue { EPUBMetadataValue(string, isLink: true) }

    // MARK: Discovery metadata

    func testEPUB3DiscoveryMetadataIsReadInDocumentOrder() throws {
        // EPUB Accessibility Techniques 1.1 §3.9, Example 8, as written there.
        let book = try book("""
            <meta
                property="schema:accessMode">
               textual
            </meta>
            <meta
                property="schema:accessMode">
               visual
            </meta>
            <meta
                property="schema:accessModeSufficient">
               textual,visual
            </meta>
            <meta
                property="schema:accessModeSufficient">
               textual
            </meta>
            <meta
                property="schema:accessibilityFeature">
               transcript
            </meta>
            <meta
                property="schema:accessibilityFeature">
               MathML
            </meta>
            <meta
                property="schema:accessibilityFeature">
               alternativeText
            </meta>
            <meta
                property="schema:accessibilityHazard">
               flashing
            </meta>
            <meta
                property="schema:accessibilityHazard">
               noMotionSimulationHazard
            </meta>
            <meta
                property="schema:accessibilityHazard">
               noSoundHazard
            </meta>
            <meta
                property="schema:accessibilitySummary">
               The video in chapter 2 presents a flashing hazard. A transcript is
               provided that covers all the essential information contained in the
               video. The publication otherwise meets WCAG 2.0 Level A.
            </meta>
            """)
        XCTAssertEqual(book.metadata.accessibility, EPUBAccessibilityMetadata(
            accessModes: ["textual", "visual"], sufficientAccessModes: [["textual", "visual"], ["textual"]],
            features: ["transcript", "MathML", "alternativeText"], hazards: ["flashing", "noMotionSimulationHazard", "noSoundHazard"],
            summaries: ["The video in chapter 2 presents a flashing hazard. A transcript is provided that covers all the essential "
                        + "information contained in the video. The publication otherwise meets WCAG 2.0 Level A."]))
        XCTAssertFalse(book.metadata.accessibility.isEmpty)
        // The rest of the metadata is read as before.
        XCTAssertEqual(book.metadata.title, "A Test Book")
        XCTAssertEqual(book.metadata.authors, ["Test Author"])
    }

    func testEPUB2MetaNameFormIsRead() throws {
        // EPUB Accessibility Techniques 1.1 §3.9, Example 9, as written there, in an EPUB 2
        // package. The summary's `content` is wrapped over four lines.
        let book = try book("""
            <meta
                name="schema:accessMode"
                content="textual"/>
            <meta
                name="schema:accessMode"
                content="visual"/>
            <meta
                name="schema:accessModeSufficient"
                content="textual,visual"/>
            <meta
                name="schema:accessModeSufficient"
                content="textual"/>
            <meta
                name="schema:accessibilityFeature"
                content="transcript"/>
            <meta
                name="schema:accessibilityFeature"
                content="MathML"/>
            <meta
                name="schema:accessibilityFeature"
                content="alternativeText"/>
            <meta
                name="schema:accessibilityHazard"
                content="flashing"/>
            <meta
                name="schema:accessibilityHazard"
                content="noMotionSimulationHazard"/>
            <meta
                name="schema:accessibilityHazard"
                content="noSoundHazard"/>
            <meta
                name="schema:accessibilitySummary"
                content="The video in chapter 2 presents a flashing hazard.
                   A transcript is provided that covers all the essential
                   information contained in the video. The publication
                   otherwise meets WCAG 2.0 Level AA."/>
            """, epub2: true)
        XCTAssertEqual(book.metadata.accessibility, EPUBAccessibilityMetadata(
            accessModes: ["textual", "visual"], sufficientAccessModes: [["textual", "visual"], ["textual"]],
            features: ["transcript", "MathML", "alternativeText"], hazards: ["flashing", "noMotionSimulationHazard", "noSoundHazard"],
            summaries: ["The video in chapter 2 presents a flashing hazard. A transcript is provided that covers all the essential "
                        + "information contained in the video. The publication otherwise meets WCAG 2.0 Level AA."]))
        // EPUB 3 packages may carry the EPUB 2 form too, as they carry `meta name="cover"`.
        let epub3 = try self.book("<meta name=\"schema:accessMode\" content=\"textual\"/><meta name=\"schema:accessibilityHazard\" content=\"none\"/>")
        XCTAssertEqual(epub3.metadata.accessibility, EPUBAccessibilityMetadata(accessModes: ["textual"], hazards: ["none"]))
    }

    func testTheDeprecatedXMetadataElementsMetaAreRead() throws {
        // OEBPS 1.2 put a package's `meta` elements in `x-metadata`; OPF 2.0.1 §2.2 deprecates it
        // and has a reading system allow it (#85).
        let book = try book("<x-metadata><meta name=\"schema:accessMode\" content=\"textual\"/>"
            + "<meta name=\"schema:accessibilityFeature\" content=\"tableOfContents\"/></x-metadata>", epub2: true)
        XCTAssertEqual(book.metadata.accessibility, EPUBAccessibilityMetadata(accessModes: ["textual"], features: ["tableOfContents"]))
    }

    func testSufficientAccessModesAreCommaSeparatedLists() throws {
        // EPUB Accessibility Techniques 1.1 §3.2: "The order in which EPUB creators list the access
        // modes in a set is not important. The only requirement is to separate the values by
        // commas." Spaces round a mode are not part of it, and an empty item names none.
        let book = try book("""
            <meta property="schema:accessModeSufficient">textual, visual</meta>\
            <meta property="schema:accessModeSufficient">  auditory ,
                textual  </meta>\
            <meta property="schema:accessModeSufficient">visual,,tactile,</meta>\
            <meta property="schema:accessModeSufficient"> , </meta>\
            <meta property="schema:accessModeSufficient">textual</meta>
            """)
        XCTAssertEqual(book.metadata.accessibility.sufficientAccessModes,
                       [["textual", "visual"], ["auditory", "textual"], ["visual", "tactile"], ["textual"]])
        let epub2 = try self.book("<meta name=\"schema:accessModeSufficient\" content=\"textual ,visual\"/>"
            + "<meta name=\"schema:accessModeSufficient\" content=\"auditory\"/>", epub2: true)
        XCTAssertEqual(epub2.metadata.accessibility.sufficientAccessModes, [["textual", "visual"], ["auditory"]])
        // Only `accessModeSufficient` is a list: a comma in another value is part of it.
        let other = try self.book("<meta property=\"schema:accessMode\">textual,visual</meta>")
        XCTAssertEqual(other.metadata.accessibility.accessModes, ["textual,visual"])
    }

    func testUnknownValuesAreKeptAsWritten() throws {
        // A value the vocabulary does not define is kept, in its own case and with its repeats:
        // the techniques' own Example 4 writes `noflashingHazard`, and their list of hazards
        // `unknownMotionSimultationHazard`.
        let book = try book("""
            <meta property="schema:accessibilityHazard">noflashingHazard</meta>\
            <meta property="schema:accessibilityHazard">unknownMotionSimultationHazard</meta>\
            <meta property="schema:accessibilityHazard">sparkles</meta>\
            <meta property="schema:accessMode">Textual</meta><meta property="schema:accessMode">smell</meta>\
            <meta property="schema:accessMode">Textual</meta>\
            <meta property="schema:accessibilityFeature">futureFeature</meta><meta property="schema:accessibilityFeature">unknown</meta>\
            <meta property="schema:accessModeSufficient">textual,telepathic</meta>\
            <meta property="dcterms:conformsTo">Our House Style 2</meta>\
            <meta property="schema:accessibilitySummary">Summary one.</meta><meta property="schema:accessibilitySummary">Summary two.</meta>
            """)
        XCTAssertEqual(book.metadata.accessibility, EPUBAccessibilityMetadata(
            accessModes: ["Textual", "smell", "Textual"], sufficientAccessModes: [["textual", "telepathic"]],
            features: ["futureFeature", "unknown"], hazards: ["noflashingHazard", "unknownMotionSimultationHazard", "sparkles"],
            summaries: ["Summary one.", "Summary two."], conformance: [EPUBConformanceClaim("Our House Style 2")]))
    }

    func testAPropertyIsKnownByItsNameAsWritten() throws {
        // A name in another case, without its prefix or with another, is another property.
        let book = try book("""
            <meta property="schema:accessmode">textual</meta><meta property="accessMode">textual</meta>\
            <meta property="schemaorg:accessMode">textual</meta><meta property="Schema:accessMode">textual</meta>\
            <meta property="a11y:certifierreport">http://example.org/report</meta><meta property="dc:conformsTo">none</meta>\
            <meta property=" schema:accessMode ">visual</meta>
            """)
        XCTAssertEqual(book.metadata.accessibility, EPUBAccessibilityMetadata(accessModes: ["visual"]))
    }

    // MARK: Conformance and evaluators

    func testAClaimHoldsTheCertifierThatRefinesItAndTheCertifierItsCredentialsAndReports() throws {
        // EPUB Accessibility 1.1 §3.5.3: Examples 7 and 8, and Example 6's evaluation date. Each
        // refinement is written before the property it refines here, which changes nothing.
        let book = try book("""
            <link rel="a11y:certifierReport" refines="#certifier" href="http://www.example.com/a11y/report/9780000000001"/>\
            <meta property="a11y:certifierCredential" refines="#certifier">A+ Accessibility Rating</meta>\
            <meta property="dcterms:date" refines="#certifier">2021-09-07</meta>\
            <meta property="a11y:certifiedBy" refines="#conf" id="certifier">
                EPUB Accessibility Evaluator
            </meta>\
            <meta property="dcterms:conformsTo" id="conf">
                EPUB Accessibility 1.1 - WCAG 2.2 Level AA
            </meta>\
            <meta property="dcterms:date" refines="#conf">2021-09-08</meta>\
            <meta property="a11y:certifierCredential" refines="  #certifier ">DAISY OK</meta>
            """)
        let certifier = EPUBAccessibilityCertifier(
            name: "EPUB Accessibility Evaluator", credentials: ["A+ Accessibility Rating", "DAISY OK"],
            reports: [link("http://www.example.com/a11y/report/9780000000001")],
            refinements: [EPUBMetadataRefinement(property: "dcterms:date", value: "2021-09-07")])
        XCTAssertEqual(book.metadata.accessibility, EPUBAccessibilityMetadata(conformance: [
            EPUBConformanceClaim("EPUB Accessibility 1.1 - WCAG 2.2 Level AA", certifiers: [certifier],
                                 refinements: [EPUBMetadataRefinement(property: "dcterms:date", value: "2021-09-08")]),
        ]))
    }

    func testEachOfSeveralClaimsHoldsItsOwnCertifiers() throws {
        // §3.5.2.1: "An EPUB publication can have multiple dcterms:conformsTo statements." A claim
        // to a standard named by its URL is a link (§4, Example 10), as EPUB Accessibility 1.0's
        // conformance URLs were. The IDs are read as XML IDs and named by percent-encoded fragments.
        let book = try book("""
            <link rel="dcterms:conformsTo" id=" a11y10 " href="http://www.idpf.org/epub/a11y/accessibility-20170105.html#wcag-aa"/>\
            <meta property="dcterms:conformsTo" id="caf&#xE9;">EPUB Accessibility 1.1 - WCAG 2.1 Level A</meta>\
            <link rel="dcterms:conformsTo" href="
                https://daisy.org/info-help/guidance-training/standards/navigable-audio-only-epub3-guidelines/ "/>\
            <meta property="a11y:certifiedBy" refines="#a11y10">Old Evaluator</meta>\
            <meta property="a11y:certifiedBy" refines="#caf%C3%A9">New Evaluator</meta>\
            <meta property="a11y:certifiedBy" refines="#cafe&#x301;">Not By Code Units</meta>
            """)
        XCTAssertEqual(book.metadata.accessibility.conformance, [
            EPUBConformanceClaim(link("http://www.idpf.org/epub/a11y/accessibility-20170105.html#wcag-aa"),
                                 certifiers: [EPUBAccessibilityCertifier(name: "Old Evaluator")]),
            EPUBConformanceClaim("EPUB Accessibility 1.1 - WCAG 2.1 Level A", certifiers: [EPUBAccessibilityCertifier(name: "New Evaluator")]),
            EPUBConformanceClaim(link("https://daisy.org/info-help/guidance-training/standards/navigable-audio-only-epub3-guidelines/")),
        ])
        XCTAssertEqual(book.metadata.accessibility.certifiers, [])
    }

    func testAnEPUB2PackagesEvaluatorRefinesNothing() throws {
        // §3.5.3.1, Example 5: "A self-evaluated EPUB 2 Publication". EPUB 2 has no `refines`, so
        // a claim, its certifier and the certifier's credential and report each stand alone.
        let book = try book("""
            <dc:publisher>Acme Publishing Inc.</dc:publisher>
            <meta
                name="dcterms:conformsTo"
                content="EPUB Accessibility 1.1 - WCAG 2.2 Level AA"/>

            <meta
                name="a11y:certifiedBy"
                content="Acme Publishing Inc."/>
            <meta name="a11y:certifierCredential" content="A+ Accessibility Rating"/>\
            <meta name="a11y:certifierReport" content="https://example.com/report"/>
            """, epub2: true)
        XCTAssertEqual(book.metadata.accessibility, EPUBAccessibilityMetadata(
            conformance: [EPUBConformanceClaim("EPUB Accessibility 1.1 - WCAG 2.2 Level AA")],
            certifiers: [EPUBAccessibilityCertifier(name: "Acme Publishing Inc.")],
            certifierCredentials: ["A+ Accessibility Rating"], certifierReports: ["https://example.com/report"]))
    }

    func testAReportInTheBookIsItsArchivePath() throws {
        // §3.5.3.4, Example 9: "A local accessibility report", relative to the package document.
        // A link that names no path an entry can have is not read, as a landmark is not: an
        // escaped slash is a character of its name (doc/architecture.md).
        let book = try book("""
            <meta property="dcterms:conformsTo" id="conf">EPUB Accessibility 1.1 - WCAG 2.2 Level AA</meta>\
            <meta property="a11y:certifiedBy" refines="#conf" id="certifier">EPUB Accessibility Evaluator</meta>\
            <link rel="a11y:certifierReport" refines="#certifier" href="reports/a11y%20report.xhtml#summary"/>\
            <link rel="a11y:certifierReport" refines="#certifier" href="reports%2Fa11y.xhtml"/>\
            <link rel="a11y:certifierReport" refines="#certifier" href="  "/>\
            <link rel="a11y:certifierReport" refines="#certifier"/>
            """, adding: ["OPS/reports/a11y report.xhtml": Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"/>".utf8)])
        XCTAssertEqual(book.metadata.accessibility.conformance.first?.certifiers.first?.reports,
                       [link("OPS/reports/a11y%20report.xhtml#summary")])
    }

    func testOneLinkExpressesEachPropertyItsRelNames() throws {
        // A link's `rel` is a list of properties.
        let book = try book("<meta property=\"a11y:certifiedBy\" id=\"c\">An Evaluator</meta>"
            + "<link rel=\" a11y:certifierCredential\n a11y:certifierReport \" refines=\"#c\" href=\"https://example.com/evaluator\"/>")
        XCTAssertEqual(book.metadata.accessibility.certifiers, [EPUBAccessibilityCertifier(
            name: "An Evaluator", credentials: [link("https://example.com/evaluator")], reports: [link("https://example.com/evaluator")])])
    }

    func testATextPropertyIsNotReadFromALink() throws {
        // Only a claim, a credential and a report are written as links.
        let book = try book("""
            <link rel="schema:accessibilitySummary" href="summary.xhtml"/><link rel="schema:accessMode" href="https://example.com/textual"/>\
            <link rel="a11y:certifiedBy" href="https://example.com/evaluator"/>
            """)
        XCTAssertTrue(book.metadata.accessibility.isEmpty)
    }

    // MARK: Primary expressions and refinements

    func testAnExpressionThatRefinesSomethingElseIsNotThePublications() throws {
        // EPUB 3.3 §5.5.4: a `meta` without `refines` is a primary expression, about the
        // publication; one with it describes what it names. Accessibility metadata that refines a
        // manifest item, the identifier, an ID the package lacks or a claim that is not the
        // book's is not the book's. A credential that refines a claim, not its certifier, is one
        // of the claim's other refinements.
        let book = try book("""
            <meta property="schema:accessMode" refines="#one">visual</meta>\
            <meta property="schema:accessibilityFeature" refines="#uid">alternativeText</meta>\
            <meta property="a11y:certifiedBy" refines="#missing">A Lost Evaluator</meta>\
            <meta property="a11y:certifiedBy" refines="one.xhtml">A Chapter Evaluator</meta>\
            <meta property="dcterms:conformsTo" id="conf" refines="#one">EPUB Accessibility 1.1 - WCAG 2.2 Level AA</meta>\
            <meta property="a11y:certifiedBy" refines="#conf">Evaluator Of A Chapter's Claim</meta>\
            <meta property="dcterms:conformsTo" id="claim">EPUB Accessibility 1.1 - WCAG 2.2 Level A</meta>\
            <meta property="a11y:certifierCredential" refines="#claim">DAISY OK</meta>\
            <meta property="schema:accessMode">textual</meta>
            """)
        XCTAssertEqual(book.metadata.accessibility, EPUBAccessibilityMetadata(
            accessModes: ["textual"],
            conformance: [EPUBConformanceClaim("EPUB Accessibility 1.1 - WCAG 2.2 Level A",
                                               refinements: [EPUBMetadataRefinement(property: "a11y:certifierCredential", value: "DAISY OK")])]))
        // A `refines` of nothing but white space refines nothing.
        let blank = try self.book("<meta property=\"schema:accessMode\" refines=\" \">textual</meta>")
        XCTAssertEqual(blank.metadata.accessibility.accessModes, ["textual"])
    }

    func testAPropertyGivenInEPUB3sFormIsNotReadAgainFromEPUB2s() throws {
        // A package that writes both forms for older readers lists each value once; a property it
        // writes only in EPUB 2's form is still read from that.
        let book = try book("""
            <meta property="schema:accessMode">textual</meta><meta name="schema:accessMode" content="textual"/>\
            <meta name="schema:accessMode" content="visual"/><meta property="schema:accessMode">visual</meta>\
            <link rel="dcterms:conformsTo" href="http://www.idpf.org/epub/a11y/accessibility-20170105.html#wcag-a"/>\
            <meta name="dcterms:conformsTo" content="http://www.idpf.org/epub/a11y/accessibility-20170105.html#wcag-a"/>\
            <meta name="schema:accessibilitySummary" content="Only in the older form."/>\
            <meta property="schema:accessibilityFeature"> </meta><meta name="schema:accessibilityFeature" content="tableOfContents"/>
            """)
        XCTAssertEqual(book.metadata.accessibility, EPUBAccessibilityMetadata(
            accessModes: ["textual", "visual"], features: ["tableOfContents"], summaries: ["Only in the older form."],
            conformance: [EPUBConformanceClaim(link("http://www.idpf.org/epub/a11y/accessibility-20170105.html#wcag-a"))]))
    }

    func testAnEmptyValueIsLeftOut() throws {
        // As a Dublin Core value is: white space of any kind alone, a no-break space among it,
        // is no value.
        let book = try book("""
            <meta property="schema:accessMode"/><meta property="schema:accessMode">  </meta>\
            <meta property="schema:accessMode">&#160;</meta><meta name="schema:accessMode" content=" "/>\
            <meta name="schema:accessMode"/><meta property="schema:accessibilitySummary">&#x3000;</meta>\
            <meta property="schema:accessMode"> textual </meta><meta property="">visual</meta><meta>visual</meta>
            """)
        XCTAssertEqual(book.metadata.accessibility, EPUBAccessibilityMetadata(accessModes: ["textual"]))
    }

    func testAPackageWithoutAccessibilityMetadataHasNone() throws {
        let book = try book("<meta property=\"dcterms:modified\">2026-01-01T00:00:00Z</meta><meta property=\"rendition:layout\">reflowable</meta>"
            + "<meta name=\"cover\" content=\"one\"/><link rel=\"dcterms:rights\" href=\"https://example.com/rights\"/>"
            + "<meta property=\"a11y:exemption\">eaa-disproportionate-burden</meta>")
        XCTAssertEqual(book.metadata.accessibility, EPUBAccessibilityMetadata())
        XCTAssertTrue(book.metadata.accessibility.isEmpty)
        XCTAssertEqual(book.metadata, EPUBMetadata(title: "A Test Book", authors: ["Test Author"], languages: ["en"], identifiers: ["test-book"]))
    }
}
