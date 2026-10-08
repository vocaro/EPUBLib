import Foundation

/// The renderer's user-agent stylesheet: HTML's rendering defaults (HTML §15) for the CSS subset,
/// plus the reader's own defaults on `html`. Parsed once.
enum UserAgentStyleSheet {
    static let sheet = CSSStyleSheet.parse(text, path: "")

    static let text = """
    @namespace "http://www.w3.org/1999/xhtml";
    @namespace m "http://www.w3.org/1998/Math/MathML";
    @namespace svg "http://www.w3.org/2000/svg";

    html { display: block; font-family: serif; line-height: 1.4; hyphens: auto; }
    body { display: block; margin: 0; }

    [hidden], area, base, basefont, datalist, head, link, meta, noembed, noframes, param, rp,
    script, style, template, title, dialog:not([open]) { display: none; }

    address, blockquote, center, dialog, div, figure, figcaption, footer, form, header, hr, legend,
    listing, main, p, plaintext, pre, search, xmp, article, aside, h1, h2, h3, h4, h5, h6, hgroup,
    nav, section, details, summary, dir, dd, dl, dt, menu, ol, ul, fieldset, optgroup, frameset,
    frame, marquee { display: block; }
    li { display: list-item; }
    input, button, select, textarea, meter, progress { display: inline-block; }

    blockquote, figure, listing, p, plaintext, pre, xmp { margin-top: 1em; margin-bottom: 1em; }
    blockquote, figure { margin-left: 40px; margin-right: 40px; }
    figcaption { text-align: center; font-size: 0.9em; }
    address { font-style: italic; }
    center { text-align: center; }

    h1 { font-size: 2em; margin-top: 0.67em; margin-bottom: 0.67em; }
    h2 { font-size: 1.5em; margin-top: 0.83em; margin-bottom: 0.83em; }
    h3 { font-size: 1.17em; margin-top: 1em; margin-bottom: 1em; }
    h4 { margin-top: 1.33em; margin-bottom: 1.33em; }
    h5 { font-size: 0.83em; margin-top: 1.67em; margin-bottom: 1.67em; }
    h6 { font-size: 0.67em; margin-top: 2.33em; margin-bottom: 2.33em; }
    h1, h2, h3, h4, h5, h6 { font-weight: bold; break-after: avoid; }

    dir, dl, menu, ol, ul { margin-top: 1em; margin-bottom: 1em; }
    :is(dir, dl, menu, ol, ul) :is(dir, dl, menu, ol, ul) { margin-top: 0; margin-bottom: 0; }
    dd { margin-left: 40px; }
    dir, menu, ol, ul { padding-left: 2em; }
    ol { list-style-type: decimal; }
    dir, menu, ul { list-style-type: disc; }
    :is(dir, menu, ol, ul) :is(dir, menu, ul) { list-style-type: circle; }
    :is(dir, menu, ol, ul) :is(dir, menu, ol, ul) :is(dir, menu, ul) { list-style-type: square; }
    ol[type="1"], li[type="1"] { list-style-type: decimal; }
    ol[type=a s], li[type=a s] { list-style-type: lower-alpha; }
    ol[type=A s], li[type=A s] { list-style-type: upper-alpha; }
    ol[type=i s], li[type=i s] { list-style-type: lower-roman; }
    ol[type=I s], li[type=I s] { list-style-type: upper-roman; }
    ul[type=none i], li[type=none i] { list-style-type: none; }
    ul[type=disc i], li[type=disc i] { list-style-type: disc; }
    ul[type=circle i], li[type=circle i] { list-style-type: circle; }
    ul[type=square i], li[type=square i] { list-style-type: square; }

    pre, listing, plaintext, xmp { font-family: monospace; white-space: pre; }
    code, kbd, samp, tt { font-family: monospace; }
    cite, dfn, em, i, var { font-style: italic; }
    b, strong { font-weight: bolder; }
    big { font-size: larger; }
    small { font-size: smaller; }
    sub, sup { font-size: smaller; }
    sub { vertical-align: sub; }
    sup { vertical-align: super; }
    u, ins { text-decoration: underline; }
    s, strike, del { text-decoration: line-through; }
    mark { background-color: yellow; color: black; }
    nobr { white-space: nowrap; }
    :link { text-decoration: underline; }
    ruby { display: ruby; }
    rt { display: ruby-text; }

    hr { margin: 0.5em auto; border-style: inset; border-width: 1px; color: gray; }

    table { display: table; border-collapse: separate; border-spacing: 2px; text-indent: initial; }
    caption { display: table-caption; text-align: center; }
    colgroup { display: table-column-group; }
    col { display: table-column; }
    thead { display: table-header-group; vertical-align: middle; }
    tbody { display: table-row-group; vertical-align: middle; }
    tfoot { display: table-footer-group; vertical-align: middle; }
    tr { display: table-row; vertical-align: middle; }
    td, th { display: table-cell; padding: 1px; vertical-align: inherit; }
    th { font-weight: bold; text-align: center; }

    [dir="ltr" i] { direction: ltr; }
    [dir="rtl" i] { direction: rtl; }

    m|math { display: inline; }
    m|math[display="block"] { display: block; text-align: center; margin: 0.5em 0; }
    svg|svg { display: inline; }
    """
}
