# Optional reader controls

Retain `EPUBReaderControls(publication: book, session: session)` alongside the publication and
session you already use. The model observes the session's `readerState`; it never creates a
session, mounts a view, or takes over `onEvent`. Controls may be attached after readiness.
Keep one model per session, even when reopening the same publication. Call
`controls.cancelPendingCommands()` when discarding it and `session.close()` when leaving the book.

The controls were operated live on iPhone, iPad and iPhone Duo simulators and in a Mac window.
What was seen, what was fixed and what is still unverified is on
[#51](https://github.com/vocaro/EPUBLib/issues/51#issuecomment-6159295619) ([second part](https://github.com/vocaro/EPUBLib/issues/51#issuecomment-6159295950)); the names VoiceOver is given are
[below](#names-values-and-states), and [testing](testing.md#reader-controls-probe) has the probe
that operated them.

Add the toolbar inside the host's `NavigationStack` on iPhone/iPad or window on Mac.
`Examples/VoiceOverVerification/Shared` contains this compiled integration example:

<!-- snippet:toolbar -->
```swift
struct ToolbarReader: View {
    let controls: EPUBReaderControls // Retained alongside the existing session by the host.
    let savePosition: () -> Void

    var body: some View {
        EPUBReaderView(session: controls.session)
            .toolbar {
                EPUBReaderToolbar(controls: controls, groups: [.search, .contents, .appearance, .readingMode])
                ToolbarItem(placement: .automatic) {
                    Button("Save Bookmark", systemImage: "bookmark", action: savePosition)
                }
                #if os(iOS)
                EPUBReaderToolbar(controls: controls, groups: [.pages], placement: .topBarPinnedTrailing)
                #else
                ToolbarSpacer(.fixed)
                EPUBReaderToolbar(controls: controls, groups: [.pages])
                #endif
            }
    }
}
```
<!-- /snippet -->

Pass ordered `groups` to omit or rearrange `.pages`, `.search`, `.contents`, `.appearance`, `.readingMode`
and `.hideControls` ([below](#hiding-the-controls-while-reading)).
`placement` accepts SwiftUI's `ToolbarItemPlacement`. Use separate toolbar instances with
disjoint groups for different placements. Add host `ToolbarItem`s in the same builder.
The toolbar uses icons with accessible labels to fit phone widths; search opens a popover
(which SwiftUI adapts on compact devices), and contents/appearance use system menus. Native
window/navigation toolbar overflow remains controlled by SwiftUI and the host's placements.
Page arrows have visibility priority above all other built-in controls and form a paired
native group on Mac. On iPhone/iPad, use `.topBarPinnedTrailing`
as shown above to keep them outside overflow, even when other controls do not fit.
Reading mode uses joined Continuous Scroll/Paging buttons with the active mode selected.
It sizes to its icons, is available when the session supports both modes, and is separate from appearance.
The mode picker has high visibility priority, below the page arrows, because segmented
pickers have no automatic overflow-menu representation on iOS. On Mac each segment is a radio
button named Continuous Scroll or Paging, with the current mode selected.

For an embedded reader use `EPUBReaderControlStrip(controls: controls) { /* host views */ }`.
It lays out horizontally when it fits and stacks groups and custom views vertically at narrow
widths or larger accessibility text sizes. In a compact height, such as an iPhone on its side,
Contents and Appearance show icons only, retaining their accessible names. Groups wrap into rows in their supplied order, preserving their text sizes and keeping the
strip shorter than a full column at accessibility sizes.
The runnable sample starts with this strip and host-owned
bookmark menu; “Use Toolbar” switches to the window/navigation toolbar. The menu offers
Save Bookmark, Return to Bookmark and Clear Bookmark for one bookmark per book. Its icon fills
when saved and becomes an outline when cleared. Page arrows
form a separate group at the far right. `EPUBReaderControl(controls:group:inlineSearch:)` exposes individual groups.
For custom labels, icons or overflow menus compose your own buttons using `controls.send`,
`changeStyle`, `submitSearch` and the observable status, instead of duplicating state plumbing.
Do not put an inline text field inside a `Menu`; use the built-in search popover there.

On iPhone and iPad the strip is as tall as its groups wherever it is offered that much, and
where it is offered less it takes that and scrolls its groups. Its own search field raises the
keyboard, and what the keyboard leaves a stack of the strip and the reader can be less than
the strip needs: on an iPhone on its side at the larger text sizes, and at the largest
accessibility size on an iPad mini on its side or a small iPhone upright. The page buttons and
the field stay on screen there, and a swipe on the strip brings the other groups up with the
keyboard still up, wherever it starts: between the controls or on the field, a menu or the
reading mode. With the room it needs the strip neither scrolls nor
clips anything, and its frames are what they were before it could scroll. Its groups keep the
height a stack gave them, so a label too long for its line is cut short and not wrapped. A
strip with nothing in it that fills the width, such as one without `.search`, stays as wide as
its groups. On a Mac the strip is as tall as its groups whatever it is offered: no keyboard
takes its room and text is one size there, and a scroll view would put one more container round
the strip's controls in the Mac's accessibility tree
([SwiftUI controls in each platform's tree](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/accessibility.md#swiftui-controls-take-different-shapes-in-each-platforms-tree)).

The strip sets a layout priority of 1 on itself, so that a stack offers it the height it needs
before the reader beside it
([layout priority](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/accessibility.md#a-layout-priority-is-seen-only-from-the-outermost-modifier)).
A host that applies padding or a frame to the strip sets the priority again after it, as the
sample does:

```swift
VStack(spacing: 0) {
    EPUBReaderControlStrip(controls: controls).padding(.horizontal).layoutPriority(1)
    EPUBReaderView(session: controls.session)
}
```

Without it the strip is still never cut off: it scrolls in the share it is given. The priority
holds in a row as well as a column, where a strip placed beside flexible views of the host's is
offered the width its row needs first; `.layoutPriority(0)` on the strip gives it an equal share
again.

Previous/next always submit logical commands. RTL books reverse the physical order and arrow
icons, independently of the app's language. Scrolled flow retains viewport-step behavior and
labels the buttons “Scroll Backward”/“Scroll Forward”.
Known book boundaries disable turns; nil means unknown and lets the engine decide. The current
contents entry receives a checkmark when it names the section being read and, for fragments, its
current title matches. An entry names the section that `navigate(href:)` shows for it, and the
location's href is read the same way: the path is percent-decoded and compared as a Swift
string, by canonical equivalence, as archive paths are
([architecture](architecture.md#publication-model)). So `cafe%CC%81.xhtml`, `caf%C3%A9.xhtml` and
`café.xhtml` name one section, and an entry that names a spine item's designated fallback names
that item's section ([#206](https://github.com/vocaro/EPUBLib/issues/206)). Fragment precision is
limited by the existing location API; duplicate chapter titles can be ambiguous. Nested children
appear in submenus and parent links remain selectable. An empty contents menu says “No contents
available”; entries without links are disabled.

Search sends commands only on Return or the Search button. Typing does not search, and no
keyboard shortcut is installed that could intercept editing keys. On a Mac, Search and Clear
retain focus in the field. On iPhone and iPad the field gives its focus up when Return or its
Search button submits a search, in the strip and in a search pane alike, which puts the
keyboard away: it would cover the page or the results the search shows, and where the strip
fills what the keyboard leaves there is no page to tap to dismiss it. Clear Search there
returns focus to the field, to type again. A search pane's field takes focus when the pane
opens; the strip's inline field does not when it appears, so opening a book raises no keyboard
over it. While the keyboard is up the bundled reader's pages keep the layout they had without
it, and the keyboard covers their foot, as does whatever a host stacks under a reader it makes
shorter for the keyboard: laid out again for the shorter reader, the book was paginated as the
keyboard rose for a search and again as the search put it away, and on an iPad one column
became two and back ([native viewer](native-viewer.md), "Keyboard" under Layout).
Whitespace-only submission clears highlights. The native engine rejects
empty normalized queries and queries longer than 512 Swift characters, reports errors, and
emits `.searchChanged(.searching(query:))`, then `.completed(query:hasMatches:)` after the
whole-book scan. With the `.search` capability, submission sends `.search(text:)`, highlights
all matches, and opens the first rendered match in spine order. No matches leave the reading
position unchanged. Engines with only `.searchHighlight` retain their highlight-only behavior;
direct `.searchHighlight(text:)` calls also preserve position. Completion never relies on relocation.
Clear reports `.idle`; `.locate`
also clears search. A newer direct search/clear suppresses an older completion and navigation;
newer page navigation prevents a pending search from moving the reader back. Task cancellation
ends pending search feedback: a search still reading the book or building its results reports
`.idle` with no results, and `send` throws `CancellationError`. A cancellation that arrives
after the results are published comes too late, whatever callback or observer makes it, and
the search completes. Close suppresses all subsequent callbacks. Hosts switching on
`EPUBReaderEvent` must add the new `.searchChanged` case.

The field shows pending/queued, no matches or an error. Its queued line counts searches only:
a line for every pending command would resize inline controls, and the reader under them,
during a page turn. The search pane's X closes it without
clearing the query, highlights, results or current match; its separate Clear Search button
clears them all and retains field focus. A successful search by an engine that only highlights
leaves only the field and action buttons; with `.searchResults` the pane adds the match
navigator and result list described below. Feedback describes the submitted query; editing
text does not replace the active highlight query. `hasMatches` reports occurrences the reader
can show: a query found only in content that renders nothing completes with no matches.

## Hiding the controls while reading

`epubReaderHidesControls(_:whileReading:)` hides the controls while the book is read and brings
them back ([#696](https://github.com/vocaro/EPUBLib/issues/696)), as Apple's guidelines ask of a
toolbar hidden "for a distraction-free experience": with ways to "reliably restore" it
([Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)), and no
Liquid Glass in the content layer
([Materials](https://developer.apple.com/design/human-interface-guidelines/materials)). Apply it
to the view that holds the reader and its toolbar or strip, after the `.toolbar`, so that the
toolbar's items see it:

<!-- snippet:hiding -->
```swift
struct HidingReader: View {
    let controls: EPUBReaderControls // Retained alongside the existing session by the host.

    var body: some View {
        EPUBReaderView(session: controls.session)
            .toolbar {
                EPUBReaderToolbar(controls: controls, groups: [.search, .contents, .appearance, .readingMode, .hideControls])
                #if os(iOS)
                EPUBReaderToolbar(controls: controls, groups: [.pages], placement: .topBarPinnedTrailing)
                #else
                ToolbarSpacer(.fixed)
                EPUBReaderToolbar(controls: controls, groups: [.pages])
                #endif
            }
            // After the toolbar, so that its Hide Controls group is offered.
            .epubReaderHidesControls(controls)
    }
}
```
<!-- /snippet -->

`controls.controlsHidden` says whether they are hidden, and `hideControls()`, `showControls()`
and `toggleControls()` change it, for custom controls too. It is true only while the reader is
ready: a book that closes or fails shows its controls again, with what they say of it. The
complete reader of [#690](https://github.com/vocaro/EPUBLib/issues/690), when it comes, applies
the modifier itself and offers `whileReading` as its own option.

Hidden, on iPhone and iPad the navigation bar, the bottom bar, the status bar and the home
indicator go. On a Mac the window toolbar goes, as View > Hide Toolbar takes it, and View > Show
Toolbar brings the controls back with it. An `EPUBReaderControlStrip` keeps its place and its
height, with its groups unseen, disabled and hidden from assistive technology, and its search
field gives up its focus and the keyboard. `.hideControls` is a Hide Controls button, offered
only under the modifier: elsewhere it takes no place in a toolbar or a strip.

They hide by themselves as the person reads on with the reader's own input: a page turned by a
key, a swipe, an edge tap or click or the wheel, and continuous scroll dragged by a finger or
moved by a Mac's wheel or trackpad. A page button, a contents entry, a search, a host command
and VoiceOver's own page turns leave them as they are. While VoiceOver or Switch Control is
running they do not hide by themselves, since hidden controls are gone from what either can
reach, and either coming on shows them. `whileReading: false` hides them only when asked.

They come back:

- by a tap in the middle of the page on iPhone and iPad, which hides them again: anywhere on it
  but the edge zones that turn the page (`EPUBPageControls`), a link, a picture or selected
  text. It waits until it is not the first tap of the double tap that selects a word. A click
  of an iPad's pointer is such a tap. While VoiceOver is running it does nothing: VoiceOver's
  double tap on a line reaches the reader as a touch at the line.
- by VoiceOver's Magic Tap, a two-finger double tap, from any line of the reader or from the
  Show Controls button, which hides them again too, on iPhone and iPad.
- by Option-Command-T, the shortcut of the Mac's own Show Toolbar, which the Hide Controls group
  and the Show Controls button carry, whatever has keyboard focus. Hide Controls is disabled
  while the controls are hidden: a hidden bar's items keep their shortcuts, and with both
  enabled the key did nothing on an iPhone simulator.
- by the Show Controls button, a chevron in the room the bars left, or over the hidden strip
  where no bar left room. It is drawn in the secondary label colour, with no glass, at more than
  the 3:1 a control's graphic needs against the background, in light and dark and with Increase
  Contrast ([#696](https://github.com/vocaro/EPUBLib/issues/696) has the measures). VoiceOver
  reads it as "Show Controls, button" where it stands, and reads none of the strip's hidden
  groups (iPhone and iPad simulators).
- when the width changes while they are hidden, as in a rotation.

The reader keeps the room the bars took. From the layout that hides the controls until both
bars are back, it is laid out in the safe area it had while they showed, so the book is not laid
out again and a bar coming back covers no text. The bars do
not go or come back at once: the navigation bar and the bottom bar each change the safe area in
a layout of its own. When the room each left was measured and given back a layout behind it,
the reader was laid out at five other frames in each round of hiding and showing on an iPhone
17 Pro simulator (`ReaderControlsHidingTests.testHiddenBarsLeaveTheReaderItsFrame`). The room is
the host's background, and only the bars are glass, over it. This holds for a reader in the safe
area, as `EPUBReaderView` is unless the host has it ignore the safe area; one that ignores it
runs under the bars as before, and was not checked.

On a Mac a click in the middle of the text keeps its meaning, the insertion point VoiceOver
starts at, and shows or hides nothing. Option-Command-T is View > Hide Toolbar's shortcut there
too; which of the two takes it in an app with that menu was not checked.

Migration: hosts with exhaustive switches over `EPUBReaderControlGroup` add `.hideControls`.

## Search results

An engine advertising `.searchResults` (the bundled reader does) publishes the completed
search's occurrences as `EPUBSearchResults` in `readerState.status.searchResults` and through
`.searchResultsChanged`, before `.searchChanged(.completed)`. `controls.searchResults` reads
the same value. It holds the submitted `query`, the `results`, their `count`, the
`currentIndex` / `current` match and `isTruncated`. Each `EPUBSearchResult` has its `index`,
its section's `spineIndex` and `sectionTitle` (the contents entry in effect, else the
document's own title), the `matchedText` as the book spells it, `contextBefore` /
`contextAfter` from the same paragraph or table cell (about a line, cut at whole words;
`snippet` joins the three), and a `location` with the section `href`, overall `progression`,
contents `title`, `quote`, page-list `page` and, in the bundled reader, a `bookmark` naming
exactly the occurrence. Pass that location to `.restore` or keep it as an `EPUBHighlight`.

Results exist only while `status.search` is `.completed`. Another query, Clear Search, a
rejected search, `.locate` and close withdraw them: the value becomes nil, reported by
`.searchResultsChanged(nil)` except after close. A search cancelled before its results are
published ends with none; a cancellation that arrives after they are published withdraws
nothing, and the search completes with them. No matches is a completed search
with an empty list. `.search` and `.searchHighlight` both list results; only `.search` opens
the first one and makes it current.

Three commands navigate, each requiring `.searchResults`:

| Command | Effect |
| --- | --- |
| `.nextSearchResult` / `.previousSearchResult` | Shows the neighbouring result and makes it current. Accepted without effect while there are no results. |
| `.showSearchResult(result)` | Shows that result and makes it current. Throws `invalidCommand` for a result that is not in the current list, such as one kept from a replaced or cleared search. |

`controls.showNextSearchResult()`, `showPreviousSearchResult()` and `showSearchResult(_:)`
submit them through the controls' FIFO queue; `canShowSearchResults` says whether there is
anything to step through. Once the engine has shown the match, they have VoiceOver say it
(`searchResultAnnouncement`), and its cursor stays on the control. A shown result is brought
into view in both flows and drawn in a stronger highlight than the other matches. Paging shows
its page. Continuous scroll rests its line about a third of the way down the view, with the
text before it above, or lower in a section's first lines, whose start is then at the top, so
that the location stays in its section; VoiceOver's cursor, where it is in the text, goes to
that line. Nothing is selected.

The bundled reader and the supplied controls settle these questions as follows:

- **Order.** Spine order across every spine document, nonlinear ones included, then document
  order within each. Overlapping occurrences each count, as each is highlighted. Occurrences
  in content that renders nothing (`display: none`, a hidden note) are not results.
- **Ends.** Stepping wraps, as the system find panels do: next from the last result shows the
  first, previous from the first shows the last. `isAtFirst` / `isAtLast` and the indicator
  say where the current match is. With one result a step shows it again.
  `EPUBSearchResults.steppedIndex(forward:)` is the one rule the commands follow.
- **Page navigation.** The current match is the result last shown. Page turns, scrolling,
  contents navigation, `.restore`, typography and flow changes leave it and the results
  alone, so the next step continues from that match, not from the visible page. After
  `.searchHighlight`, or when newer navigation kept a pending `.search` from moving the
  reader, there is no current match: next then shows the first result and previous the last.
- **Bounds.** One search lists at most 10,000 results and reads at most 10,000 matches from
  one section. Beyond that `isTruncated` is true, `count` is a lower bound shown as
  “10,000+”, and stepping stays within the listed results, each of which remains accurate.

Match navigation is separate from page turns throughout: its own commands, its own labels
(“Previous Match” / “Next Match”) and up/down chevrons in a fixed logical order that an RTL
book never mirrors. No keyboard shortcut is installed and Return still submits the query; a
host wanting Find Next on Command-G binds it to `controls.showNextSearchResult()`.

Once a search has results, the search pane shows the navigator under the field: `3 of 27`,
or `27 matches` before one has been shown. As a popover or sheet the pane lists the results
beneath it. Where the keyboard leaves the pane little room, such as an iPhone on its side or
an iPad mini's popover on its side, the list gives way first, down to 44 points, and whatever
still does not fit under the field scrolls there, so that larger text does not push the field
and the X off the screen. The inline field in `EPUBReaderControlStrip` has a Search Results
button that presents the list in a popover instead. Choosing a result shows it. Where the pane
or the list is a sheet, which covers the reader, it also closes it, leaving the query and results
in place: a popover becomes a sheet in a window of compact width, on an iPhone and in a narrow
iPad window. A popover stays open, as it does after a step. Both views are public for other
placements:

<!-- snippet:searchResults -->
```swift
/// Keeps the match count and stepping at hand while the search pane is closed, and lists the
/// results in a sheet the host owns. The built-in search pane already contains both.
struct SearchResultsExample: View {
    let controls: EPUBReaderControls // Retained alongside the existing session by the host.
    @State private var browsing = false

    var body: some View {
        EPUBReaderView(session: controls.session)
            .toolbar {
                EPUBReaderToolbar(controls: controls, groups: [.search, .contents])
                ToolbarItemGroup(placement: Self.placement) {
                    EPUBSearchResultNavigator(controls: controls, showsResultBrowser: false)
                    Button("Search Results", systemImage: "list.bullet.rectangle") { browsing = true }
                        .disabled(!controls.canShowSearchResults)
                }
            }
            .sheet(isPresented: $browsing) {
                EPUBSearchResultList(controls: controls) { _ in browsing = false }
            }
    }

    #if os(iOS)
    private static let placement = ToolbarItemPlacement.bottomBar
    #else
    private static let placement = ToolbarItemPlacement.automatic
    #endif
}
```
<!-- /snippet -->

`EPUBSearchResultNavigator(controls:showsResultBrowser:)` is the indicator with the two match
buttons and, by default, a button presenting the browser. Unlike the pane's own copy it also
states pending, empty and failed searches. It lays out in one row, or the indicator above its
buttons at narrow widths and large text sizes. `EPUBSearchResultList(controls:onSelect:)` is
the browser: results grouped under their section, the occurrence in bold within its context,
the page label when the book has a page list, a checkmark on the current match, and the
pending, empty or failed statement in place of an empty list. Both show nothing for an engine
without `.searchResults`.

For custom controls, `controls.searchResultSummary` is the indicator's text and
`searchResultAccessibilityValue` its spoken form (“Match 27 of 27, last match, Second
Chapter”), which the supplied match buttons also carry as their value. `searchResultAnnouncement`
is what is announced
([VoiceOver does not reread a changed value](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#voiceover-keeps-an-items-traits-and-actions-as-it-found-them)):
the same words, then the text from
the occurrence onward (“Match 27 of 27, last match, Second Chapter: needle at the end.”).
`searchResultButtonLabel(forward:)` and `searchResultButtonHelp(forward:)` give the buttons'
label and help; the help states a wrap or the first step. `searchResultAccessibilityLabel(for:)`
names a result by its place, section and page, then the text from the occurrence onward and
what precedes it, so two occurrences in one paragraph still read differently.

The query, results and current match live in the session and the controls model, not in a
view. They survive closing the pane, toolbar adaptation, a fold or resize and remounting the
reader for the same session.

Migration: hosts with exhaustive switches add `.searchResults` (`EPUBReaderCapability`),
`.nextSearchResult`, `.previousSearchResult` and `.showSearchResult` (`EPUBReaderCommand`) and
`.searchResultsChanged` (`EPUBReaderEvent`). `EPUBSearchState`, `submitSearch()`,
`clearSearch()` and the control groups are unchanged. A third-party engine that only
highlights needs nothing beyond those cases: it omits the capability, answers the three
commands with `.unsupported(.searchResults)`, and the supplied controls keep their earlier
search pane. An engine adopting the capability publishes the list before completion, mirrors
it in `readerState` when it has one, steps as `steppedIndex(forward:)` says and withdraws
results as above; `EPUBEngineContract.verify` checks each of these.

## Commands, appearance and state

Commands submitted through one controls model execute in FIFO order. Style edits read the latest
style when they execute, preserving fields changed by earlier queued edits or host commands.
Appearance controls change font size two points at a time within 12–36 points, the sizes the
bundled reader draws distinctly, and are disabled at either end; they choose System, Light or Dark. System
is the default and follows the mounted view's color scheme, including OS theme changes and
host color-scheme overrides. Explicit Light/Dark remain fixed until changed. Use
`controls.changeStyle { $0.appearance = .system }` (or `.light` / `.dark`) in host controls.
`readerState.status.effectiveAppearance` reports the resolved Light/Dark value without
replacing the selected preference. Existing `isDark:` initializers and property writes still
select an explicit appearance; the Boolean getter is true only for explicit Dark.
Reading mode controls
switch between continuous scrolling and paging. The native engine's
existing relayout preserves the reading anchor. Controls show command activity and errors and
remain disabled until ready, after close/failure or while the surface is detached. Unsupported
groups are hidden. Queued work rechecks lifecycle before submission; cancellation invalidates the
queue, and a new book/model cannot receive old work. Already submitted commands cannot be undone.
For strict ordering of host actions with toolbar actions, send both through the same controls model;
direct `session.send` calls may interleave at suspension points
([submission is not completion](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/command-lifecycles.md#command-submission-is-not-completion)).

The native session maintains `readerState` for direct commands, input navigation, remounts and
close. Third-party sessions remain source-compatible via a default nil state; built-in controls
are unavailable until they opt in. An engine can retain `EPUBReaderState`, expose it on the session,
and update an `EPUBReaderStatus` using `state.update(_:)`. Publish lifecycle, capabilities, actual
style, resolved effective appearance, location, optional turn boundaries, search feedback and the number of active commands.
Update state before the corresponding event
([publish state first](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/command-lifecycles.md#publish-state-before-the-event-that-reports-it)).
Existing event callbacks remain host-owned.

All controls use native SwiftUI buttons, text fields and menus, semantic labels and standard
keyboard traversal. There are no page-turn shortcuts on the toolbar. Apply `epubReaderPageControls(.hostOnly)`
to the retained reading surface to disable direct input while keeping toolbar commands available,
or provide custom `EPUBPageControls` keyboard bindings in the host's integration code.
The verification host's reader uses the default input settings. Native reader key handlers
remain on the sibling reading surface, so focus in search uses normal editing keys. Hosts retain
ownership of persistence, library/import management, selection actions and app-specific shortcuts.

Page-button help describes the configured native inputs. On Mac, default Next Page help
lists Right Arrow, Page Down and Space, the right edge click, and wheel/trackpad directions;
Previous Page lists Left Arrow, Page Up and Shift-Space with the opposite gestures. Keyboard
hints say “With reader focus”: they do not apply while the search field or another host field
has focus. On iPhone/iPad the help describes edge taps and horizontal touch swipes instead
of mouse gestures, alongside any configured hardware keys. SwiftUI presents help on platforms
that support it; the accessible button label stays short.

The buttons read the same `epubReaderPageControls` environment as the reading surface.
Apply that modifier to a common ancestor of the reader and toolbar/strip, or apply the same
value to both when they have separate scopes. For example:

```swift
VStack {
    EPUBReaderView(session: controls.session)
    EPUBReaderControlStrip(controls: controls)
}
.epubReaderPageControls(pageInputs)
```

For a toolbar, apply the modifier after `.toolbar { EPUBReaderToolbar(controls: controls) }`
on the containing reader view. Updating `pageInputs` updates both direct input and help
without reopening the book. A modifier applied only inside a child reading surface does
not reach sibling controls. Removed/remapped bindings, disabled gestures, invalid or zero
edge widths, and `.hostOnly` are reflected in help. Duplicate key chords use their first
effective binding, matching the reader. In continuous scroll, only keyboard page-step hints
remain; edge clicks/taps, touch page swipes and wheel page turns are available only in paging.
RTL reverses physical gesture directions; keyboard bindings retain their configured logical
actions (the default Right Arrow still means next).

Hosts can supplement or replace help without registering toolbar shortcuts:

```swift
controls.customizePageButtonHelp = { action, defaultHelp in
    defaultHelp + (action == .next ? " You can also use the host's Next command." : "")
}
// Or replace it entirely, for example when integrating another reader engine:
controls.customizePageButtonHelp = { action, _ in
    action == .next ? "Continue reading using the host controls." : "Return using the host controls."
}
```

Assign `nil` to restore the defaults. Custom host buttons can reuse
`controls.pageButtonLabel(for:)` and `controls.pageButtonHelp(for:pageControls:)`, passing
the same input settings as their reading surface. This help API describes the bundled native
engine; hosts integrating third-party input behavior should customize its text accordingly.

## Names, values and states

What the accessibility tree holds for each supplied control, read from it on iOS while the
controls were operated; the Mac's tree agrees where noted.

| Control | Name | Value or state |
| --- | --- | --- |
| Page buttons | Previous Page, Next Page; Scroll Backward, Scroll Forward in continuous scroll | Disabled at either end of the book |
| Reading mode | Continuous Scroll, Paging | The current one selected. On the Mac a radio group named Reading Mode with two radio buttons of those names, the current one's value 1. |
| Search, Contents, Appearance | The same | Contents and Appearance are menu buttons on the Mac |
| Hide Controls, Show Controls | The same | Option-Command-T on each; Show Controls takes VoiceOver's Magic Tap on iPhone and iPad |
| Contents entries | The entry's title | The current ones selected; the unlinked entry disabled; a parent "Collapsed" to VoiceOver |
| Appearance entries | Smaller Text, Larger Text, System, Light, Dark | The chosen appearance selected. On the Mac the three appearances are in a submenu named Appearance. |
| Search field | Search in book | The query |
| Pane buttons | Search, Close Search, Clear Search; Search Results and Close Search Results in the strip's browser | |
| Count | Search matches | "Match 2 of 14, Low tide"; "Match 1 of 14, first match, Before the road"; "Match 14 of 14, last match, Afterword"; "Match 1 of 1, only match, The market"; "Match 1 of at least 10,000, first match, Stage 1" |
| Previous Match, Next Match | The same | The count's value |
| Result row | "Match 9 of 14, The cairn, page 11: lantern on the cairn. Preceded by: when the evening is quiet. Somebody has left a" | "Current match" and selected on the current row |
| Section in the list | Its title | A heading |

In the right-to-left book the tree lists Previous Page before Next Page, as in a left-to-right
one, though Next Page is drawn on the left.

Two things the tree shows that the source does not intend: the contents entries' "Current
section" value is not exposed on iOS (the system menu shows a checkmark, which VoiceOver calls
"selected"), and every result row holds a hidden checkmark image named "Selected", which
VoiceOver did not stop on
([SwiftUI controls in each platform's tree](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/accessibility.md#swiftui-controls-take-different-shapes-in-each-platforms-tree)).
