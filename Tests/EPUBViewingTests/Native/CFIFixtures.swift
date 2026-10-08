import Foundation

/// Inputs shared by `CFIVectorGenerator`, which runs the vendored foliate-js on them in WebKit,
/// and `CFIGoldenVectorTests`, which runs the Swift port on the same bytes. Changing anything
/// here means regenerating `CFIGoldenVectors.swift`.
enum CFIFixtures {
    struct Document {
        let name: String
        let xhtml: String
        /// Quotes to locate, before the reader's quote normalization.
        var quotes: [String] = []
        /// Local CFIs to resolve besides the ones generated from ranges.
        var cfis: [String] = []
    }

    struct Package {
        let name: String
        let opf: String
        /// Full CFIs to resolve besides each spine item's base.
        var cfis: [String] = []
    }

    /// Local paths every document resolves: virtual indices, missing chunks, stale offsets, ID
    /// assertions that do and do not exist, ranges in and out of order, malformed input.
    static let commonCFIs = [
        "/0", "/1", "/2", "/3", "/4", "/5", "/6", "/99", "/4/0", "/4/1", "/4/1:0", "/4/1:5", "/4/2", "/4/2/0",
        "/4/2/1", "/4/2/1:0", "/4/2/1:3", "/4/2/1:9999", "/4/2/2", "/4/2/3", "/4/2/3:1", "/4/2/4", "/4/2/99",
        "/4/2/1/1", "/4/2/1:2/3", "/4/2:5", "/4/4/1:1", "/4/6/2/1:0", "/2/2/1:2", "/4/2[nonexistent]",
        "/4/2[nonexistent]/1:2", "/4/2/1:2[a,b;s=a]", "/4/2/1:1~2.5@3:4", "/4/2/1:5[;s=b]",
        "/4,/2/1:0,/4/1:2", "/4,/4/1:2,/2/1:0", "/4/2,/1:1,/1:4", "/4/2,,/1:4", "/4/2!/4/2", "", "!", ",", "/4/2,/1:0",
    ]

    static let documents: [Document] = [
        Document(name: "basic", xhtml: #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en">
            <head>
            <title>Basic</title>
            <link rel="stylesheet" type="text/css" href="style.css"/>
            </head>
            <body>
            <h1 id="title">A Title</h1>
            <p id="p1">First <em>emphasised</em> paragraph with <a href="#p2">a link</a>.</p>
            <p id="p2">Second paragraph, <span><b>nested <i>deeply</i></b> inline</span> text.</p>
            <blockquote><p>Quoted</p></blockquote>
            </body>
            </html>
            """#, quotes: ["First emphasised paragraph", "a link.", "nested deeply inline", "second PARAGRAPH",
                           "A Title First", "Quoted", "quoted\n\nnothing"],
            cfis: ["/4/2[title]", "/4/4[p1]/1:2", "/4/4[p1]", "/4/6[p2]/4/2/3:2", "/4/4[title]/1:3",
                   "/4/4[p1],/1:0,/3:3", "/4[nope]/4[p1]/2/1:1"]),
        Document(name: "chunks", xhtml: #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" lang="en">
            <head><title>Chunks</title></head>
            <body>
              <!-- a comment before the first element -->
              <div>   </div>
              <p>Split<!-- by a comment --> text<?pi data?> and a processing instruction.</p>
              <p><![CDATA[cdata at the start]]> then text <![CDATA[<not markup>]]> end</p>
              <p>Text then CDATA<![CDATA[]]><b>bold</b><i>italic</i></p>
              <p><!--only a comment--></p>
              <p>
                 multiple    spaces	and	tabs
              </p>
              <p><b>x</b><!-- between --><i>y</i>last<!-- trailing --></p>
              <p><!-- leading --><b>first</b>text<i>last</i><!-- trailing --></p>
            </body>
            </html>
            """#, quotes: ["Split text and a processing instruction.", "cdata at the start then text <not markup> end",
                           "multiple spaces and tabs", "CDATAbolditalic", "xylast", "Split  text"],
            cfis: ["/4/6/1:3", "/4/6/1:5", "/4/6/1:6", "/4/6/1:99", "/4/6/1", "/4/8/1:21", "/4/12/1", "/4/12/0", "/4/12/2",
                   "/4/16/5", "/4/16/1", "/4/18/1", "/4/18/5", "/4/18/0", "/4/18/6"]),
        Document(name: "entities", xhtml: #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
            <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="fr">
            <head><title>Entit&eacute;s</title></head>
            <body>
            <p>Caf&eacute;&nbsp;cr&egrave;me &mdash; &ldquo;quoted&rdquo; &amp; &lt;escaped&gt; &#x2019;&#8217; &copy;</p>
            <p>Non&#xA0;breaking&nbsp;&nbsp;spaces and &hellip; ellipsis</p>
            <p>Astral &#x1D49C; and emoji &#x1F600; text</p>
            </body>
            </html>
            """#, quotes: ["Café crème", "cafe creme — “quoted”", "& <escaped>", "Non breaking spaces",
                           "Astral 𝒜 and", "emoji 😀 text", "&nbsp;"],
            cfis: ["/4/2/1:4", "/4/6/1:8", "/4/6/1:9", "/4/6/1:10"]),
        Document(name: "html5-doctype", xhtml: #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" lang="en">
            <head><title>HTML5 doctype</title></head>
            <body>
            <p>Named&nbsp;entity with an HTML5 doctype.</p>
            <p>Second <b>paragraph</b>.</p>
            </body>
            </html>
            """#, quotes: ["Named entity", "second paragraph."]),
        Document(name: "namespaces", xhtml: #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xmlns:m="http://www.w3.org/1998/Math/MathML" xml:lang="en" lang="en">
            <head><title>Namespaces</title><style type="text/css">p { color: red }</style></head>
            <body epub:type="bodymatter">
            <section epub:type="chapter" id="ch1">
            <p>Before <a epub:type="noteref" href="#n1">1</a> the note.</p>
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 10 10"><title>Figure</title><text x="1" y="5">SVG text</text><style>.s { fill: red }</style><image xlink:href="a.png" width="10" height="10"/></svg>
            <p>Inline <math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi><mo>=</mo><mn>2</mn></math> and <m:math><m:mi>y</m:mi></m:math> prefixed.</p>
            <aside epub:type="footnote" id="n1"><p>The note text.</p></aside>
            <p xml:id="xmlid">Only an xml:id.</p>
            <script type="text/javascript">var hidden = "script text";</script>
            <p>After the script.</p>
            </section>
            </body>
            </html>
            """#, quotes: ["Before 1 the note.", "FigureSVG text", "x=2 and y prefixed", "the note text", "script text",
                           ".s { fill", "Only an xml:id. After the script.", "color: red"],
            cfis: ["/4/2[ch1]/4/2/1:1", "/4/2[ch1]/6/3:2", "/4/2[n1]", "/4/2/10[xmlid]", "/4/2[xmlid]",
                   "/4/2[ch1]/4/2[ch1]", "/4/2[n1]/1:2"]),
        Document(name: "deep", xhtml: #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" lang="en"><head><title>Deep</title></head><body>
            """# + (0..<24).map { "<div class=\"d\($0)\">level \($0) " }.joined() + "<span id=\"leaf\">leaf</span>"
            + String(repeating: " end</div>", count: 24) + "</body></html>",
            quotes: ["level 3 level 4", "leaf end end", "level 23 leaf"],
            cfis: ["/4/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/1:1",
                   "/4/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/1:0",
                   "/4/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2/2[leaf]/1:2", "/4/2/2/2/3:1"]),
        Document(name: "ids", xhtml: #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" lang="en">
            <head><title>IDs</title></head>
            <body>
            <p id="a[b]">Brackets</p>
            <p id="c^d">Caret</p>
            <p id="e,f;g=h">Comma semicolon equals</p>
            <p id="i(j)">Parens</p>
            <p id="第二章">Unicode id</p>
            <p id="dup">First duplicate</p>
            <p id="dup">Second duplicate</p>
            <p id="">Empty id</p>
            <div id="spaced id"><span id="inner">Inner</span></div>
            </body>
            </html>
            """#, quotes: ["Caret Comma", "duplicate", "Inner"],
            cfis: ["/4/2[a^[b^]]", "/4/99[a^[b^]]/1:2", "/4/4[c^^d]/1:1", "/4/6[e^,f^;g^=h]", "/4/8[i^(j^)]/1:3",
                   "/4/10[第二章]", "/4/14[dup]/1:3", "/4/12[dup]", "/4/18[spaced id]/2[inner]/1:2", "/4/18/2[inner]",
                   "/4/2[a[b]]", "/4/16[]/1:2"]),
        Document(name: "empty-adjacent", xhtml: #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" lang="en">
            <head><title>Empty and adjacent</title></head>
            <body>
            <p>Line one<br/>line two<br/><br/>after two breaks</p>
            <p><img src="a.png" alt="A"/><img src="b.png" alt="B"/></p>
            <p><span></span><span></span>text after empty spans</p>
            <hr/>
            <p><b>a</b><i>b</i><u>c</u></p>
            <div><p>first</p><p>second</p></div>
            <p/>
            </body>
            </html>
            """#, quotes: ["Line oneline two", "line twoafter", "abc", "firstsecond"],
            cfis: ["/4/2/4", "/4/2/4/0", "/4/2/4/1", "/4/2/5", "/4/2/6", "/4/2/7", "/4/2/8", "/4/2/9:2", "/4/4/1", "/4/4/3",
                   "/4/4/5", "/4/4/6", "/4/4/2/1", "/4/6/2", "/4/6/3", "/4/6/5:4", "/4/10/3", "/4/10/5", "/4/10/7",
                   "/4/10/8", "/4/14/0", "/4/14/1", "/4/14/2", "/4/14", "/4/12/2/1:2,/4/12/4/1:3", "/4,/10/2/1:0,/10/6/1:1"]),
        Document(name: "search", xhtml: #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" lang="en">
            <head><title>Search title text</title><style>.x { content: "style text" }</style></head>
            <body>
            <p>The Café serves café, CAFÉ and cafe&#x301; to everyone.</p>
            <p>Whitespace   runs
            	and tabs collapse into one.</p>
            <p>Zero&#xFEFF;width no&#xFEFF;break and soft&#xAD;hyphen&#xAD;ated words.</p>
            <p>A word split across <b>bold</b>face and <i>it</i><em>alic</em> elements.</p>
            <p>It’s “curly” — not 'straight' or "plain".</p>
            <p>Ligature ﬁne, fullwidth ＡＢＣ, kana カタカナ and ひらがな, Greek ΣΟΦΟΣ σοφος σοφοσ.</p>
            <p>Repeated aaaa overlapping.</p>
            <script>var s = "script text";</script>
            <p>Emoji ❤️ and ❤ heart, flag 🇫🇷, family 👨‍👩‍👧.</p>
            <p>Line<br/>break and end of text</p>
            <p>Stroke ø and o, æsir aesir, straße strasse, Ⅻ XII, ① 1, ٣ 3.</p>
            </body>
            </html>
            """#, quotes: [
                "café", "CAFE", "cafe", "The café serves", "whitespace runs and tabs", "Whitespace runs\n\tand",
                "zerowidth", "Zero width", "zero\u{FEFF}width", "softhyphenated", "soft-hyphen", "boldface", "italic",
                "split across bold", "it’s", "it's", "\"curly\"", "“curly”", "— not", "fine", "ﬁne", "abc", "ＡＢＣ",
                "かたかな", "カタカナ", "ひらがな", "σοφος", "ΣΟΦΟΣ", "σοφοσ", "aa", "a", "e", "script text", "style text",
                "search title", "❤", "❤️", "heart, flag 🇫🇷", "👨", "👨‍👩‍👧", "end of text", "linebreak", "line break",
                "nonexistent phrase", "everyone.", "e\u{301}", "é", "Stroke o", "ø and o", "aesir aesir", "æsir",
                "strasse strasse", "straße", "XII XII", "Ⅻ", "1 1", "① 1", "3 3", "٣ 3", "\u{301}", " ", "   ",
            ]),
        Document(name: "locales", xhtml: #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" lang="en">
            <head><title>Locales</title></head>
            <body lang="tr">
            <p>İstanbul ılık Istanbul istanbul.</p>
            <p xml:lang="sv">Smörgåsbord smorgasbord.</p>
            </body>
            </html>
            """#, quotes: ["istanbul", "Istanbul", "İstanbul", "ilik", "ılık", "smorgasbord", "Smörgåsbord"]),
        Document(name: "no-namespace", xhtml: #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <html>
            <head><title>No namespace</title></head>
            <body>
            <p>Plain <b>XML</b> without the XHTML namespace.</p>
            </body>
            </html>
            """#, quotes: ["plain xml", "No namespace"]),
        Document(name: "svg-root", xhtml: #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><title>Cover</title><text>Cover text</text></svg>
            """#, quotes: ["cover text"]),
    ]

    static let packages: [Package] = [
        Package(name: "standard", opf: #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">x</dc:identifier><dc:title>T</dc:title></metadata>
              <manifest>
                <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
                <item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>
                <item id="c3" href="c3.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="c1"/>
                <itemref idref="c2" linear="no"/>
                <itemref idref="c3"/>
              </spine>
            </package>
            """#, cfis: ["epubcfi(/6/4[c2]!/4/2/1:3)", "epubcfi(/6/2)", "epubcfi(/6/8)", "epubcfi(/6/1)", "epubcfi(/6/3)",
                         "epubcfi(/6/0)", "epubcfi(/6/9)", "epubcfi(/6/10)", "epubcfi(/4/2)", "epubcfi(/6/4/2)", "epubcfi(/6)",
                         "epubcfi(!/4/2)", "epubcfi(/6/6!/4/2,/1:0,/1:5)", "epubcfi(/6/6,/4/2/1:0,/4/2/1:5)",
                         "epubcfi(/6/4[c1]!/4)", "epubcfi(/2/2)", "not a cfi"]),
        Package(name: "spine-ids", opf: #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" id="pkg">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">x</dc:identifier></metadata>
              <manifest>
                <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine id="main-spine" toc="ncx">
                <itemref id="ir-cover" idref="cover"/>
                <itemref id="ir[1]" idref="ch1"/>
                <itemref idref="ch2" id="ir^2"/>
              </spine>
            </package>
            """#, cfis: ["epubcfi(/6[main-spine]/4[ch1]!/4/2/1:0)", "epubcfi(/6/4[ir-cover])", "epubcfi(/6[x]/6[ir-cover])",
                         "epubcfi(/6/4[uid])", "epubcfi(/6/6[ir^[1^]]!/4)", "epubcfi(/99[ir-cover])"]),
        Package(name: "unusual-order", opf: #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid"><!-- comment --><spine toc="ncx"><itemref idref="b"/><!-- between --><itemref idref="a"/><foo/><itemref idref="b"/></spine><guide><reference type="cover" href="a.xhtml"/></guide><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/><item id="b" href="b.xhtml" media-type="application/xhtml+xml"/></manifest><metadata/></package>
            """#, cfis: ["epubcfi(/2/1)", "epubcfi(/2/7)", "epubcfi(/2/8)", "epubcfi(/2/0)", "epubcfi(/2/9)",
                         "epubcfi(/2/3)"]),
        Package(name: "prefixed", opf: #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <opf:package xmlns:opf="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
              <opf:metadata/>
              <opf:manifest><opf:item id="x" href="x.xhtml" media-type="application/xhtml+xml"/></opf:manifest>
              <opf:spine><opf:itemref idref="x"/></opf:spine>
            </opf:package>
            """#),
        Package(name: "no-namespace", opf: #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <package version="2.0"><metadata/><manifest><item id="x" href="x.xhtml" media-type="application/xhtml+xml"/><item id="y" href="y.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="x"/>
            <itemref idref="y"/></spine></package>
            """#),
        Package(name: "foreign-children", opf: #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" xmlns:x="urn:x" version="3.0"><metadata/><manifest/><x:spine><itemref idref="wrong"/></x:spine><spine><x:itemref idref="foreign"/><itemref idref="real"/></spine></package>
            """#, cfis: ["epubcfi(/6/2)", "epubcfi(/8/2)", "epubcfi(/8/4)"]),
    ]

    /// Strings for parse → string round trips, `isCFI` and `collapse`.
    static let strings = [
        "epubcfi(/6/4!/4/10/2:3)", "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/3:10)",
        "epubcfi(/6/14[chap%2Dtwo]!/4/2/10)", "epubcfi(/6/4!/4,/2/2:0,/6/2:12)", "epubcfi(/6/14[note^(2^)]!/4/2/10)",
        "epubcfi(/6/4!/4/2/1:5[;s=a])", "epubcfi(/6/4!/4,/2/1:0[pre,post;s=b],/2/1:10)",
        "epubcfi(/6/14[a^[b^]c^,d^;e^=f]!/4/2/10)", "epubcfi(/6/14[a^^b]!/4/2/10)", "epubcfi(/6/14[第二章]!/4/2/10)",
        "epubcfi(/6/4!/4/2:3)", "epubcfi(/6/4!/4/3:0)", "epubcfi(/6/4!/4/3:00012)", "epubcfi(/6/004!/04/2)",
        "epubcfi(/6/4[id;s=a]!/4/2)", "epubcfi(/6/4[id][text]!/4/2)", "epubcfi(/6/4[][x]!/4/2)", "epubcfi(/6/4[]!/4/2)",
        "epubcfi(/6/4[a,b,c]!/4/2)", "epubcfi(/6/4!/4/2/1:3[x;foo=bar;s=c])", "epubcfi(/6/4!/4/2/1:3[x;s=c;s=d])",
        "epubcfi(/6/4!/4/2/1:3[x;s])", "epubcfi(/6/4!/4/2/1:3[x;s=])", "epubcfi(/6/4!/4/2/1:3[x;=y])",
        "epubcfi(/6/4!/4/2/1:3~2.5)", "epubcfi(/6/4!/4/2/1:3~0)", "epubcfi(/6/4!/4/2/1:3~.5)", "epubcfi(/6/4!/4/2/1:3~5.)",
        "epubcfi(/6/4!/4/2/1:3~1.2.3)", "epubcfi(/6/4!/4/2/1:3~.)", "epubcfi(/6/4!/4/2/1:3@10:20)",
        "epubcfi(/6/4!/4/2/1:3@10.5:20.25:30)", "epubcfi(/6/4!/4/2/1:3@:5)", "epubcfi(/6/4!/4/2/1:3~23.5@1:2[t])",
        "epubcfi(/6/4!/4/2/1:3~0.0000001)", "epubcfi(/6/4!/4/2/1:3~123456789012345678901234)",
        "epubcfi(/6/4!/4/2/1:3~100000000000000000000)", "epubcfi(/6/4!/4/2/1:3~0.000001)",
        "  epubcfi(/6/4!/4/2)  ", "epubcfi( /6/4!/4/2 )", "epubcfi(/6/4!/4/2\n)", "epubcfi(/6/4[a\u{2028}b]!/4/2)",
        "/6/4!/4/2", "epubcfi(/6/4!/4/2", "epubcfi(/6/4)!/4/2)", "epubcfi(/6/4)(x)", "epubcfi(/6/4)^)", "epubcfi()",
        "epubcfi(/6/4^/2)", "epubcfi(/6/4^^[x]!/2)", "epubcfi(/6/4^[;s=a]!/2)", "epubcfi(/6/4[x^]!/2)",
        "epubcfi(/6/4[x^\u{3000}y]!/2)", "epubcfi(/6/4[x!y]!/2)", "epubcfi(/6/4[x/y:z]!/2)", "epubcfi(/6/4[unterminated",
        "epubcfi(/a/4)", "epubcfi(/6/4!/4/2/)", "epubcfi(/6/4!/4/2/1:)", "epubcfi(/6/4!/4/2/1:x)", "epubcfi(:5)",
        "epubcfi([x])", "epubcfi(~5)", "epubcfi(@5)", "epubcfi([;s=a])", "epubcfi([;t=a])", "epubcfi(;s=a)",
        "epubcfi(/6/4!!/4/2)", "epubcfi(!/4/2)", "epubcfi(/6/4!/4/2!)", "epubcfi(,/2,/4)", "epubcfi(/6/4!/4,/2,/4,/6)",
        "epubcfi(/6/4!/4,/2)", "epubcfi(/6/4!/4,,)", "epubcfi(/6/4!/4/2,/1:0,/1:5)", "epubcfi(/6/4,/4/2/1:0,/4/2/1:5)",
        "epubcfi(/6/4!/4/2[p1;s=a]/1:0)", "epubcfi(/6/99999999999999999999)", "epubcfi(/6/4!/4/2/1:99999999999999999999)",
        "epubcfi(/6/4!/4/2/1:2147483648)", "epubcfi(/6/4!/4/2/1:9007199254740993)", "epubcfi(/-1/4)", "epubcfi(/6/4.5)",
        "epubcfi(/6/4!/4/2/1:5[  spaced  ])", "epubcfi(/6/4!/4/2/1:5[\u{FEFF}bom])", "\u{FEFF}epubcfi(/6/4)\u{FEFF}",
        "\u{A0}epubcfi(/6/4)", "epubcfi(/6/4[a]b[c])", "epubcfi(/6/4)x", "x", "", "epubcfi(/6/4!/4/2[x]:3)",
    ]

    /// Pairs for `compare` and `buildRange`.
    static let pairs: [(String, String)] = [
        ("epubcfi(/6/4!/4/2/1:3)", "epubcfi(/6/4!/4/2/1:5)"), ("epubcfi(/6/4!/4/2/1:5)", "epubcfi(/6/4!/4/2/1:3)"),
        ("epubcfi(/6/4!/4/2/1:3)", "epubcfi(/6/4!/4/2/1:3)"), ("epubcfi(/6/4!/4/2)", "epubcfi(/6/4!/4/2/1:0)"),
        ("epubcfi(/6/4!/4/2/1:0)", "epubcfi(/6/4!/4/2)"), ("epubcfi(/6/4!/4/2)", "epubcfi(/6/6!/4/2)"),
        ("epubcfi(/6/6)", "epubcfi(/6/4!/4/2)"), ("epubcfi(/6/4!/4/2:3)", "epubcfi(/6/4!/4/2:1)"),
        ("epubcfi(/6/4!/4/2/1:3)", "epubcfi(/6/4!/4/2/3)"), ("epubcfi(/6/4!/4/2,/1:0,/1:5)", "epubcfi(/6/4!/4/2,/1:0,/1:9)"),
        ("epubcfi(/6/4!/4/2,/1:0,/1:5)", "epubcfi(/6/4!/4/2/1:0)"), ("epubcfi(/6/4!/4/2/1:0)", "epubcfi(/6/4!/4/2,/1:0,/1:5)"),
        ("epubcfi(/6/4!/4/2,/1:2,/1:5)", "epubcfi(/6/4!/4,/2/1:2,/4/1:1)"), ("epubcfi(/6/4!/4/2/1:3~1)", "epubcfi(/6/4!/4/2/1:3~2)"),
        ("epubcfi(/6/4[a]!/4/2)", "epubcfi(/6/4[b]!/4/2)"), ("epubcfi(/6/4!/4/2/1)", "epubcfi(/6/4!/4/2/1:0)"),
        ("epubcfi(/6/4!/4/10/1:3)", "epubcfi(/6/4!/4/8/5/1:3)"), ("x", "epubcfi(/6/4)"), ("epubcfi(/6/4)", "x"), ("", ""),
        ("epubcfi(/6/4!/4/2/1:3)", "epubcfi(/6/4!/4/2/1:30)"), ("epubcfi(/6/4!/4/2/4/1:0)", "epubcfi(/6/4!/4/2/1:9)"),
        ("epubcfi(/6/4!/4/2/1:5)", "epubcfi(/6/4!/4/2/1:0[x;s=a])"), ("epubcfi(/6/4!/4,/2/1:0,/2/1:3)", "epubcfi(/6/4!/4/2/1:0)"),
    ]

    /// Characters whose base-strength equivalence classes the generator records, and the
    /// locales it records them for (`en` in full, the others only where several characters meet).
    static let collationRanges: [ClosedRange<UInt32>] = [
        0x21...0x7E, 0xA1...0x24F, 0x250...0x2FF, 0x370...0x3FF, 0x400...0x4FF, 0x5D0...0x5EA, 0x621...0x64A,
        0x660...0x669, 0x6F0...0x6F9, 0x905...0x939, 0x966...0x96F, 0x1E00...0x1EFF, 0x2010...0x205E,
        0x2070...0x209F, 0x20A0...0x20BF, 0x2100...0x218F, 0x2460...0x24FF, 0x3041...0x30FF, 0xFB00...0xFB06,
        0xFF01...0xFF5E, 0xFF61...0xFF9F,
    ]
    static let collationLocales = ["en", "sv", "tr", "da", "de", "ja"]
}
