import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public extension Fixture {
    /// A book assembled part by part, for tests that each exercise one requirement of EPUB 3.3
    /// and EPUB Reading Systems 3.3. Original synthetic content; no external corpus or network.
    ///
    /// Every part has a conventional default (an `EPUB/package.opf` package, a navigation
    /// document listing the linear sections, pretty-printed XHTML with an HTML DOCTYPE), and
    /// every part can be replaced, so a test states only what its requirement is about.
    struct SpecBook: Sendable {
        public struct Section: Sendable {
            /// Path from the package directory, as a manifest href writes it.
            public var href: String
            public var id: String
            public var mediaType: String
            /// The document's bytes.
            public var data: Data
            /// Further attributes of the manifest item (`properties`, `fallback`).
            public var item: String
            /// Further attributes of the spine itemref (`linear`, `properties`).
            public var itemref: String
            /// The archive path's last components when they differ from the href (percent-encoding).
            public var path: String?
        }

        /// The package document's directory; empty puts it at the archive root.
        public var directory = "EPUB"
        public var packageName = "package.opf"
        public var version = "3.0"
        public var packageAttributes = ""
        public var identifier = "urn:uuid:5f0f2f0e-1d5c-4b63-9c1a-0d2b6a3e7c11"
        /// The metadata element's content, without the identifier.
        public var metadata = "<dc:title>A Conformance Book</dc:title>\n    <dc:creator>Test Author</dc:creator>\n    <dc:language>en</dc:language>"
        public var sections: [Section] = []
        /// Further manifest items, as written.
        public var manifest = ""
        public var spineAttributes = ""
        /// The spine's itemrefs as written, in place of one per section.
        public var spine: String?
        /// What follows the spine: a guide, collections, bindings.
        public var trailer = ""
        /// The navigation document's body; nil lists the sections in a `toc` nav.
        public var navigation: String?
        /// The navigation document's manifest attributes; nil leaves it out of the manifest.
        public var navigationItem: String? = "properties=\"nav\""
        /// Other files by path from the package directory.
        public var files: [String: Data] = [:]
        /// Other files by archive path.
        public var rootFiles: [String: Data] = [:]
        /// `META-INF/container.xml` as written, in place of one naming the package document.
        public var container: String?

        public init() {}

        /// An XHTML content document as authoring tools write one.
        public static func xhtml(title: String = "Section", head: String = "", root: String = "", body: String) -> String {
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"\(root.isEmpty ? "" : " " + root)>
            <head>
            <title>\(title)</title>\(head)
            </head>
            <body>\(body)</body>
            </html>

            """
        }

        /// Adds an XHTML section named `name.xhtml` to the manifest and the spine.
        @discardableResult
        public mutating func add(_ name: String, title: String? = nil, head: String = "", root: String = "", item: String = "",
                                 itemref: String = "", body: String) -> Self {
            add(href: name + ".xhtml", id: name.replacingOccurrences(of: "/", with: "-"), mediaType: "application/xhtml+xml",
                Data(Self.xhtml(title: title ?? name, head: head, root: root, body: body).utf8), item: item, itemref: itemref)
        }

        /// Adds a spine item with these bytes.
        @discardableResult
        public mutating func add(href: String, id: String, mediaType: String, _ data: Data, item: String = "",
                                 itemref: String = "", path: String? = nil) -> Self {
            sections.append(Section(href: href, id: id, mediaType: mediaType, data: data, item: item, itemref: itemref, path: path))
            return self
        }

        /// Adds a manifest resource that is not in the spine.
        @discardableResult
        public mutating func resource(_ href: String, id: String, mediaType: String, _ data: Data, item: String = "",
                                      path: String? = nil) -> Self {
            manifest += "\n    <item id=\"\(id)\" href=\"\(href)\" media-type=\"\(mediaType)\"\(item.isEmpty ? "" : " " + item)/>"
            files[path ?? href] = data
            return self
        }

        public var packagePath: String { directory.isEmpty ? packageName : directory + "/" + packageName }
        private func archivePath(_ path: String) -> String { directory.isEmpty ? path : directory + "/" + path }

        public var package: String {
            let items = sections.map {
                "    <item id=\"\($0.id)\" href=\"\($0.href)\" media-type=\"\($0.mediaType)\"\($0.item.isEmpty ? "" : " " + $0.item)/>"
            }.joined(separator: "\n")
            let nav = navigationItem.map { "\n    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\"\($0.isEmpty ? "" : " " + $0)/>" } ?? ""
            let itemrefs = spine ?? sections.map { "    <itemref idref=\"\($0.id)\"\($0.itemref.isEmpty ? "" : " " + $0.itemref)/>" }.joined(separator: "\n")
            return """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="\(version)" unique-identifier="uid"\(packageAttributes.isEmpty ? "" : " " + packageAttributes)>
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">\(identifier)</dc:identifier>
                \(metadata)
                <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
              </metadata>
              <manifest>
            \(items)\(nav)\(manifest)
              </manifest>
              <spine\(spineAttributes.isEmpty ? "" : " " + spineAttributes)>
            \(itemrefs)
              </spine>\(trailer)
            </package>

            """
        }

        public var navigationDocument: String {
            let entries = sections.filter { $0.mediaType == "application/xhtml+xml" && !$0.itemref.contains("linear=\"no\"") }
                .map { "      <li><a href=\"\($0.href)\">\($0.id)</a></li>" }.joined(separator: "\n")
            return Self.xhtml(title: "Contents", body: navigation ?? "\n<nav epub:type=\"toc\">\n    <ol>\n\(entries)\n    </ol>\n</nav>\n")
        }

        public var archiveFiles: [String: Data] {
            var all: [String: Data] = [
                "mimetype": Data("application/epub+zip".utf8),
                "META-INF/container.xml": Data((container ?? """
                <?xml version="1.0" encoding="UTF-8"?>
                <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <rootfiles>
                    <rootfile full-path="\(packagePath)" media-type="application/oebps-package+xml"/>
                  </rootfiles>
                </container>

                """).utf8),
                packagePath: Data(package.utf8),
            ]
            if navigationItem != nil || navigation != nil { all[archivePath("nav.xhtml")] = Data(navigationDocument.utf8) }
            for section in sections { all[archivePath(section.path ?? section.href)] = section.data }
            for (path, data) in files { all[archivePath(path)] = data }
            for (path, data) in rootFiles { all[path] = data }
            return all
        }

        public func archive() throws -> Data { try Fixture.archive(archiveFiles) }

        // MARK: Resources

        /// A solid image of the given pixel size, encoded as `type`.
        public static func image(width: Int, height: Int, as type: UTType = .png, red: CGFloat = 0.2, green: CGFloat = 0.4,
                                 blue: CGFloat = 0.8) -> Data {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            precondition(CGImageDestinationFinalize(destination))
            return data as Data
        }

        /// A standalone SVG drawing of the given size.
        public static func svg(width: Int, height: Int, title: String = "A drawing", label: String = "") -> String {
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)">
              <title>\(title)</title>
              <rect width="\(width)" height="\(height)" fill="#336699"/>
              <circle cx="\(width / 2)" cy="\(height / 2)" r="\(min(width, height) / 4)" fill="#ffcc00"/>\(label.isEmpty ? "" : "\n  <text x=\"10\" y=\"20\">\(label)</text>")
            </svg>

            """
        }

        /// Sentences of ordinary prose, each in its own paragraph, numbered so order shows.
        public static func prose(_ count: Int, label: String = "Paragraph") -> String {
            (1...max(1, count)).map { "\n<p>\(label) \($0) of ordinary reading text, long enough to fill a line or two of a page.</p>" }.joined()
        }
    }
}
