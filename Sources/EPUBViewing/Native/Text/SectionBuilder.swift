import EPUBCore
import EPUBReading
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SectionBuildRequest: @unchecked Sendable {
    let publication: EPUBPublication
    let spineIndex: Int
    let typography: NativeTypography
    let fonts: FontRegistry
    let rich: any RichContentFactory
}

/// The computed style of an element given its parent's computed style: the cascade, injected so
/// the builder can be exercised with arbitrary computed values.
typealias SectionStyleFunction = (_ element: ContentNode, _ parent: ComputedStyle) -> ComputedStyle

/// Builds a spine item's attributed text in one walk of its DOM: CSS block boxes become
/// paragraphs (collapsed vertical margins as paragraph spacing, accumulated horizontal boxes as
/// indents), inline boxes become attribute runs, and every rendered character is mapped back to
/// the DOM. `SectionWriter` describes the model and its simplifications.
///
/// Builds are independent and run off the main thread, concurrently across sections. The only
/// objects they share are the font registry and the rich-content factory, both thread-safe.
enum SectionBuilder {
    /// Builds one spine item. Never throws: a section that cannot be read becomes a short notice
    /// paragraph with `report.withheld` set, so the rest of the book stays readable.
    static func build(_ request: SectionBuildRequest) -> SectionText {
        let item = request.publication.spine[request.spineIndex]
        let document: ContentDocument
        do {
            let data = try request.publication.data(for: item.resource)
            document = try ContentDocument.parse(data, path: item.resource.path)
        } catch {
            return withheld(request, reason: error)
        }
        var report = SectionReport()
        let sheets = SectionStyles.load(for: document, publication: request.publication, fonts: request.fonts, report: &report)
        let resolver = StyleResolver(document: document, stylesheets: sheets, typography: request.typography)
        report.stylesTruncated = report.stylesTruncated || resolver.stylesTruncated
        return build(document: document, request: request, initialStyle: resolver.initialStyle, report: report) {
            resolver.style(for: $0, parent: $1)
        }
    }

    /// The builder proper, over an already parsed document and an injected cascade.
    /// `initialStyle` is what the root element inherits (by default the reader's base size).
    static func build(document: ContentDocument, request: SectionBuildRequest, initialStyle: ComputedStyle? = nil,
                      report: SectionReport = SectionReport(), style: @escaping SectionStyleFunction) -> SectionText {
        let item = request.publication.spine[request.spineIndex]
        let state = SectionBuildState(request: request, document: document, style: style,
                                      initialStyle: initialStyle ?? ComputedStyle(fontSize: request.typography.fontSize))
        state.report.report = report
        state.report.report.recoveredAsHTML = report.recoveredAsHTML || document.recoveredAsHTML
        if item.layout == .prePaginated { state.report.report.fixedLayoutReflowed = true }
        state.report.report.scriptsRefused += document.nodes.reduce(0) { count, node in
            count + (node.isElement && node.name == "script"
                && (node.isHTML || node.namespace == ContentNamespace.svg) ? 1 : 0)
        }
        let output = SectionWriter(state: state, mode: .section).renderSection()
        let title = document.head?.elementChildren.first { $0.isHTML("title") }?.textContent
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return SectionText(spineIndex: request.spineIndex, href: item.resource.href, document: document,
                           string: output.string, map: output.map, anchors: output.anchors, notes: state.notes,
                           title: title?.isEmpty == false ? title : nil, report: state.report.report)
    }

    static func withheld(_ request: SectionBuildRequest, reason: Error) -> SectionText {
        let item = request.publication.spine[request.spineIndex]
        let empty = try! ContentDocument.parse(Data("<html xmlns='http://www.w3.org/1999/xhtml'><body/></html>".utf8),
                                               path: item.resource.path)
        var report = SectionReport()
        report.withheld = true
        let notice = NSAttributedString(string: "This section could not be shown.", attributes: [
            .font: request.fonts.font(for: ComputedStyle(fontSize: request.typography.fontSize)),
            .foregroundColor: ReaderPalette.secondaryText(dark: request.typography.isDark),
        ])
        return SectionText(spineIndex: request.spineIndex, href: item.resource.href, document: empty, string: notice,
                           map: TextMap(length: notice.length), anchors: [:], notes: [:], title: nil, report: report)
    }
}

/// Everything one section build shares between the section's writer and the nested writers it
/// starts for table cells and captions (`RichContentContext.renderContent`) and for notes.
final class SectionBuildState {
    let request: SectionBuildRequest
    let document: ContentDocument
    let style: SectionStyleFunction
    let initialStyle: ComputedStyle
    let report = SectionReportBox()
    let styling: InlineStyling
    var notes: [String: NSAttributedString] = [:]
    /// The body's computed style: notes are styled like body text.
    var bodyStyle: ComputedStyle
    /// The publication's first language, for a document that declares none.
    let defaultLanguage: String?
    /// A pre-paginated spine item, reflowed: its absolutely positioned boxes stay in the flow.
    let isFixedLayout: Bool
    /// Nesting of `renderContent` and note captures, bounded so hostile nesting cannot recurse deeply.
    private var nesting = 0
    private static let maximumNesting = 8
    /// UTF-16 units all of a section's notes may hold. Notes never repeat one another's text (a
    /// note leaves out the notes nested in it), so only hostile markup comes near this.
    static let maximumNoteLength = 4 << 20
    private var noteBudget = SectionBuildState.maximumNoteLength
    /// Whether each node (by order) has an endnotes container among its ancestors, computed in one
    /// pass when first needed, so classifying notes is not quadratic in their nesting.
    private lazy var insideEndnotes: [Bool] = {
        var inside = [Bool](repeating: false, count: document.nodes.count)
        for node in document.nodes where node.isElement {
            if let parent = node.parent {
                inside[node.order] = inside[parent.order] || ContentSemantics.isEndnotesContainer(parent)
            }
        }
        return inside
    }()

    init(request: SectionBuildRequest, document: ContentDocument, style: @escaping SectionStyleFunction,
         initialStyle: ComputedStyle) {
        self.request = request; self.document = document; self.style = style; self.initialStyle = initialStyle
        bodyStyle = initialStyle
        styling = InlineStyling(fonts: request.fonts, isDark: request.typography.isDark)
        defaultLanguage = request.publication.metadata.languages.first.flatMap { $0.isEmpty ? nil : $0 }
        isFixedLayout = request.publication.spine[request.spineIndex].layout == .prePaginated
    }

    private(set) lazy var richContext = RichContentContext(
        publication: request.publication, document: document, spineIndex: request.spineIndex,
        typography: request.typography, fonts: request.fonts,
        style: { [unowned self] in self.style($0, $1) },
        renderContent: { [unowned self] in self.renderContent($0, style: $1) },
        resolve: { [unowned self] in self.resolveResource($0) },
        report: report)

    /// An element's children rendered into a separate string, as the section renders a block's
    /// content, with no text map. Too deep a nesting renders the plain text instead.
    func renderContent(_ element: ContentNode, style: ComputedStyle) -> NSAttributedString {
        guard nesting < Self.maximumNesting else {
            let text = element.textContent.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return NSAttributedString(string: text, attributes: [
                .font: request.fonts.font(for: style),
                .foregroundColor: ReaderPalette.text(dark: request.typography.isDark),
            ])
        }
        nesting += 1
        defer { nesting -= 1 }
        return SectionWriter(state: self, mode: .detached).renderContent(of: element, style: style)
    }

    /// The note an element is, with endnote scopes memoized.
    func noteKind(_ element: ContentNode) -> ContentSemantics.NoteKind? {
        ContentSemantics.noteKind(element) { self.insideEndnotes[$0.order] }
    }

    /// Captures a note element's content once, under its `id` and the ids of its leading
    /// descendants (a noteref may name the note's first paragraph rather than the note).
    ///
    /// Only the section's own walk captures notes, and it reaches every element once. A note's
    /// content leaves out the notes nested in it, which are captured on their own, so notes never
    /// repeat each other's text however deeply they nest; the note budget bounds the rest.
    func captureNote(_ element: ContentNode) {
        guard let id = element.id, notes[id] == nil, noteBudget > 0, nesting < Self.maximumNesting else { return }
        notes[id] = NSAttributedString() // Claims the id, so a note cannot capture itself again.
        nesting += 1
        defer { nesting -= 1 }
        var content = SectionWriter(state: self, mode: .note(id: id)).renderNote(element)
        if content.length > noteBudget {
            let end = (content.string as NSString).rangeOfComposedCharacterSequence(at: noteBudget).location
            content = content.attributedSubstring(from: NSRange(location: 0, length: end))
        }
        noteBudget -= content.length
        notes[id] = content
        var leading = element.elementChildren.first
        while let node = leading {
            if let alias = node.id, notes[alias] == nil { notes[alias] = content }
            leading = node.elementChildren.first
        }
    }

    /// `RichContentContext.resolve`: the decoded archive path of a local reference. Remote and
    /// other non-archive references count as refused (`data:` URIs as unreadable) and return nil.
    func resolveResource(_ reference: String) -> String? {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return nil }
        guard let path = archivePath(of: reference) else {
            if reference.lowercased().hasPrefix("data:") { report.report.unreadableResources += 1 }
            else { report.report.remoteResourcesRefused += 1 }
            return nil
        }
        return path
    }

    /// The manifest media type of a local reference, without counting anything.
    func mediaType(of reference: String) -> String? {
        guard let path = archivePath(of: reference) else { return nil }
        return request.publication.resources.first { $0.path == path }?.mediaType
    }

    private func archivePath(of reference: String) -> String? {
        guard let resolved = try? ResourceReference.resolve(reference, relativeTo: document.path) else { return nil }
        let path = String(resolved.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        return path.removingPercentEncoding ?? path
    }
}
