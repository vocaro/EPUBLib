import Foundation

/// Real source bytes replayed through Foliate's loadDocument and epubcfi.js in WebKit.
enum HTMLCFIFixtures {
    struct Fixture {
        let name: String
        let markup: String
        let quote: String
        let compatible: Bool
    }

    static let fixtures: [Fixture] = [
        .init(name: "outside-body-whitespace", markup: "<html>\n  <head><title>Book</title></head>\n <body>\n<p>First passage.</p>\n<p>Second passage.</p>\n</body>\n  </html>", quote: "Second passage.", compatible: true),
        .init(name: "named-reference-without-dtd", markup: "<html xmlns='http://www.w3.org/1999/xhtml'>\n<head><title>Book</title></head>\n<body><p>First&nbsp;passage.</p><p>Second passage.</p></body>\n</html>", quote: "First passage.", compatible: true),
        .init(name: "explicit-list-and-inline", markup: "<html><head><title>Book</title></head><body><div><p>First <b>bold</b> passage.</p><ul><li><p>Second passage.</p></li></ul></div></body></html>", quote: "Second passage.", compatible: true),
        .init(name: "prefixed-semantic-attributes", markup: "<html xmlns:epub='http://www.idpf.org/2007/ops' xml:lang='fr'><head><title>Book</title></head><body epub:type='bodymatter'><section id='chapter' epub:type='chapter'><p>First passage.</p><p id='second'>Second passage.</p></section></body></html>", quote: "Second passage.", compatible: true),
        .init(name: "numeric-carriage-return-and-attribute-tab", markup: "<html><head><title>Book</title></head><body><p id='first&#9;id'>First&#13;passage.</p><p>Second passage.</p></body></html>", quote: "First\rpassage.", compatible: true),
        .init(name: "literal-attribute-tab", markup: "<html><head><title>Book</title></head><body><p id='first\tid'>First passage.</p><p>Second passage.</p></body></html>", quote: "Second passage.", compatible: false),
        .init(name: "literal-attribute-newline", markup: "<html><head><title>Book</title></head><body><p id='first\nid'>First passage.</p><p>Second passage.</p></body></html>", quote: "Second passage.", compatible: false),
        .init(name: "implicit-tbody", markup: "<html><head><title>Book</title></head><body><table><tr><td>First passage.</td><td>Second passage.</td></tr></table></body></html>", quote: "Second passage.", compatible: false),
        .init(name: "table-foster-parenting", markup: "<html><head><title>Book</title></head><body><table>Moved text.<tr><td>First passage.</td></tr></table><p>Second passage.</p></body></html>", quote: "Second passage.", compatible: false),
        .init(name: "self-closing-span", markup: "<html><head><title>Book</title></head><body><p><span/>First passage.</p><p id='second'>Second passage.</p></body></html>", quote: "Second passage.", compatible: false),
        .init(name: "html-cdata", markup: "<html><head><title>Book</title></head><body><p><![CDATA[Lost XML text.]]>First passage.</p><p>Second passage.</p></body></html>", quote: "Second passage.", compatible: false),
        .init(name: "formatting-adoption", markup: "<html><head><title>Book</title></head><body><p><b>First <i>passage.</b> remaining.</i></p><p id='second'>Second passage.</p></body></html>", quote: "Second passage.", compatible: false),
        .init(name: "implicit-head-and-body", markup: "<html><p>First passage.</p><p>Second passage.</p></html>", quote: "Second passage.", compatible: false),
        .init(name: "foreign-svg", markup: "<html><head><title>Book</title></head><body><svg><title>Figure</title><text>First passage.</text></svg><p>Second passage.</p></body></html>", quote: "Second passage.", compatible: false),
        .init(name: "pre-initial-newline", markup: "<html><head><title>Book</title></head><body><pre>\nFirst passage.</pre><p>Second passage.</p></body></html>", quote: "Second passage.", compatible: false),
        .init(name: "paragraph-containing-block", markup: "<html><head><title>Book</title></head><body><p>First<div>block</div>passage.</p><p>Second passage.</p><p>Third passage.</p><p>Wrong passage.</p></body></html>", quote: "Second passage.", compatible: false),
        .init(name: "closing-void-br", markup: "<html><head><title>Book</title></head><body><p>First<br></br>passage.</p><p>Second passage.</p></body></html>", quote: "Second passage.", compatible: false),
    ]
}
