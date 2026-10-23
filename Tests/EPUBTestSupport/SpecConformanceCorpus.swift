import Foundation

/// The W3C EPUB reading-system test suite (github.com/w3c/epub-tests) as this repository reads
/// it: how an expanded test directory becomes an archive in memory, and what each test id must
/// produce. The suite is not part of the repository; `EPUBLIB_W3C_EPUB_TESTS` names its `tests`
/// directory. Nothing in it is executed: files are read as bytes and packed.
///
/// An expectation is the test's own pass criterion where that can be read from the publication
/// model or the built sections, replaced by this repository's documented decision where one
/// applies (`outOfScope` quotes it). A criterion the specification only recommends is a `note`,
/// reported and not asserted.
public enum SpecConformanceCorpus {
    public static let environmentKey = "EPUBLIB_W3C_EPUB_TESTS"
    public static let reportKey = "EPUBLIB_W3C_EPUB_TESTS_REPORT"

    /// What a section report discloses.
    public enum Disclosure: String, Sendable, CaseIterable {
        case fixedLayout, verticalWriting, scripts, remoteResources, unsupportedElements, unreadableResources
        case withheld, positionsUnavailable, mathFallback, flexGrid
    }

    public enum Check: Sendable, Equatable {
        // The publication model.
        case title(String)
        case authors([String])
        /// Resource paths in reading order.
        case spine([String])
        case linear([Bool])
        /// `reflowable` or `prePaginated` per spine item.
        case layouts([String])
        case progression(String)
        /// Contents titles, flattened in document order.
        case toc([String])
        /// Contents hrefs, flattened in document order.
        case tocTargets([String])
        // The built sections.
        /// The phrase is in the section's rendered text. The extraction run
        /// (`SpecConformanceW3CCorpusExtractionTests`) looks for it in the section's extracted text
        /// too, so it holds only the book's own characters. Text the reader generates, such as the
        /// marks around a `q` or a list marker, goes in `renderedInOrder` or `notRendered`.
        case rendered(Int, String)
        case notRendered(Int, String)
        /// Phrases met in this order reading the linear sections one after another.
        case renderedInOrder([String])
        /// An image attachment decoded from this archive path.
        case image(Int, path: String)
        case imageCount(Int, Int)
        /// A MathML formula laid out natively.
        case formula(Int)
        /// The phrase is set in a face other than the one the section's first character has.
        case embeddedFont(Int, phrase: String)
        /// The phrase is set in the face the section's first character has.
        case defaultFont(Int, phrase: String)
        /// The link over the phrase names this spine index (its first occurrence).
        case link(Int, phrase: String, spineIndex: Int)
        case externalLink(Int, phrase: String)
        /// A note shown in place of its reference holds this text.
        case note(Int, id: String, contains: String)
        case noNote(Int, id: String)
        /// No paragraph of the section has a right-to-left base direction.
        case leftToRight(Int)
        case disclosed(Disclosure)
        case notDisclosed(Disclosure)
        /// Whether the section asked for vertical writing.
        case vertical(Int, Bool)
        /// A position in each spine occurrence resolves back to that occurrence.
        case distinctPositions
        /// The spine indices shown as fixed-layout pages, whole at their declared size: every
        /// other section flows (#5).
        case fixedPages([Int])
    }

    public struct Expectation: Sendable {
        /// The requirement's anchor in EPUB Reading Systems 3.3 (or EPUB 3.3).
        public var requirement: String
        /// The documented decision that puts the test's own criterion out of scope.
        public var outOfScope: String?
        /// The publication is refused with an error whose description starts with this.
        public var refused: String?
        /// Spine indices shown as "This section could not be shown."
        public var withheld: Set<Int> = []
        /// Spine indices read with the forgiving HTML parser.
        public var recovered: Set<Int> = []
        /// Explicit indices strict headless extraction must refuse as malformed. When nil,
        /// use the viewer's withheld and recovered indices. A viewer-only namespace repair (of an
        /// undeclared prefix) can disable CFIs even when the extractor's XML reader accepts the
        /// characters; a name that Namespaces in XML forbids, it refuses too (#178).
        public var extractionMalformed: Set<Int>?
        public var checks: [Check] = []
        /// A recommended (SHOULD or MAY) behaviour the reader lacks, or a limit of this run.
        public var note: String?

        public init(_ requirement: String, outOfScope: String? = nil, refused: String? = nil, withheld: Set<Int> = [],
                    recovered: Set<Int> = [], extractionMalformed: Set<Int>? = nil,
                    note: String? = nil, _ checks: Check...) {
            self.requirement = requirement; self.outOfScope = outOfScope; self.refused = refused
            self.withheld = withheld; self.recovered = recovered; self.extractionMalformed = extractionMalformed
            self.note = note; self.checks = checks
        }
    }

    // MARK: Documented decisions

    static let fixedLayout = "doc/native-viewer.md, Decisions: \"A fixed-layout spine item that is not one image or one drawing reflows, with a .disclosure\""
    static let verticalWriting = "doc/native-viewer.md, Decisions: \"writing-mode: vertical-* renders horizontally, with a .disclosure\""
    static let scripting = "doc/architecture.md, Viewer isolation: \"script elements are counted and disclosed but never run\""
    static let mediaOverlays = "doc/architecture.md: \"Media overlays, TTS and annotation persistence are outside the initial API\""
    static let patternFills = "doc/native-viewer.md, Decisions: \"Pattern fills ... show their title, description or drawing text instead\""
    static let repair = "doc/architecture.md: \"Markup that is not well-formed is read with libxml2's forgiving HTML parser rather than refused\""
    static let entities = "doc/architecture.md: \"XMLSafety refuses entity declarations and internal DTD subsets\""
    static let externalLinks = "doc/native-viewer.md, Security: \"External links are refused with a notice\""

    // MARK: Expectations

    /// The expected outcome of a test id. An id the table does not list falls to its family's
    /// decision, else to "opens and every section builds".
    public static func expectation(for id: String, supportsPSDFallback: Bool = false) -> Expectation {
        var expectation = listed[id] ?? family(of: id)
        // The W3C fixture calls its PSD fallback "likely" unsupported. When the host's
        // independent image decoder can draw it, displaying it fulfills the fallback rule.
        if id == "pub-foreign_bad-fallback", supportsPSDFallback {
            expectation.withheld = []
            expectation.checks = [.image(0, path: "EPUB/bar.psd"), .notDisclosed(.withheld), .notDisclosed(.unreadableResources)]
            expectation.note = "ImageIO independently decodes the PSD fallback; the DMG's fallback must be displayed"
        }
        if centredFigures.contains(id) { expectation.checks.append(.notDisclosed(.flexGrid)) }
        return expectation
    }

    private static func family(of id: String) -> Expectation {
        if id.hasPrefix("mol-") {
            return Expectation("epub-rs#sec-media-overlays", outOfScope: mediaOverlays)
        }
        if id.hasPrefix("scr-") {
            return Expectation("epub-rs#sec-scripted-content", outOfScope: scripting, .disclosed(.scripts))
        }
        if id.hasPrefix("fxl-") || id.hasPrefix("lay-fxl-") || id.hasPrefix("lay-pp-") || id.hasPrefix("xx-lay-pp") {
            return Expectation("epub-rs#sec-fixed-layouts", outOfScope: fixedLayout, .disclosed(.fixedLayout), .fixedPages([]))
        }
        if id.hasPrefix("lay-roll-") || id.hasPrefix("xx-lay-roll") {
            return Expectation("epub-rs (3.4 draft) #sec-roll-layouts", outOfScope: "roll layouts are not part of EPUB 3.3; an unknown rendition:layout value is reflowable")
        }
        return Expectation("unlisted", note: "not in this table: only opening and building are checked")
    }

    /// Tests whose stylesheet (`EPUB/texts/fixed.css`) centres a page's one image with
    /// `figure { height: 100%; display: flex; align-items: center; justify-content: center }`.
    /// A row with one item is inside the supported subset (doc/native-viewer.md, "Flex and grid alignment"),
    /// so the figure is aligned and nothing is disclosed.
    private static let centredFigures: Set<String> = [
        "lay-pp-embedded-images", "lay-pp-embedded-images-svg", "lay-pp-images-mixed",
        "lay-roll-embedded-images", "lay-roll-embedded-images-svg", "lay-roll-images-mixed", "xx-lay-roll-template",
    ]

    private static let passIfOpens = Check.rendered(0, "Test passes if the EPUB opens.")
    private static let fallbackShown = "Test passes if you see this text."

    private static let listed: [String: Expectation] = [
        // Content documents.
        "cnt-css-fonts_ot": .init("epub-rs#confreq-css-rs-fonts", .embeddedFont(0, phrase: "This should be an unusual font")),
        "cnt-css-fonts_tt": .init("epub-rs#confreq-css-rs-fonts", .embeddedFont(0, phrase: "This should be an unusual font")),
        "cnt-css-fonts_woff": .init("epub-rs#confreq-css-rs-fonts", .embeddedFont(0, phrase: "This should be an unusual font")),
        "cnt-css-fonts_woff2": .init("epub-rs#confreq-css-rs-fonts", .embeddedFont(0, phrase: "This should be an unusual font")),
        "cnt-mathml-support": .init("epub-rs#confreq-mathml-rs-render", .formula(0), .notDisclosed(.mathFallback)),
        "cnt-svg-css": .init("epub-rs#confreq-svg-rs-css", outOfScope: patternFills,
                             .rendered(0, "Test passes if the image appears filled"), .disclosed(.unsupportedElements)),
        "cnt-svg-css-inclusion": .init("epub-rs#confreq-svg-rs-css-embed-inc", outOfScope: patternFills, .disclosed(.unsupportedElements)),
        "cnt-svg-css-reference": .init("epub-rs#confreq-rs-css-embed-ref", outOfScope: patternFills, .disclosed(.unsupportedElements)),
        "cnt-svg-embedded": .init("epub-rs#confreq-svg-rs-embed", .imageCount(0, 1), .notDisclosed(.unsupportedElements)),
        "cnt-svg-support": .init("epub-rs#confreq-rs-epub3-svg", .imageCount(0, 1), .notDisclosed(.unsupportedElements)),
        "cnt-xhtml-support": .init("epub-rs#confreq-rs-epub3-xhtml", .rendered(0, "Test passes if you see this.")),

        // Prefixed CSS (all SHOULD): the documents must read; what is honoured is noted.
        "css-epub-hyphens": .init("epub-rs#confreq-css-rs-prefixed", .rendered(0, "The nineteenth century dislike")),
        "css-epub-line-break": .init("epub-rs#confreq-css-rs-prefixed", note: "SHOULD: -epub-line-break is not read"),
        "css-epub-text-align-last": .init("epub-rs#confreq-css-rs-prefixed", note: "SHOULD: -epub-text-align-last is not read"),
        "css-epub-text-combine-horizontal": .init("epub-rs#confreq-css-rs-prefixed", outOfScope: verticalWriting,
            note: "SHOULD: -epub-text-combine-horizontal is not read", .disclosed(.verticalWriting)),
        "css-epub-text-emphasis": .init("epub-rs#confreq-css-rs-prefixed", outOfScope: verticalWriting,
            note: "SHOULD: -epub-text-emphasis-* are not read", .disclosed(.verticalWriting)),
        "css-epub-text-orientation": .init("epub-rs#confreq-css-rs-prefixed", outOfScope: verticalWriting,
            note: "SHOULD: -epub-text-orientation is not read", .disclosed(.verticalWriting)),
        "css-epub-text-transform": .init("epub-rs#confreq-css-rs-prefixed", outOfScope: verticalWriting,
            note: "SHOULD: text-transform: -epub-fullwidth is not read", .disclosed(.verticalWriting)),
        "css-epub-text-underline-position": .init("epub-rs#confreq-css-rs-prefixed", outOfScope: verticalWriting,
            note: "SHOULD: -epub-text-underline-position is not read", .disclosed(.verticalWriting)),
        "css-epub-word-break": .init("epub-rs#confreq-css-rs-prefixed", note: "SHOULD: -epub-word-break is not read"),
        "css-epub-writing-mode": .init("epub-rs#confreq-css-rs-prefixed", outOfScope: verticalWriting,
            .vertical(0, false), .vertical(1, true), .vertical(2, true), .disclosed(.verticalWriting)),

        // Navigation document.
        "nav-access": .init("epub-rs#confreq-nav-toc-access", .toc(["Test passes if you can see this link"]),
                            .tocTargets(["EPUB/content_001.xhtml"])),
        "nav-activation": .init("epub-rs#confreq-nav-activation",
            .toc(["1st content document", "Click to access 2nd content document"]),
            .tocTargets(["EPUB/content_001.xhtml", "EPUB/content_002.xhtml"]),
            .link(0, phrase: "Click to access 2nd content document", spineIndex: 2),
            .rendered(2, "Test passes if the navigation link leads here.")),
        "nav-non-text_img": .init("epub-rs#confreq-nav-alt-text",
            .toc(["Start page", "Description of the Abbey of S\u{E9}nanque"]),
            .tocTargets(["EPUB/content_001.xhtml", "EPUB/senanque.xhtml"])),
        // The image's title is "Image of the Abbey"; alt is preferred.
        "nav-non-text_img_title": .init("epub-rs#confreq-nav-alt-text",
            .toc(["Start page", "Description of the Abbey of S\u{E9}nanque"]),
            .tocTargets(["EPUB/content_001.xhtml", "EPUB/senanque.xhtml"])),
        "nav-spine_in-spine": .init("epub-rs#confreq-nav-spine",
            .spine(["EPUB/nav.xhtml", "EPUB/content_001.xhtml", "EPUB/content_002.xhtml"]),
            .toc(["Test passes if you can see two links (first link)", "Test passes if you can see two links (second link)"]),
            .rendered(0, "Test passes if you can see two links (first link)")),
        "nav-spine_in-spine-hidden-toc-css": .init("epub-rs#confreq-nav-hidden", .toc(["The first link", "The second link"]),
            .rendered(0, "The first link"), .notRendered(0, "The second link")),
        "nav-spine_in-spine-hidden-toc-html": .init("epub-rs#confreq-nav-hidden", .toc(["The first link", "The second link"]),
            .rendered(0, "The first link"), .notRendered(0, "The second link")),
        "nav-spine_in-spine-no-list-style": .init("epub-rs#confreq-nav-ol-style",
            .toc(["Test passes if you can see two links: the first link", "the second link"])),
        "nav-spine_not-in-spine": .init("epub-rs#confreq-nav-spine", .spine(["EPUB/content_001.xhtml", "EPUB/content_002.xhtml"]),
            .toc(["Test passes if you can see two links (first link)", "Test passes if you can see two links (second link)"])),

        // Open Container Format.
        "ocf-font_obfuscation": .init("epub-rs#confreq-ocf-fobfus", .embeddedFont(0, phrase: "This should be an unusual TrueType font."),
                                      .image(0, path: "EPUB/media/text_image.png")),
        "ocf-font_obfuscation_bis": .init("epub#obfus-key-unique-id", .defaultFont(0, phrase: "This should be an unusual TrueType font."),
                                          .disclosed(.unreadableResources)),
        "ocf-metainf-inc": .init("epub-rs#sec-container-metainf-inc", .rendered(0, "Test passes if this page of the book can be accessed")),
        "ocf-metainf-manifest": .init("epub-rs#sec-container-metainf-manifest.xml", .spine(["EPUB/content_001.xhtml"])),
        "ocf-package_arbitrary": .init("epub-rs#container-default-rendition", .spine(["FOO/BAR/content_001.xhtml"]),
                                       .rendered(0, "Test passes if you see this.")),
        "ocf-package_multiple": .init("epub-rs#container-default-rendition", .spine(["FOO/BAR/content_001.xhtml"]),
                                      .rendered(0, "Test passes if you see this.")),
        "ocf-url_link-leaking-relative": .init("epub-rs#sec-container-iri-step-parse", .image(0, path: "media/imgs/monastery.jpg")),
        "ocf-url_link-path-absolute": .init("epub-rs#sec-container-iri-root-parse", .image(0, path: "media/imgs/monastery.jpg")),
        "ocf-url_link-relative": .init("epub-rs#sec-container-iri-root", .image(0, path: "media/imgs/monastery.jpg")),
        "ocf-url_manifest": .init("epub-rs#sec-container-iri-root", .spine(["EPUB/foo/content_001.xhtml"]),
                                  .rendered(0, "Test passes if this page opens.")),
        "ocf-url_origin": .init("epub-rs#sec-container-iri-origin", outOfScope: scripting, .disclosed(.scripts)),
        "ocf-url_parse-leaking-relative": .init("epub-rs#sec-container-iri-step-parse", outOfScope: scripting, .disclosed(.scripts)),
        "ocf-url_parse-path-absolute": .init("epub-rs#sec-container-iri-root-parse", outOfScope: scripting, .disclosed(.scripts)),
        "ocf-url_relative": .init("epub-rs#sec-container-iri-root", .spine(["foo/BAR/qux/content_001.xhtml"]),
                                  .rendered(0, "Test passes if this page opens.")),
        "ocf-zip-comp": .init("epub-rs#confreq-zip-comp",
            note: "not exercised: the expanded directory is repacked here with Deflate, so the unsupported compression is gone"),
        "ocf-zip-mult": .init("epub-rs#confreq-zip-mult",
            note: "the expanded directory is repacked whole; the split archive's segment beside it is opened separately and must be refused"),

        // Package document.
        "pkg-collections-unknown": .init("epub-rs#confreq-rs-pkg-collections-unknown", passIfOpens),
        "pkg-creator-order": .init("epub-rs#confreq-rs-pkg-creator-order",
            .authors(["Dave Cramer", "Wendy Reid", "Dan Lazin", "Ivan Herman", "Brady Duga"])),
        "pkg-dir-auto_root-rtl": .init("epub-rs#confreq-rs-pkg-dir-auto", note: "the publication model carries no base direction for metadata",
                                       .title("CSS: مغامرة جديدة!")),
        "pkg-dir-auto_root-unset": .init("epub-rs#confreq-rs-pkg-dir-auto", note: "the publication model carries no base direction for metadata",
                                         .title("CSS: הרפתקה חדשה!")),
        "pkg-dir_but_not_content": .init("epub-rs#confreq-rs-pkg-lang-no-content", .leftToRight(0)),
        "pkg-dir_creator-rtl": .init("epub-rs#confreq-rs-pkg-dir", note: "the publication model carries no base direction for metadata",
                                     .authors(["Dave Cramer"])),
        "pkg-dir_rtl-root-ltr": .init("epub-rs#confreq-rs-pkg-dir", note: "the publication model carries no base direction for metadata",
                                      .title("CSS: הרפתקה חדשה!")),
        "pkg-dir_rtl-root-unset": .init("epub-rs#confreq-rs-pkg-dir", note: "the publication model carries no base direction for metadata",
                                        .title("CSS: הרפתקה חדשה!")),
        "pkg-dir_unset-root-rtl": .init("epub-rs#confreq-rs-pkg-dir", note: "the publication model carries no base direction for metadata",
                                        .title("CSS: مغامرة جديدة!")),
        "pkg-dir_unset-root-unset": .init("epub-rs#confreq-rs-pkg-dir", note: "the publication model carries no base direction for metadata",
                                          .title("CSS: مغامرة جديدة!")),
        // The page's own instructions print « and », so the marks are looked for around the quotation.
        "pkg-lang_but_not_content": .init("epub-rs#confreq-rs-pkg-lang-no-content", .rendered(0, "Le mieux est l'ennemi du bien"),
                                          .renderedInOrder(["“Le mieux est l'ennemi du bien”"]),
                                          .notRendered(0, "«\u{202F}Le mieux"), .notRendered(0, "bien\u{202F}»")),
        "pkg-linked-records": .init("epub-rs#sec-linked-records", .title("Package metadata title!"), .authors(["Matthew Chan"])),
        "pkg-manifest-unknown": .init("epub-rs#confreq-rs-pkg-manifest-unknown", passIfOpens),
        "pkg-manifest-unlisted-resource": .init("epub-rs#confreq-rendition-rs-manifest",
            note: "SHOULD: a resource the manifest does not list is not rendered; the reader shows the archive's red image"),
        "pkg-meta-unknown": .init("epub-rs#confreq-rs-pkg-meta-unknown", passIfOpens),
        "pkg-meta-whitespace": .init("epub-rs#confreq-rs-pkg-whitespace", .title("pkg-meta-whitespace"), .authors(["Dave Cramer"])),
        "pkg-spine-duplicate-item-hyperlink": .init("epub-rs#confreq-rs-pkg-duplicate-item-hyperlink",
            .spine(["EPUB/content_001.xhtml", "EPUB/content_002.xhtml", "EPUB/content_002.xhtml", "EPUB/content_002.xhtml"]),
            .link(0, phrase: "this link", spineIndex: 1)),
        "pkg-spine-duplicate-item-rendering": .init("epub-rs#confreq-rs-pkg-duplicate-item-rendering",
            .spine(["EPUB/content_001.xhtml", "EPUB/content_002.xhtml", "EPUB/content_002.xhtml", "EPUB/content_002.xhtml"]),
            .renderedInOrder(["three identical pages after this one", "This document occurs three times",
                              "This document occurs three times", "This document occurs three times"])),
        "pkg-spine-duplicate-item-ui": .init("epub-rs#confreq-rs-pkg-duplicate-item-ui", .distinctPositions),
        "pkg-spine-nonlinear-activation": .init("epub#confreq-spine-nonlinear", .linear([true, false]),
            .link(0, phrase: "this link", spineIndex: 1), .rendered(1, "Test passes if following the link opens this page.")),
        "pkg-spine-order": .init("epub-rs#sec-pkg-doc-spine",
            .spine(["EPUB/d-content_001.xhtml", "EPUB/c-content_002.xhtml", "EPUB/b-content_003.xhtml", "EPUB/a-content_004.xhtml"]),
            .renderedInOrder(["This page must appear first.", "This page must appear second.", "This page must appear third.",
                              "This page must appear last."])),
        "pkg-spine-order-svg": .init("epub-rs#confreq-rs-spine-order", .spine(["EPUB/1.svg", "EPUB/2.svg", "EPUB/3.svg", "EPUB/4.svg"]),
            .imageCount(0, 1), .imageCount(1, 1), .imageCount(2, 1), .imageCount(3, 1)),
        "pkg-spine-progression-default": .init("epub-rs#confreq-rs-spine-progression-default",
            note: "EPUB RS 3.3: \"the reading system can choose the rendering direction\"; the test expects right to left for its Arabic metadata, the reader keeps left to right",
            .progression("default")),
        "pkg-spine-progression-pre-paginated": .init("epub-rs#confreq-rs-spine-progression-prepaginated", outOfScope: fixedLayout,
            .progression("ltr"), .disclosed(.fixedLayout)),
        "pkg-spine-progression_ltr": .init("epub-rs#confreq-rs-spine-progression", .progression("ltr"),
            .renderedInOrder(["must appear first", "must appear second", "must appear third", "must appear last"])),
        "pkg-spine-progression_rtl": .init("epub-rs#confreq-rs-spine-progression", .progression("rtl"),
            .renderedInOrder(["must appear first", "must appear second", "must appear third", "must appear last"])),
        "pkg-spine-unknown": .init("epub-rs#confreq-rs-pkg-spine-unknown", passIfOpens),
        "pkg-title-order": .init("epub-rs#title-order", .title("pkg-title-order")),
        "pkg-unique-id": .init("epub-rs#confreq-rs-pkg-unique-id", .rendered(0, "Unique identifier not unique")),
        "pkg-unique-id_duplicate": .init("epub-rs#confreq-rs-pkg-unique-id", .rendered(0, "Unique identifier reused")),
        "pkg-version-backward": .init("epub-rs#confreq-rs-backward-epub", passIfOpens),

        // Structural semantics.
        "pss-support": .init("epub-rs#confreq-rs-epubtype-beh", .note(0, id: "the_note", contains: "This text is meant to appear as a footnote."),
                             .notRendered(0, "This text is meant to appear as a footnote.")),
        "pss-support_ignore-title": .init("epub-rs#confreq-rs-epubtype-ignore-element", .noNote(1, id: "the_note")),

        // Publication resources.
        "pub-cmt-avif": .init("epub-rs#confreq-rs-epub3-images", .image(0, path: "EPUB/img/001.avif")),
        "pub-cmt-gif": .init("epub-rs#confreq-rs-epub3-images", .image(0, path: "EPUB/img/001.gif")),
        "pub-cmt-jpeg": .init("epub-rs#confreq-rs-epub3-images", .image(0, path: "EPUB/img/001.jpg")),
        "pub-cmt-jxl": .init("epub-rs#confreq-rs-epub3-images", .image(0, path: "EPUB/img/001.jxl")),
        "pub-cmt-png": .init("epub-rs#confreq-rs-epub3-images", .image(0, path: "EPUB/img/001.png")),
        "pub-cmt-svg": .init("epub-rs#confreq-rs-epub3-images", .image(0, path: "EPUB/img/001.svg")),
        "pub-cmt-webp": .init("epub-rs#confreq-rs-epub3-images", .image(0, path: "EPUB/img/001.webp")),
        "pub-cmt-mp3": .init("epub-rs#confreq-rs-epub3-mp3-aac", outOfScope: "the reader plays no audio; the element's own content stands in, disclosed",
                             .rendered(0, "Audio format is not supported."), .disclosed(.unsupportedElements)),
        "pub-cmt-mp4": .init("epub-rs#confreq-rs-epub3-mp3-aac", outOfScope: "the reader plays no audio; the element's own content stands in, disclosed",
                             .rendered(0, "Audio format is not supported."), .disclosed(.unsupportedElements)),
        "pub-cmt-opus": .init("epub-rs#confreq-rs-epub3-mp3-aac", outOfScope: "the reader plays no audio; the element's own content stands in, disclosed",
                              .rendered(0, "Audio format is not supported."), .disclosed(.unsupportedElements)),
        "pub-data-urls_browsing-context": .init("epub-rs#confreq-rs-data-urls", .imageCount(0, 1), .notDisclosed(.unreadableResources)),
        "pub-data-urls_top-level-content": .init("epub-rs#confreq-rs-data-urls", .imageCount(0, 1), .disclosed(.fixedLayout),
                                                 .notDisclosed(.unreadableResources)),
        "pub-external-links": .init("epub-rs#sec-external-links-open", outOfScope: externalLinks, .externalLink(0, phrase: "External Links")),
        "pub-external-links_consent": .init("epub-rs#sec-external-links-consent", outOfScope: externalLinks,
                                            .externalLink(0, phrase: "'mailto' link")),
        "pub-file-urls": .init("epub-rs#confreq-rs-file-urls", .imageCount(0, 0), .disclosed(.unsupportedElements)),
        "pub-foreign_bad-fallback": .init("epub-rs#confreq-rs-foreign", withheld: [0], .disclosed(.withheld)),
        "pub-foreign_image": .init("epub-rs#confreq-rs-foreign",
            note: "ImageIO decodes the PSD itself, so the PNG fallback is never needed; either image satisfies the requirement", .imageCount(0, 1)),
        "pub-foreign_json-spine": .init("epub-rs#confreq-rs-foreign", .rendered(0, fallbackShown), .notRendered(0, "Test fails")),
        "pub-foreign_xml-spine": .init("epub-rs#confreq-rs-foreign", .rendered(0, fallbackShown), .notRendered(0, "Test fails")),
        "pub-foreign_xml-suffix-spine": .init("epub-rs#confreq-rs-foreign", .rendered(0, fallbackShown), .notRendered(0, "Test fails")),
        "pub-xml-external-id": .init("epub-rs#confreq-rs-xml-extid", outOfScope: entities, withheld: [0], .disclosed(.withheld)),
        "pub-xml-names": .init("epub-rs#confreq-rs-xml-ns", outOfScope: repair, recovered: [0],
            note: "the invalid QName is read as HTML under the #102 namespace-error policy; saved positions are refused and disclosed; strict extraction refuses it (#178)",
            .disclosed(.positionsUnavailable)),
        "pub-xml-non-validating_comment": .init("epub-rs#confreq-rs-xml-nval", .spine(["EPUB/content_001.xhtml", "EPUB/content_002.xhtml"])),
        "pub-xml-non-validating_unclosed": .init("epub-rs#confreq-rs-xml-nval", outOfScope: repair, recovered: [0],
                                                 .disclosed(.positionsUnavailable)),

        // Security and privacy.
        "sec-untrusted-consent_network": .init("epub-rs#security-privacy-recommendations-sideloaded-consent", .imageCount(0, 0),
            .disclosed(.remoteResources), .disclosed(.unsupportedElements)),
        "sec-untrusted-consent_scripting": .init("epub-rs#security-privacy-recommendations-sideloaded-consent",
            .rendered(0, "No script has been executed."), .disclosed(.scripts)),

        // Scripting: only its fallback is in scope for a reader that runs nothing.
        "scr-support-fallback": .init("epub-rs#confreq-rs-scripted-flbk", .rendered(0, "Test passes."), .notRendered(0, "the test fails")),
        "scr-not-support_ccscript-modify-host": .init("epub-rs#confreq-rs-scripted-container-dom", outOfScope: scripting,
                                                      .disclosed(.unsupportedElements)),
        "scr-not-support_ccscript-modify-size": .init("epub-rs#confreq-rs-scripted-container-size", outOfScope: scripting,
                                                      .disclosed(.unsupportedElements)),

        // Media overlays: a reader without them ignores the attributes and the SMIL items.
        "mol-ignore": .init("epub-rs#confreq-rs-epub3-mo-ignore", .rendered(1, "Call me Ishmael.")),

        // Layout rendering control.
        "lay-pkg-flow-paginated": .init("epub-rs#paginated", note: "SHOULD: rendition:flow is not read; the host chooses the flow"),
        "lay-pkg-flow-scrolled-continuous": .init("epub-rs#scrolled-continuous", note: "SHOULD: rendition:flow is not read; the host chooses the flow"),
        "lay-pkg-flow-scrolled-doc": .init("epub-rs#scrolled-doc", note: "SHOULD: rendition:flow is not read; the host chooses the flow"),
        "lay-reflow-align-x-center": .init("epub-rs#reflow-align-x-center", outOfScope: verticalWriting,
            note: "SHOULD: rendition:align-x-center is not read", .progression("rtl")),
        "lay-fxl-layout-default": .init("epub-rs#layout-default", .layouts(["reflowable"]), .notDisclosed(.fixedLayout)),
        "lay-pp-layout-default": .init("epub-rs#layout-default", .layouts(["reflowable"]), .notDisclosed(.fixedLayout)),
        "lay-page-layout-both": .init("epub-rs#page-layout-both", outOfScope: fixedLayout,
            .layouts(["prePaginated", "reflowable", "prePaginated", "prePaginated"]), .disclosed(.fixedLayout)),
        "lay-page-layout-both-spread": .init("epub-rs#page-spread-both", outOfScope: fixedLayout,
            .layouts(["prePaginated", "reflowable", "prePaginated", "reflowable", "prePaginated"]), .disclosed(.fixedLayout)),
        "lay-rendition-flow-pre-pag": .init("epub-rs#flow-pre-pag", outOfScope: fixedLayout,
            .layouts(["reflowable", "prePaginated", "prePaginated", "reflowable"]), .disclosed(.fixedLayout)),
        "lay-viewport-meta-prop": .init("epub-rs#viewport-meta-prop", outOfScope: fixedLayout, .disclosed(.fixedLayout)),
        "fxl-spine-overrides_behave-as-global": .init("epub-rs#confreq-rs-pkg-spine-override", outOfScope: fixedLayout,
            .layouts(["prePaginated", "reflowable"]), .disclosed(.fixedLayout)),
        "fxl-spine-overrides_behave-as-global-bis": .init("epub-rs#confreq-rs-pkg-spine-override", outOfScope: fixedLayout,
            .layouts(["reflowable", "prePaginated", "reflowable"]), .disclosed(.fixedLayout)),
        "fxl-spine-overrides_duplicate": .init("epub-rs#confreq-rs-pkg-spine-override-first", outOfScope: fixedLayout,
            .layouts(["prePaginated", "reflowable"]), .disclosed(.fixedLayout)),
        "lay-pp-spine-overrides_behave-as-global": .init("epub-rs#confreq-rs-pkg-spine-override", outOfScope: fixedLayout,
            .layouts(["prePaginated", "reflowable"]), .disclosed(.fixedLayout)),
        "lay-pp-spine-overrides_behave-as-global-bis": .init("epub-rs#confreq-rs-pkg-spine-override", outOfScope: fixedLayout,
            .layouts(["reflowable", "prePaginated", "reflowable"]), .disclosed(.fixedLayout)),
        // Pre-paginated pages that are one image or drawing are shown whole (#5): Kate
        // Greenaway's "A Apple Pie", its pages as XHTML with an image, as XHTML with an SVG,
        // as raster images in the spine with XHTML fallbacks, and mixed.
        "lay-pp-embedded-images": .init("epub-rs#confreq-rs-epub3-fxl", .fixedPages(Array(0...8)), .notDisclosed(.fixedLayout)),
        "lay-pp-embedded-images-svg": .init("epub-rs#confreq-rs-epub3-fxl", .fixedPages(Array(0...8)), .notDisclosed(.fixedLayout)),
        "lay-pp-images-in-spine": .init("epub-rs#confreq-rs-epub3-fxl", .fixedPages(Array(0...8)), .notDisclosed(.fixedLayout),
            .notDisclosed(.positionsUnavailable)),
        "lay-pp-images-mixed": .init("epub-rs#confreq-rs-epub3-fxl", .fixedPages(Array(0...8)), .notDisclosed(.fixedLayout),
            .notDisclosed(.positionsUnavailable)),
        "lay-pp-spine-overrides_image-only-pp": .init("epub-rs#confreq-rs-pkg-spine-override",
            .layouts(["prePaginated", "reflowable"]), .fixedPages([0]), .notDisclosed(.fixedLayout)),
        "lay-pp-spine-overrides_image-only-reflow": .init("epub-rs#confreq-rs-pkg-spine-override",
            .layouts(["reflowable", "prePaginated", "reflowable"]), .fixedPages([1]), .notDisclosed(.fixedLayout)),
        "lay-pp-spine-overrides_image-spine-pp": .init("epub-rs#confreq-rs-pkg-spine-override",
            .layouts(["prePaginated", "reflowable"]), .fixedPages([0]), .notDisclosed(.fixedLayout)),
        "lay-pp-spine-overrides_image-spine-reflow": .init("epub-rs#confreq-rs-pkg-spine-override",
            .layouts(["reflowable", "prePaginated", "reflowable"]), .fixedPages([1]), .notDisclosed(.fixedLayout)),
        "xx-epub-template": .init("template", note: "the suite's own template"),
    ]

    // MARK: Packing

    /// The test directories under `root`, by id, in order. Loose files (a split archive's
    /// segment, the suite's own packing script) are not tests.
    public static func testDirectories(under root: URL) throws -> [(id: String, url: URL)] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { ($0.lastPathComponent, $0) }
            .sorted { $0.0 < $1.0 }
    }

    /// The segments of split archives lying beside the test directories.
    public static func splitArchiveSegments(under root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { $0.pathExtension.lowercased() == "z01" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }
    }

    /// The regular files of an expanded EPUB by archive path. Symbolic links and anything that
    /// is not a regular file are left out, and no file is opened through a link.
    public static func files(ofExpandedEPUBAt directory: URL) throws -> [String: Data] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let base = directory.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [:] }
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true, url.lastPathComponent != ".DS_Store" else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            files[String(path.dropFirst(base.count + 1))] = try Data(contentsOf: url)
        }
        return files
    }

    /// An OCF ZIP container of an expanded EPUB: `mimetype` first and stored, the rest deflated.
    public static func archive(ofExpandedEPUBAt directory: URL) throws -> Data {
        try Fixture.archive(files(ofExpandedEPUBAt: directory))
    }
}
