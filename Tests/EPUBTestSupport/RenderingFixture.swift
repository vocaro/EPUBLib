import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension Fixture {
    public enum Rendering: String, CaseIterable, Sendable {
        case escapedHref, fixedLayout, rightToLeft, vertical, largeIllustrated
    }

    /// Original synthetic content; no external corpus or network dependency.
    public static func rendering(_ kind: Rendering) throws -> Data {
        var files = try files()
        var opf = String(decoding: files["OPS/book.opf"]!, as: UTF8.self)
        var nav = String(decoding: files["OPS/nav.xhtml"]!, as: UTF8.self)
        switch kind {
        case .escapedHref:
            // Lowercase escapes and an unnecessarily escaped letter must normalize too.
            let encoded = "%63hapter%20%23100%25%3f.xhtml"
            opf = opf.replacingOccurrences(of: "one.xhtml", with: encoded)
            nav = nav.replacingOccurrences(of: "one.xhtml", with: encoded)
            files["OPS/chapter #100%?.xhtml"] = files.removeValue(forKey: "OPS/one.xhtml")
            nav = nav.replacingOccurrences(of: "#start", with: "#start%20%2350%25")
            files["OPS/chapter #100%?.xhtml"] = Data(String(decoding: files["OPS/chapter #100%?.xhtml"]!, as: UTF8.self)
                .replacingOccurrences(of: "id=\"start\"", with: "id=\"start #50%\"").utf8)
        case .fixedLayout:
            opf = opf.replacingOccurrences(of: "</metadata>", with:
                "<meta property='rendition:layout'>pre-paginated</meta></metadata>")
            // Two pages that position HTML text, which reflow, then a page of each shape the
            // reader shows whole (#5): an XHTML page of one raster image, one of one inline
            // SVG, an SVG document and a raster image in the spine, with its XHTML fallback.
            for name in ["one", "two"] {
                files["OPS/\(name).xhtml"] = Data("""
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Fixed \(name)</title>
                <meta name="viewport" content="width=600,height=800"/>
                <style>body { width:600px; height:800px; margin:0; background:#eef; } h1 { position:absolute; top:80px; left:40px; }</style>
                </head><body><h1 id="start">Fixed \(name)</h1><svg xmlns="http://www.w3.org/2000/svg" width="300" height="200"><rect width="300" height="200" fill="orange"/></svg></body></html>
                """.utf8)
            }
            files["OPS/plate.png"] = SpecBook.image(width: 600, height: 800)
            files["OPS/landscape.png"] = SpecBook.image(width: 1000, height: 600, red: 0.8, green: 0.4, blue: 0.2)
            files["OPS/image-page.xhtml"] = Data("""
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Image page</title>
            <meta name="viewport" content="width=600, height=800"/><style>body { margin:0 } img { width:100%; height:100% }</style>
            </head><body><div><img src="plate.png" alt="A plate of the fixed-layout fixture"/></div></body></html>
            """.utf8)
            files["OPS/drawing-page.xhtml"] = Data("""
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Drawing page</title>
            <meta name="viewport" content="width=600, height=800"/></head><body>
            <svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%" viewBox="0 0 600 800"><title>A drawn page</title>
            <rect width="600" height="800" fill="#cde"/><text x="40" y="120" font-size="48">Drawn page words</text></svg></body></html>
            """.utf8)
            files["OPS/page.svg"] = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 800"><title>An SVG page</title>
            <rect width="600" height="800" fill="#edc"/><text x="40" y="120" font-size="48">SVG page words</text></svg>
            """.utf8)
            files["OPS/landscape.xhtml"] = Data("""
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Landscape</title></head><body><p>A landscape plate.</p></body></html>
            """.utf8)
            opf = opf.replacingOccurrences(of: "</manifest>", with: """
                <item id="image-page" href="image-page.xhtml" media-type="application/xhtml+xml"/>\
                <item id="drawing-page" href="drawing-page.xhtml" media-type="application/xhtml+xml" properties="svg"/>\
                <item id="svg-page" href="page.svg" media-type="image/svg+xml"/>\
                <item id="plate" href="plate.png" media-type="image/png"/>\
                <item id="landscape-text" href="landscape.xhtml" media-type="application/xhtml+xml"/>\
                <item id="landscape" href="landscape.png" media-type="image/png" fallback="landscape-text"/></manifest>
                """)
                .replacingOccurrences(of: "<itemref idref=\"two\"/>", with: """
                <itemref idref="two"/><itemref idref="image-page"/><itemref idref="drawing-page"/>\
                <itemref idref="svg-page"/><itemref idref="landscape"/>
                """)
        case .rightToLeft, .vertical:
            if kind == .rightToLeft {
                opf = opf.replacingOccurrences(of: "<spine ", with: "<spine page-progression-direction='rtl' ")
            }
            for name in ["one", "two"] {
                let html = String(decoding: files["OPS/\(name).xhtml"]!, as: UTF8.self)
                    .replacingOccurrences(of: "<html ", with: kind == .rightToLeft ? "<html dir='rtl' lang='ar' " : "<html lang='ja' ")
                    .replacingOccurrences(of: "</head>", with: kind == .vertical ? "<style>html { writing-mode:vertical-rl; }</style></head>" : "</head>")
                    .replacingOccurrences(of: "A paragraph of ordinary reading text for pagination.", with:
                        kind == .rightToLeft ? "هذا نص عربي لاختبار اتجاه القراءة والتنقل بين الصفحات." : "これは縦書きの表示とページ移動を確認するための文章です。")
                files["OPS/\(name).xhtml"] = Data(html.utf8)
            }
        case .largeIllustrated:
            var manifest = "", spine = ""
            // Eight incompressible 1024×1024 RGBA images and 40 illustrated chapters.
            for i in 0..<8 {
                files["OPS/image\(i).png"] = try image(seed: UInt32(i + 1))
                manifest += "<item id='image\(i)' href='image\(i).png' media-type='image/png'/>"
            }
            for i in 0..<40 {
                let path = "illustration\(i).xhtml"
                files["OPS/\(path)"] = Data("""
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Illustration \(i)</title></head><body>
                <h1>Illustration \(i)</h1><img src="image\(i % 8).png" style="max-width:100%;max-height:70vh" alt="Synthetic noise"/>
                <p>Original synthetic illustration \(i).</p></body></html>
                """.utf8)
                manifest += "<item id='illustration\(i)' href='\(path)' media-type='application/xhtml+xml'/>"
                spine += "<itemref idref='illustration\(i)'/>"
            }
            opf = opf.replacingOccurrences(of: "</manifest>", with: manifest + "</manifest>")
                .replacingOccurrences(of: "<itemref idref=\"one\"/><itemref idref=\"two\"/>", with: spine)
        }
        files["OPS/book.opf"] = Data(opf.utf8)
        files["OPS/nav.xhtml"] = Data(nav.utf8)
        return try archive(files)
    }

    private static func image(seed: UInt32) throws -> Data {
        var state = seed
        var pixels = [UInt8](repeating: 255, count: 1024 * 1024 * 4)
        for i in pixels.indices where i % 4 != 3 {
            state = 1664525 &* state &+ 1013904223
            pixels[i] = UInt8(state >> 24)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: 1024, height: 1024, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
