// The prototype's own glue between foliate-js and the StudyWright host.
//
// This is deliberately not foliate-js's `reader.html` / `reader.js` demo shell. Three reasons,
// all of them requirements rather than taste:
//
//  1. The demo shell calls `makeBook(file)`, which dispatches on the file's magic bytes and
//     dynamically imports the MOBI, PDF, CBZ and FictionBook handlers. Handing `view.open()` an
//     already-constructed `EPUB` instead means those imports are never evaluated, which is what
//     lets the bundle exclude them — and pdf.js's ~10 MB vendor tree with them — without
//     patching anything upstream.
//  2. The loader below refuses to hand the renderer any script resource, strips the markup that
//     would reach the network without fetching content, and counts both so the host can disclose
//     them.
//  3. The host's chrome (Contents, Quiz, Ask, the position indicator) is native. This page
//     renders the document and reports position and selection; it draws no UI of its own.
//
// Nothing here parses EPUB, ZIP or CFI. Those are foliate-js's, at the pinned commit recorded in
// asset-manifest.json.

import './lib/view.js'
import { EPUB } from './lib/epub.js'
import {
    configure, ZipReader, BlobReader, TextWriter, BlobWriter,
} from './lib/vendor/zip.js'

const HOST = window.webkit?.messageHandlers?.studywrightReader
const MAXIMUM_SELECTION_LENGTH = 4096
const MAXIMUM_REASON_LENGTH = 512
// A resource the loader will not return bytes for, whatever the manifest claims it is. The
// media-type refusal below is the precise check; this is the one that also holds for the
// resources loaded before a listener can be attached.
const SCRIPT_EXTENSIONS = ['.js', '.mjs', '.cjs', '.jsx']

const post = message => { try { HOST?.postMessage(message) } catch { /* host is gone */ } }

// The book could not be opened. The host replaces the reader with this reason, so it is reserved
// for exactly that: anything the reader survives goes through `notice` instead.
const fail = reason => post({
    type: 'failed',
    reason: String(reason).slice(0, MAXIMUM_REASON_LENGTH),
})

// Something went wrong that the reader survives — a selection that would not resolve, a command
// that threw. Recorded by the host, not turned into a failed book.
const notice = detail => post({
    type: 'notice',
    detail: String(detail).slice(0, MAXIMUM_REASON_LENGTH),
})

// An uncaught exception or rejected promise anywhere in this page — including inside
// foliate-js's own pagination/rendering path — reaches the host as a `notice` rather than
// staying silent. Nothing else observes this: a real book's resources can all load
// successfully (no CSP violation, no refused navigation, no scheme-handler error) while a
// script exception still leaves the page blank, and that failure mode is otherwise invisible
// on the host side.
window.addEventListener('error', event => {
    const detail = event.error?.stack || event.message || String(event)
    notice(`script error: ${detail}`)
})
window.addEventListener('unhandledrejection', event => {
    const reason = event.reason
    const detail = reason?.stack || reason?.message || String(reason)
    notice(`unhandled rejection: ${detail}`)
})

let scriptResourcesRefused = 0
let remoteHintsRemoved = 0
let lateRemoteHints = 0

// `ready` is re-posted, not posted once. Sections load as the person reads, so a resource
// refused or a link removed in section nine happens long after the first message; reporting only
// the opening counts would disclose the first chapter's diminishment and hide the rest. The host
// treats `ready` as the current state rather than as an event, and this sends nothing when the
// counts have not moved.
let sectionCount = 0
let publishedCounts = null

const publishReadiness = () => {
    const counts = [
        sectionCount, scriptResourcesRefused, remoteHintsRemoved, lateRemoteHints,
    ].join('/')
    if (counts === publishedCounts) return
    publishedCounts = counts
    post({
        type: 'ready',
        sectionCount,
        scriptResourcesRefused,
        remoteHintsRemoved,
        lateRemoteHints,
    })
}

// MARK: - Markup that reaches the network without fetching anything
//
// Content-Security-Policy has no directive that governs `dns-prefetch` or `preconnect`. The
// policy closes every content fetch a book can attempt — images, fonts, stylesheets, media,
// `@import`, `fetch` — and refuses none of these, which resolve a hostname and open a socket
// without fetching content. A `<meta http-equiv>` in the host page does not govern a section's
// `blob:` document either, so there is no policy layer downstream of this one: if these are not
// removed from the source before the renderer parses it, they are not removed at all.
//
// Which zip members are markup, decided by the member's own name. See `makeZipLoader`: the
// media type is not available on every path a resource arrives by, and a filter conditioned on
// one that is missing is a filter that never runs.
const MARKUP_EXTENSIONS = ['.xhtml', '.html', '.htm', '.xml', '.svg']

// BEGIN hint-filter
//
// Everything from the line above to `END hint-filter` is also evaluated on its own, under
// WebKit's parsers, by `ReaderEPUBHintFilterTests`. It may therefore use nothing declared
// outside it, and it does not touch the disclosed counts: `filterMarkup` below does the counting.
const PRECONNECTING_RELS = new Set([
    'dns-prefetch', 'preconnect', 'prefetch', 'prerender', 'preload', 'modulepreload',
])
// The two readings a section's text can be given. Which one the renderer uses is foliate-js's
// decision, made from a media type this loader is not handed, so the filter answers for both.
const MARKUP_READINGS = ['application/xhtml+xml', 'text/html']

const isPreconnecting = link =>
    (link.getAttribute('rel') ?? '').split(/\s+/)
        .some(rel => PRECONNECTING_RELS.has(rel.toLowerCase()))

// A type selector matches by local name in any namespace, so this also finds the namespace-
// prefixed spelling `<x:link xmlns:x="http://www.w3.org/1999/xhtml" …>`, which WebKit honours
// as an ordinary link element in an XHTML document.
const preconnectingLinksIn = doc =>
    [...doc.querySelectorAll('link[rel]')].filter(isPreconnecting)

// What a section becomes when no rewrite of it is free of hints under both readings. Withholding
// is the one outcome that cannot reach the network, and saying so inside the section puts the
// explanation where the missing text would have been. It is well-formed XHTML and ordinary
// HTML, so it reads the same whichever parser it is handed to.
const WITHHELD_SECTION =
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Section not shown</title></head>'
    + '<body><p>This section was not shown. It asks the reader to connect to a server, and the '
    + 'reader could not remove that request safely.</p></body></html>'

// The markup to hand the renderer, and how many hints were taken out of it.
//
// Every markup member is parsed. There is no textual pre-test: an internal DTD entity —
// `<!ENTITY h "&#60;l&#105;nk rel='preconnect' …/>">`, used as `&h;` — puts a link element in
// the XHTML reading without the word `link` appearing anywhere in the text, and no regular
// expression over the source sees what the XML parser will expand. That costs two parses per
// markup member. It costs no fidelity, because a member in which neither reading finds a hint
// is still returned as its original text.
//
// Both readings are searched because they can disagree about the same text: a CDATA section is
// character data to the XML parser and, to the HTML parser, a bogus comment that ends at the
// first `>`, so a link can exist in one reading and not the other. A hint in either counts.
//
// `parsererror` decides only which reading is serialised, and it is looked for only in the
// XHTML reading, which is the only one that can fail. It never decides *whether* to filter. A
// book can carry its own `<parsererror>`, literally or through an entity, and the HTML parser
// has no fatal errors, so on that reading the element can only be the book's; skipping any
// reading that contained one is how `<parsererror/>` beside `<link rel="preconnect">` used to
// come back unfiltered.
//
// The rewrite is then parsed again under both readings, and one that still carries a hint under
// either is not returned: the section is withheld instead. That is what makes choosing the wrong
// reading to serialise safe. The check is one parse deep. foliate-js parses and re-serialises a
// section once more before the section document exists, and `auditLoadedDocument` is what
// watches that step.
const withoutPreconnectingLinks = text => {
    const parse = (markup, type) => new DOMParser().parseFromString(markup, type)
    const [xhtml, html] = MARKUP_READINGS.map(type => parse(text, type))
    const found = Math.max(preconnectingLinksIn(xhtml).length, preconnectingLinksIn(html).length)
    if (found === 0) return { text, removed: 0 }
    const doc = xhtml.querySelector('parsererror') === null ? xhtml : html
    for (const hint of preconnectingLinksIn(doc)) hint.remove()
    const rewritten = new XMLSerializer().serializeToString(doc)
    const isClean = MARKUP_READINGS.every(type =>
        preconnectingLinksIn(parse(rewritten, type)).length === 0)
    return { text: isClean ? rewritten : WITHHELD_SECTION, removed: found }
}
// END hint-filter

// The filter above, with its removals counted into the disclosure.
const filterMarkup = text => {
    const { text: filtered, removed } = withoutPreconnectingLinks(text)
    remoteHintsRemoved += removed
    return filtered
}

// A detector, not a control. By the time a section document exists, a preconnecting link inside
// it has already had its chance, so removing it here changes nothing about this load. A non-zero
// count means the filter above does not cover the path this document arrived by — a finding
// about this prototype rather than about the book — and it is reported so that gap cannot pass
// unnoticed as a green boot.
const auditLoadedDocument = doc => {
    const late = [...doc.querySelectorAll('link[rel]')].filter(isPreconnecting)
    for (const link of late) link.remove()
    lateRemoteHints += late.length
}

// MARK: - Loading the book

// The upstream zip loader's shape (`{ entries, loadText, loadBlob, getSize }`), with two
// additions: a member whose name is a script is not readable through it at all, and markup is
// filtered on the way out.
const makeZipLoader = async blob => {
    configure({ useWebWorkers: false })
    const reader = new ZipReader(new BlobReader(blob))
    const entries = await reader.getEntries()
    const map = new Map(entries.map(entry => [entry.filename, entry]))
    const hasExtension = (name, extensions) =>
        extensions.some(extension => name.toLowerCase().endsWith(extension))
    const isScriptName = name => hasExtension(name, SCRIPT_EXTENSIONS)
    // The member's name is passed to `f` as well as its entry, because both filters below decide
    // what to do from the name rather than from an argument the caller may not supply.
    const load = f => (name, ...args) => {
        // The adapter keeps URL references encoded until this exact archive lookup.
        try { name = decodeURIComponent(name) } catch { return null }
        if (isScriptName(name)) {
            scriptResourcesRefused += 1
            return null
        }
        return map.has(name) ? f(map.get(name), name, ...args) : null
    }
    return {
        entries,
        loadText: load(async entry => filterMarkup(await entry.getData(new TextWriter()))),
        // Both halves are filtered because which one a section arrives through is foliate-js's
        // choice, not this file's. Non-markup resources are handed back as the very blob the
        // unzip produced, and a markup blob with nothing to remove is too.
        //
        // Markup is recognised by the member's filename, not by a media type. `epub.js` calls
        // `loadBlob(href)` with one argument on every path — `loadItem` and the `init` wrapper
        // both — so a `type` parameter here is always `undefined`, `new BlobWriter(undefined)`
        // produces a blob whose `type` is the empty string, and a filter conditioned on either
        // one could never fire. The filename is information this wrapper actually has, and it
        // also covers the case that puts markup on this path at all: a section whose manifest
        // media-type is wrong or unknown, which `shouldReplace` then does not route to
        // `loadReplaced`.
        loadBlob: load(async (entry, name, type) => {
            const blob = await entry.getData(new BlobWriter(type))
            if (!hasExtension(name, MARKUP_EXTENSIONS)) return blob
            const text = await blob.text()
            const filtered = filterMarkup(text)
            return filtered === text ? blob : new Blob([filtered], { type: blob.type })
        }),
        getSize: name => {
            try { return map.get(decodeURIComponent(name))?.uncompressedSize ?? 0 }
            catch { return 0 }
        },
    }
}

const openBook = async () => {
    // `connect-src 'self'` is the only fetch this page makes, and the scheme handler answers it
    // with the one file the host opened the reader on.
    const response = await fetch('book.epub')
    if (!response.ok) throw new Error(`book unavailable (${response.status})`)
    const book = await new EPUB(await makeZipLoader(await response.blob())).init()
    // foliate-js's own refusal seam: the loader dispatches `load` for each manifest item with
    // `isScript` and a writable `allow`, and awaits `allow` before returning the item. Setting
    // it false is the supported way to decline a resource; the extension check above covers the
    // window before `init()` publishes this target.
    book.transformTarget?.addEventListener('load', event => {
        if (event.detail?.isScript) {
            event.detail.allow = false
            scriptResourcesRefused += 1
        }
    })
    return book
}

// MARK: - Selection

const sectionIndexByDocument = new WeakMap()
// The fallback for a range whose document never came through a `load` event. Every document that
// did has its own entry above, which is what keeps this from being wrong on a fixed-layout spread
// where two documents are live at once.
let lastLoadedIndex = 0

const documentOf = range => {
    const node = range?.startContainer ?? range?.commonAncestorContainer
    return node?.ownerDocument ?? node ?? null
}

const reportSelection = (view, doc) => {
    try {
        const selection = doc.getSelection()
        if (!selection || selection.isCollapsed || selection.rangeCount === 0) {
            return post({ type: 'selection-cleared' })
        }
        const range = selection.getRangeAt(0)
        const text = selection.toString().slice(0, MAXIMUM_SELECTION_LENGTH)
        if (!text.trim()) return post({ type: 'selection-cleared' })
        const index = sectionIndexByDocument.get(doc) ?? lastLoadedIndex
        post({ type: 'selected', cfi: view.getCFI(index, range), text })
    } catch (error) {
        // `getCFI` throws on a range whose document is going away. Without this the message is
        // simply lost, which is indistinguishable from "nothing was selected".
        notice(error)
    }
}

// A listener and a debounce timer per live section document, torn down per document.
//
// Not one listener globally. The reflowable paginator does keep a single document on screen, but
// the bundled fixed-layout renderer draws a spread as *two* live documents and fires `load` for
// each, so "attach to the next, detach the previous" would silently stop reporting selections
// from the left-hand page of every spread. Fixed layout is on this lane's unverified list; the
// premise it would break is not worth encoding either way.
//
// Both halves of the teardown still matter per document: a debounce timer left running fires
// against a document the reader has already left and posts `selection-cleared` over a selection
// just made elsewhere, and a listener left attached stacks a second copy every time the same
// section is re-loaded.
const MAXIMUM_LIVE_DOCUMENTS = 8
const attachedDocuments = new Map()

const detachDocument = doc => {
    const detach = attachedDocuments.get(doc)
    if (!detach) return
    attachedDocuments.delete(doc)
    detach()
}

const attachSelection = (view, doc, index) => {
    detachDocument(doc)
    // A document whose frame is gone cannot produce another selection, and its pending timer
    // would report against a section the reader has left. `defaultView` is null once the iframe
    // holding it is detached, which is the liveness signal available here.
    for (const [other] of attachedDocuments) {
        if (other.defaultView === null) detachDocument(other)
    }
    // …and a bound, so a renderer that never detaches its frames cannot accumulate listeners
    // for a whole book. Insertion order makes the oldest document the one to go.
    while (attachedDocuments.size >= MAXIMUM_LIVE_DOCUMENTS) {
        detachDocument(attachedDocuments.keys().next().value)
    }
    sectionIndexByDocument.set(doc, index)
    lastLoadedIndex = index
    let pending = null
    const schedule = () => {
        if (pending !== null) clearTimeout(pending)
        // Selection fires continuously while a drag or a caret adjustment is in progress.
        // Reporting the settled selection keeps one gesture to one message.
        pending = setTimeout(() => { pending = null; reportSelection(view, doc) }, 150)
    }
    doc.addEventListener('selectionchange', schedule)
    attachedDocuments.set(doc, () => {
        if (pending !== null) clearTimeout(pending)
        pending = null
        doc.removeEventListener('selectionchange', schedule)
    })
}

// MARK: - Search

// foliate-js's search is an async generator over the whole book, and draining it is not a no-op:
// `View.search` calls `addAnnotation` for each result, so the overlay highlights every match as
// the generator advances. Highlighting is the visible effect of this call and the reason it is
// worth making. The results themselves are not listed here — in-document search results belong
// in the shell's Contents pane, which reads the library's own full-text index, and a second
// result list would prejudge which of the two owns in-document search.
//
// `search(opts)` reads `query` and `index` and spreads the rest into its matcher. Omitting
// `index` is what makes the search whole-book; there is no `scope` option.
const runSearch = async (view, query) => {
    view.clearSearch()
    for await (const _result of view.search({ query })) { /* highlighted, not listed */ }
}

// MARK: - Citation navigation

// A chunk's retained text can carry a character the vendored matcher's own corpus-side
// normalization discards outright. `search.js`'s `segmenterSearch` walks the *live* document a
// grapheme at a time and, before it ever reaches its whitespace handling, drops any grapheme
// composed entirely of Unicode Format-category (`\p{Format}`) code points — "ignore formatting
// characters" (`!/[^\p{Format}]/u.test(segment)` → `continue`) — which is not a collapse to a
// space but a removal: that grapheme contributes *nothing* to the corpus string the query is
// compared against. U+FEFF ZERO WIDTH NO-BREAK SPACE is Format-category, and Standard Ebooks'
// own typesetting places it directly between a word and a following em dash, invisibly, so the
// dash never opens a line on its own — measured directly against a real title, every one of its
// chapter files carried dozens. `ArchiveDocumentExtractor.extractEPUB` never touches it (it is
// neither `[ \t]` nor `\n`, the only characters whitespace normalization collapses), so it
// survives verbatim into a chunk's own text and into the quote this file is handed. Comparing
// that quote character for character against a corpus the matcher has already *removed* the
// same character from then disagrees at every one of those positions — an extra character in
// the quote, not merely a differently-spelled one — and because `view.search` requires its
// *whole* query to match one contiguous window, one disagreement anywhere in the quote fails the
// entire search. At that density, essentially no citation or quiz passage resolving into a chunk
// carrying the word joiner could ever be found (`ReaderEPUBLocateChapterRegressionTests`). Soft
// hyphen (U+00AD) is Format-category too, for the same reason typography inserts it invisibly.
// Stripping every Format-category grapheme here, then collapsing ordinary whitespace runs to a
// single space, mirrors exactly what the matcher already does to the side it walks live — not a
// new rule invented for this file. It does not by itself fix every reported symptom: a
// Contents row always resolves through a section's *first* chunk
// (`ReaderContentsPresentation.outline`'s de-duplication), and `ArchiveDocumentExtractor
// .extractEPUB`'s whole-document text walk (`XMLTextHarvester.strippingTags`) separately leaks
// a chapter's own `<head><title>` text into that first chunk as an unrelated leading fragment —
// a `Sources/StudyWright` defect out of this file's reach, tracked separately.
const normalizeLocateWhitespace = quote =>
    quote.replace(/\p{Format}/gu, '').replace(/\s+/g, ' ').trim()

// The host does not know a chunk's CFI — the prepared-title pack carries only a spine unit
// index, `ArchiveDocumentExtractor.extractEPUB` can skip a spine item that index would then no
// longer line up with, and no CFI is stored anywhere in the index. What it does know is the
// chunk's own text, so a citation is resolved by finding that text in the live book rather than
// by trusting an index. `view.search` is foliate-js's own book-wide matcher (`search.js`): it
// yields `{ index, subitems }` batches as each section is scanned, one `subitems` entry per
// match with the CFI already computed. The first match found — the first place the quoted text
// occurs in reading order — is where the citation goes.
//
// **`highlight` decides `select` vs. `goTo`, and both are followed by `clearSearch`.**
// `view.search` is not a silent lookup: `View.search` calls `addAnnotation` for every subitem it
// yields, on the way, which draws foliate-js's own `Overlayer.outline` (a red rectangle per
// visible line — `range.getClientRects()` returns one per line of a multi-line match) for every
// match it passed on the way to the one this file actually wants. Breaking out of the generator
// on the first hit — the `return` below — never runs `view.search`'s own generator body again, so
// nothing it already drew is ever removed by that call; only a fresh `view.clearSearch()` removes
// it, which is why one runs in `finally` on every exit from this function, found or not. Without
// it, a Contents jump or a citation landing leaves the book marked up with every outline `search`
// drew while scanning toward the match — the red boxes the owner reported after a Contents tap.
// `view.select` and `view.clearSearch()` are orthogonal (a native DOM `Selection`, not an overlay
// annotation), so clearing the search overlay immediately after selecting never touches the
// selection highlight itself.
//
// A Contents (TOC) row carries no quote of its own (`ReaderContentsPresentation.outline` builds
// its target with `quote: nil`) and resolves only through a chunk's retained text as a fallback
// locator (`ReaderDocumentRendering.epubLocateQuote`) — a less certain, unconfirmed-by-the-person
// position, so `reader-shell.md` calls for landing there with no persistent highlight at all:
// `view.goTo(cfi)` (`reason: 'navigation'`) places only a collapsed, invisible caret. A citation,
// a graded quiz passage, or a Contents *search* hit all carry an exact quote the person is being
// shown on purpose, so `highlight` is true there: `view.select(cfi)` (`reason: 'selection'`)
// selects the whole matched range — a native, theme-aware highlight using the browser's own
// selection styling, already the mechanism `reader-shell.md`'s "highlights it" describes for a
// citation — which clears itself the moment the person selects something else or navigates again.
const locate = async (view, quote, highlight) => {
    try {
        for await (const result of view.search({ query: normalizeLocateWhitespace(quote) })) {
            const cfi = result?.subitems?.[0]?.cfi ?? result?.cfi
            if (cfi) {
                if (highlight) await view.select(cfi)
                else await view.goTo(cfi)
                return
            }
        }
        notice('the cited passage could not be found in this book')
    } finally {
        view.clearSearch()
    }
}

// MARK: - Typography

// The host's own seam for Dynamic Type and light/dark appearance. `view.renderer` is foliate-js's
// live renderer — `<foliate-paginator>` for a reflowable book, `<foliate-fxl>` for a fixed-layout
// one — and only the paginator exposes `setStyles`, so a fixed-layout book (author-specified
// typography, the same reason a PDF page does not resize for Dynamic Type either) is left alone
// by the `?.` rather than by a branch here. `Paginator.setStyles` re-injects the given CSS into
// every section's own `<style>` element as it loads — including whichever section is on screen
// right now — so this reaches the whole book, not only chapters turned to after the call.
const setStyle = (view, css) => { view.renderer?.setStyles?.(css) }

// MARK: - Reading flow (page turns / continuous scroll)
//
// `flow` is `<foliate-paginator>`'s own observed attribute (`paginator.js`'s
// `static observedAttributes`); setting it runs the element's own `attributeChangedCallback`,
// which re-renders the current section under the new layout (columnized vs. `overflow: auto`
// scrolling) without this file touching its shadow DOM. `view.renderer` is a fixed-layout book's
// `<foliate-fxl>` for a book that renders one, and that element does not declare `flow` as an
// observed attribute at all, so the same call is a harmless no-op there rather than a branch this
// file has to carry — the setting simply does not apply to a fixed-layout book, matching
// `doc/architecture.md`'s existing "left alone by the `?.`" pattern for `setStyle` above.
const setFlow = (view, flow) => {
    view.renderer?.setAttribute?.('flow', flow)
    updateEdgeFades()
}

// MARK: - Continuous-scroll edge fade
//
// The native `.soft` `UIScrollView` edge effect (`ReaderEPUBWebView.applyAppearance`) fades
// content against the web view's *own* scroll view, and `doc/architecture.md` already records
// why that is inert for the default paginated flow: a page never overflows the web view's
// bounds, so there is nothing for the native effect to fade against. Continuous-scroll flow does
// have overflow — but not where the native effect can reach it. `flow="scrolled"` makes
// `#container` the thing that scrolls, and `#container` lives inside `<foliate-paginator>`'s own
// shadow root, opened with `{ mode: 'closed' }` (`paginator.js`). A closed shadow root has no
// `element.shadowRoot` accessor from outside it — not from this file, not from Swift — so the
// host can never hand that div's `UIScrollView`-backed scrolling to `webView.scrollView`, and
// making the paginator scroll natively at all would mean rewriting `#container`'s own layout
// inside `paginator.js`, which is vendored and pinned byte-identical
// (`ReaderEPUBAssets.swift`, `pipeline/studywright_pipeline/verify_vendored_assets.py`). Wiring
// the WKWebView's own scroll view to be the scroller for this content is therefore not reachable
// from bootstrap.js or Swift alone, whatever contentInset is tried.
//
// What *is* reachable: the paginator re-dispatches a plain, synchronous `scroll` `Event` on
// itself for every native scroll tick of `#container` (`this.#container.addEventListener(
// 'scroll', () => this.dispatchEvent(new Event('scroll')))`), and `start`, `size` and `viewSize`
// are public getters on the same element (`view.renderer`, already used by `setStyle` above).
// Neither of those requires reaching into the shadow root. So the fade below is a CSS gradient
// drawn in *this* page — two fixed divs outside the paginator's shadow tree, styled in
// `index.html` — kept in sync with scroll position through that public surface. It is a drawn
// approximation, not the system effect, and differs from it in one way worth naming: it resets to
// invisible at the top of every new section, because the closed shadow root gives this file only
// the current section's scroll position, never a whole-book one to fade a section boundary
// against — where a real UIScrollView-backed fade over one continuous document would not reset
// there at all.
let edgeFadeTop = null
let edgeFadeBottom = null
/// The paginator element the fade is currently listening to. Reflowable `<foliate-paginator>` is
/// one persistent element for a book's whole session — only the section inside it swaps — so this
/// is set at most once per book; a fixed-layout book's `<foliate-fxl>` never reaches this file's
/// `scrolled` check as true and is left alone, the same way `setFlow` leaves it alone.
let edgeFadeRenderer = null

/// How many pixels of scroll the fade takes to reach full strength — a short ramp so it reads as
/// a fade-in rather than a hard cut, closer to the native soft edge effect's own brief transition
/// than a binary show/hide would be.
const EDGE_FADE_RAMP_PX = 24

/// The fade stands in for floating iOS chrome over the page. The Mac host keeps every control in
/// the window toolbar, so there the strips would only dim text. `ReaderEPUBWebView` marks the
/// page with this class on macOS before this file runs.
const edgeFadeDisabled = () => document.documentElement.classList.contains('sw-macos')

const createEdgeFadesIfNeeded = () => {
    if (edgeFadeTop || edgeFadeDisabled()) return
    edgeFadeTop = document.createElement('div')
    edgeFadeTop.className = 'sw-edge-fade'
    edgeFadeTop.dataset.edge = 'top'
    edgeFadeBottom = document.createElement('div')
    edgeFadeBottom.className = 'sw-edge-fade'
    edgeFadeBottom.dataset.edge = 'bottom'
    document.body.append(edgeFadeTop, edgeFadeBottom)
}

const updateEdgeFades = () => {
    if (!edgeFadeTop || !edgeFadeBottom) return
    const renderer = edgeFadeRenderer
    if (!renderer || !renderer.scrolled) {
        edgeFadeTop.style.opacity = '0'
        edgeFadeBottom.style.opacity = '0'
        return
    }
    const clamp01 = value => Math.max(0, Math.min(1, value))
    const { start, size, viewSize } = renderer
    edgeFadeTop.style.opacity = String(clamp01(start / EDGE_FADE_RAMP_PX))
    edgeFadeBottom.style.opacity = String(clamp01((viewSize - (start + size)) / EDGE_FADE_RAMP_PX))
}

/// Called on every `load` (a section became current) so a fresh renderer is picked up once, and
/// so a section swap — which resets `#container`'s scroll offset — re-evaluates the fade
/// immediately rather than showing the previous section's stale strength for one frame.
const attachEdgeFadeListenerIfNeeded = view => {
    const renderer = view.renderer
    if (!renderer || renderer === edgeFadeRenderer
        || typeof renderer.addEventListener !== 'function') return
    edgeFadeRenderer = renderer
    createEdgeFadesIfNeeded()
    renderer.addEventListener('scroll', updateEdgeFades)
    updateEdgeFades()
}

// MARK: - Page-turn input: wheel and touch boundary push
//
// The owner's standing rule is to spend as little custom code as this reader can get away with
// and prefer a standard, platform-provided mechanism wherever one reaches the same result — the
// tap/click edge zones and the Mac keyboard bindings are consequently *not* in this file: they
// are a native SwiftUI tap gesture and `.onKeyPress` (`ReaderEPUBPrototypeSurface`,
// `ReaderEPUBWebView.swift`), which cost this page nothing at all. What is left here is only the
// input this page is the *sole* place able to observe: nothing in `paginator.js` binds wheel
// input at all, and its own touch handling (`#onTouchMove`) explicitly does nothing in
// continuous-scroll flow (`if (this.scrolled || state.pinched) return`) — scrolling there is
// native `#container` scrolling, entirely inside a closed shadow root
// (`doc/architecture.md`'s "Continuous-scroll edge fade" section), so no Swift-side gesture
// recognizer or scroll-view delegate can ever see it, and it stops dead at a section's own start
// or end with nothing to swap in more. `view.next()`/`view.prev()` — foliate-js's own public
// "turn a page, or, once already at this section's end/start, advance to the next/previous
// section" call (`Paginator.#turnPage`/`#scrollNext`/`#scrollPrev`) — is what both handlers below
// call once they notice the person pushing past that edge; this file supplies only the trigger.
//
// Attached per section document (`doc`, from the `load` event `attachSelection` and
// `attachEdgeFadeListenerIfNeeded` already key off): a section renders in its own iframe, and
// wheel/touch input over its content reaches that document directly, which is also why nothing
// here needs the coordinate math a host-level overlay would.
const BOUNDARY_EPS_PX = 2
const WHEEL_DELTA_THRESHOLD = 4
const TOUCH_PUSH_THRESHOLD_PX = 32
const PAGE_TURN_COOLDOWN_MS = 450

let lastPageTurnAt = 0
let pageTurnPending = false

/// Whether the renderer is currently pinned at its own start, its own end, or (a section short
/// enough to render entirely within the viewport) both at once — checked independently rather
/// than as a single either/or edge, so a one-screen section still advances correctly in whichever
/// direction the person pushes.
const rendererBoundary = renderer => {
    const { start, size, viewSize } = renderer
    if (!(viewSize > 0)) return { atStart: false, atEnd: false }
    return {
        atStart: start <= BOUNDARY_EPS_PX,
        atEnd: start + size >= viewSize - BOUNDARY_EPS_PX,
    }
}

/// `view.next()`/`view.prev()`, cooldown-guarded so one flick, one continued touch drag, or one
/// section's worth of accumulated wheel ticks turns at most one page/section — never several —
/// and so a call already in flight is never overlapped by another.
const turnPageDebounced = (view, forward) => {
    if (pageTurnPending) return
    const now = Date.now()
    if (now - lastPageTurnAt < PAGE_TURN_COOLDOWN_MS) return
    pageTurnPending = true
    lastPageTurnAt = now
    const advance = forward ? view.next() : view.prev()
    advance.catch(notice).finally(() => { pageTurnPending = false })
}

/// Mac trackpad and mouse wheel. In paginated flow a wheel tick turns a page outright — the same
/// call a tap zone or the `nextPage`/`previousPage` command makes. In scrolled flow a wheel tick
/// only crosses a section boundary, and only while the renderer is already pinned at the edge the
/// tick pushes toward: every other tick is the renderer's own native within-section scrolling,
/// which this file leaves entirely alone.
const attachWheelPageTurnListenerIfNeeded = (view, doc) => {
    doc.addEventListener('wheel', event => {
        const renderer = view.renderer
        if (!renderer) return
        const delta = Math.abs(event.deltaX) > Math.abs(event.deltaY) ? event.deltaX : event.deltaY
        if (Math.abs(delta) < WHEEL_DELTA_THRESHOLD) return
        const forward = delta > 0
        if (!renderer.scrolled) { turnPageDebounced(view, forward); return }
        const { atStart, atEnd } = rendererBoundary(renderer)
        if ((forward && atEnd) || (!forward && atStart)) turnPageDebounced(view, forward)
    }, { passive: true })
}

/// iOS swipe, scrolled flow only — paginated flow's own swipe-to-turn already works through
/// `paginator.js`'s native touch handling. A touch drag toward an edge the renderer is already
/// pinned at is the person pushing past the end of what native scrolling has to show, the same
/// signal the wheel handler above reads from a continued tick.
///
/// The drag is judged by its whole travel, from `touchstart` to the latest position, on every
/// `touchmove` and once more at `touchend` (from `changedTouches`): WebKit can deliver only one
/// or two `touchmove` events for a quick swipe before the touch ends, so a check on the moves
/// alone misses a swipe whose travel is only visible at its end.
const attachTouchBoundaryListener = (view, target) => {
    let startY = null
    const push = y => {
        const renderer = view.renderer
        if (!renderer?.scrolled || startY === null || typeof y !== 'number') return
        // Positive: the finger has moved up, dragging content upward — a forward/"next" scroll.
        const dy = startY - y
        const { atStart, atEnd } = rendererBoundary(renderer)
        if (dy > TOUCH_PUSH_THRESHOLD_PX && atEnd) turnPageDebounced(view, true)
        else if (dy < -TOUCH_PUSH_THRESHOLD_PX && atStart) turnPageDebounced(view, false)
    }
    target.addEventListener('touchstart', event => {
        startY = event.touches[0]?.clientY ?? null
    }, { passive: true })
    target.addEventListener('touchmove', event => push(event.touches[0]?.clientY), { passive: true })
    target.addEventListener('touchend', event => {
        push(event.changedTouches[0]?.clientY)
        startY = null
    }, { passive: true })
    target.addEventListener('touchcancel', () => { startY = null }, { passive: true })
}

/// Per section document: a touch over the section's own content reaches only its iframe.
const attachTouchBoundaryListenerIfNeeded = (view, doc) => attachTouchBoundaryListener(view, doc)

// MARK: - Wiring

const main = async () => {
    const view = document.createElement('foliate-view')
    document.body.append(view)
    // A section shorter than the viewport leaves page around its iframe in scrolled flow, and a
    // touch there reaches this document, never the section's: listen here as well, once.
    attachTouchBoundaryListener(view, document)

    view.addEventListener('load', event => {
        try {
            const { doc, index } = event.detail
            auditLoadedDocument(doc)
            attachSelection(view, doc, index)
            attachEdgeFadeListenerIfNeeded(view)
            attachWheelPageTurnListenerIfNeeded(view, doc)
            attachTouchBoundaryListenerIfNeeded(view, doc)
            // Only once the opening `ready` has gone: before that, `sectionCount` is not known
            // yet and this would report it as zero.
            if (publishedCounts !== null) publishReadiness()
        } catch (error) {
            notice(error)
        }
    })

    view.addEventListener('relocate', event => {
        const detail = event.detail ?? {}
        const doc = documentOf(detail.range)
        post({
            type: 'relocated',
            // A relocation without a locator is a position update with less in it. Sending an
            // empty string instead would be refused whole by the host as a malformed CFI, which
            // reads like an attack and costs the section index and the progress with it.
            cfi: typeof detail.cfi === 'string' && detail.cfi !== '' ? detail.cfi : null,
            sectionIndex: sectionIndexByDocument.get(doc) ?? lastLoadedIndex,
            fraction: typeof detail.fraction === 'number' ? detail.fraction : null,
            sectionTitle: detail.tocItem?.label ?? null,
        })
        // A relocation the anchor/navigation path caused (`goTo`, restoring a saved CFI) does not
        // necessarily fire `#container`'s own `scroll` event, so this is a second sync point for
        // the edge fade rather than the only one.
        updateEdgeFades()
    })

    // A link out of the book goes nowhere. The host's navigation policy refuses the scheme as
    // well; this cancels it before a navigation is attempted at all.
    view.addEventListener('external-link', event => event.preventDefault())

    const book = await openBook()
    await view.open(book)
    // `showTextStart: true`, not the default. Left at its default, `View.init` falls through to
    // `next()` — a *relative* page turn from an undefined starting position — to establish the
    // opening location. For a book whose first section's own columnization leaves that undefined
    // start on a page other than the one actually scrolled into view, the section that ends up
    // loaded renders correctly (right markup, right computed style, right layout — confirmed live
    // against the owner's real Standard Ebooks *Frankenstein*) at a horizontal offset one page
    // width outside the viewport, which reads as a wholly blank page though nothing failed and no
    // error is thrown. `showTextStart: true` instead resolves an explicit target — the first
    // bodymatter landmark, or the book's first linear section — through `View.goToTextStart()`'s
    // indexed `goTo()`, which lands the opening view correctly. The branch's own synthetic
    // two-section fixture (`UITestShelfFixture.EPUBPack`) never exercised the `next()` branch's
    // failure mode; only a real, larger book's spine did.
    await view.init({ lastLocation: null, showTextStart: true })

    // The one entry point the host calls. Its name is not guessable content and, more to the
    // point, `script-src 'self'` means a book cannot run code to call it.
    window.__studywrightReaderDispatch = payload => {
        try {
            switch (payload?.command) {
            // `goTo` and the search are async, so their failures arrive as a rejected promise
            // and never reach the `catch` below. A stored CFI that no longer resolves — the
            // ordinary case after a book is re-imported — would otherwise be an unhandled
            // rejection with the host told nothing, which is exactly the silence the `notice`
            // message exists to end.
            case 'navigate': return void view.goTo(payload.href).catch(notice)
            case 'goTo': return void view.goTo(payload.cfi).catch(notice)
            // `View.select` catches its own errors and logs them, so there is nothing here to
            // catch: an unresolvable selection is upstream's silent no-op rather than a notice
            // this file drops.
            case 'select': return void view.select(payload.cfi)
            case 'search': return void runSearch(view, payload.query).catch(notice)
            case 'clearSearch': return void view.clearSearch()
            case 'locate': return void locate(view, payload.quote, payload.highlight === true).catch(notice)
            case 'setStyle': return void setStyle(view, payload.css)
            case 'setFlow': return void setFlow(view, payload.flow)
            // The host's own page-turn command — sent by the native SwiftUI tap zones, the Mac
            // keyboard bindings, and the VoiceOver/Voice Control page-turn action on iOS
            // (`ReaderEPUBWebView.swift`), none of which need anything else from this page.
            // `view.next()`/`view.prev()` are foliate-js's public "turn a page, or advance to the
            // next/previous section once already at this one's end/start" call, in *either*
            // flow — `Paginator.#turnPage` decides which for a reflowable book, exactly as the
            // wheel and touch-boundary handlers above use it.
            case 'nextPage': return void view.next().catch(notice)
            case 'previousPage': return void view.prev().catch(notice)
            default: return
            }
        } catch (error) {
            // A command that threw synchronously is not a book that would not open either.
            notice(error)
        }
    }

    sectionCount = book.sections?.length ?? 0
    publishReadiness()
}

main().catch(fail)
