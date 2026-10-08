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

// SKELETON: a deliberately small builder (paragraphs, inline font styles, links, anchors and an
// exact text map) so the session and views can run early. The text workstream replaces its
// internals with the full block/inline model; `build(_:)` keeps this signature and contract.
enum SectionBuilder {
    /// Builds one spine item. Never throws: a section that cannot be read becomes a short notice
    /// paragraph with `report.withheld` set, so the rest of the book stays readable.
    static func build(_ request: SectionBuildRequest) -> SectionText {
        let item = request.publication.spine[request.spineIndex]
        do {
            let data = try request.publication.data(for: item.resource)
            let document = try ContentDocument.parse(data, path: item.resource.path)
            var builder = SkeletonBuilder(request: request, document: document)
            return builder.run()
        } catch {
            return withheld(request, reason: error)
        }
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

private struct SkeletonBuilder {
    let request: SectionBuildRequest
    let document: ContentDocument
    let resolver: StyleResolver
    let output = NSMutableAttributedString()
    var map = TextMap()
    var anchors: [String: Int] = [:]
    var pendingAnchors: [String] = []
    var pendingSpace = false
    var paragraphStart = 0
    var blockStyle: ComputedStyle
    let report = SectionReportBox()

    init(request: SectionBuildRequest, document: ContentDocument) {
        self.request = request; self.document = document
        var report = SectionReport()
        let sheets = SectionStyles.load(for: document, publication: request.publication, report: &report)
        resolver = StyleResolver(document: document, stylesheets: sheets, typography: request.typography)
        blockStyle = resolver.initialStyle
        self.report.report = report
    }

    mutating func run() -> SectionText {
        let rootStyle = resolver.style(for: document.root, parent: resolver.initialStyle)
        if let body = document.body { walk(body, parent: rootStyle, link: nil) }
        endParagraph()
        while output.length > 0, output.string.utf16.last == 0x0A { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }
        for id in pendingAnchors { anchors[id] = output.length }
        map.length = output.length
        report.report.recoveredAsHTML = document.recoveredAsHTML
        let item = request.publication.spine[request.spineIndex]
        let title = document.head?.elementChildren.first { $0.isHTML("title") }?.textContent
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return SectionText(spineIndex: request.spineIndex, href: item.resource.href, document: document,
                           string: output, map: map, anchors: anchors, notes: [:],
                           title: title?.isEmpty == false ? title : nil, report: report.report)
    }

    private func attributes(_ style: ComputedStyle, link: ReaderLink?) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: request.fonts.font(for: style),
            .foregroundColor: link != nil ? ReaderPalette.link(dark: request.typography.isDark)
                : ReaderPalette.text(dark: request.typography.isDark),
        ]
        if let link { attributes[.link] = link.url }
        if style.verticalAlign == .super { attributes[.baselineOffset] = style.fontSize * 0.4 }
        if style.verticalAlign == .sub { attributes[.baselineOffset] = -style.fontSize * 0.2 }
        if style.textDecoration.contains(.underline) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.textDecoration.contains(.lineThrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }

    private mutating func walk(_ node: ContentNode, parent: ComputedStyle, link: ReaderLink?) {
        if node.isText { append(node, style: parent, link: link); return }
        let style = resolver.style(for: node, parent: parent)
        if let id = node.id { pendingAnchors.append(id) }
        guard style.display != .none else { return }
        if node.isHTML("script") { report.report.scriptsRefused += 1; return }
        var link = link
        if node.isHTML("a"), let href = node.attribute("href") {
            if let resolved = try? ResourceReference.resolve(href, relativeTo: document.path) {
                link = .internal(href: resolved)
            } else { link = .external(href) }
        }
        if node.isHTML("br") { appendGenerated("\u{2028}", style: style); pendingSpace = false; return }
        let block = style.display.isBlockLevel
        if block { endParagraph(); blockStyle = style }
        let rich = richContent(node, style: style)
        if let rich {
            flushAnchors()
            let location = output.length
            output.append(rich)
            map.append(.init(location: location, length: rich.length, node: node.order, offset: 0, sourceLength: 0, isExact: false))
            pendingSpace = false
        } else {
            for child in node.children { walk(child, parent: style, link: link) }
        }
        if block { endParagraph(); blockStyle = parent }
    }

    private func richContent(_ node: ContentNode, style: ComputedStyle) -> NSAttributedString? {
        let context = RichContentContext(
            publication: request.publication, document: document, spineIndex: request.spineIndex,
            typography: request.typography, fonts: request.fonts,
            style: { [resolver] in resolver.style(for: $0, parent: $1) },
            renderContent: { [request] element, style in
                NSAttributedString(string: element.textContent, attributes: [.font: request.fonts.font(for: style)])
            },
            resolve: { [document] reference in
                (try? ResourceReference.resolve(reference, relativeTo: document.path))
                    .map { String($0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]).removingPercentEncoding ?? $0 }
            },
            report: report)
        if node.isHTML("img") { return request.rich.image(node, style: style, context: context) }
        if node.isHTML("hr") { return request.rich.horizontalRule(node, style: style, context: context) }
        if node.isHTML("table") { return request.rich.table(node, style: style, context: context) }
        if node.namespace == ContentNamespace.mathML, node.name == "math" { return request.rich.math(node, style: style, context: context) }
        if node.namespace == ContentNamespace.svg, node.name == "svg" { return request.rich.svg(node, style: style, context: context) }
        return nil
    }

    private mutating func flushAnchors() {
        for id in pendingAnchors where anchors[id] == nil { anchors[id] = output.length }
        pendingAnchors.removeAll()
    }

    private mutating func append(_ node: ContentNode, style: ComputedStyle, link: ReaderLink?) {
        let attributes = attributes(style, link: link)
        let units = Array(node.text.utf16)
        var index = 0
        while index < units.count {
            let unit = units[index]
            let isSpace = unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0C
            if isSpace && !style.whiteSpace.preservesSpaces {
                var end = index
                while end < units.count, [0x20, 0x09, 0x0A, 0x0D, 0x0C].contains(units[end]) { end += 1 }
                if output.length > paragraphStart { pendingSpace = true }
                index = end
                continue
            }
            if pendingSpace {
                let location = output.length
                output.append(NSAttributedString(string: " ", attributes: attributes))
                map.append(.init(location: location, length: 1, node: node.order, offset: max(0, index - 1), sourceLength: 1, isExact: false))
                pendingSpace = false
            }
            var end = index
            while end < units.count, style.whiteSpace.preservesSpaces || ![0x20, 0x09, 0x0A, 0x0D, 0x0C].contains(units[end]) { end += 1 }
            flushAnchors()
            let location = output.length
            output.append(NSAttributedString(string: String(utf16CodeUnits: Array(units[index..<end]), count: end - index), attributes: attributes))
            map.append(.init(location: location, length: end - index, node: node.order, offset: index, sourceLength: end - index, isExact: true))
            index = end
        }
    }

    private mutating func appendGenerated(_ string: String, style: ComputedStyle) {
        output.append(NSAttributedString(string: string, attributes: attributes(style, link: nil)))
    }

    private mutating func endParagraph() {
        pendingSpace = false
        guard output.length > paragraphStart else { return }
        let paragraph = NSMutableParagraphStyle()
        let em = blockStyle.fontSize
        paragraph.paragraphSpacing = blockStyle.margin.bottom.resolve(reference: 0, viewport: .zero) ?? em * 0.5
        paragraph.paragraphSpacingBefore = blockStyle.margin.top.resolve(reference: 0, viewport: .zero) ?? 0
        paragraph.alignment = blockStyle.textAlign == .center ? .center : .natural
        paragraph.lineHeightMultiple = 1.2
        output.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: paragraphStart, length: output.length - paragraphStart))
        output.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
        paragraphStart = output.length
    }
}
