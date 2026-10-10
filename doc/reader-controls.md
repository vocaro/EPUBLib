# Optional reader controls

Retain `EPUBReaderControls(publication: book, session: session)` alongside the publication and
session you already use. The model observes the session's `readerState`; it never creates a
session, mounts a view, or takes over `onEvent`. Controls may be attached after readiness.
Keep one model per session, even when reopening the same publication. Call
`controls.cancelPendingCommands()` when discarding it and `session.close()` when leaving the book.

Add the toolbar inside the host's `NavigationStack` on iPhone/iPad or window on Mac. The sample
contains this compiled integration example:

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
                ToolbarSpacer(.fixed)
                EPUBReaderToolbar(controls: controls, groups: [.pages])
            }
    }
}
```
<!-- /snippet -->

Pass ordered `groups` to omit or rearrange `.pages`, `.search`, `.contents`, `.appearance`, `.readingMode`.
`placement` accepts SwiftUI's `ToolbarItemPlacement`. Use separate toolbar instances with
disjoint groups for different placements. Add host `ToolbarItem`s in the same builder.
The toolbar uses icons with accessible labels to fit phone widths; search opens a popover
(which SwiftUI adapts on compact devices), and contents/appearance use system menus. Native
window/navigation toolbar overflow remains controlled by SwiftUI and the host's placements.
Reading mode uses joined Continuous Scroll/Paging buttons with the active mode selected.
It is available when the session supports both modes and is separate from appearance.

For an embedded reader use `EPUBReaderControlStrip(controls: controls) { /* host views */ }`.
It lays out horizontally when it fits and stacks groups and custom views vertically at narrow
widths or larger accessibility text sizes. The runnable sample starts with this strip and host-owned
bookmark menu; “Use Toolbar” switches to the window/navigation toolbar. The menu offers
Save Bookmark, Return to Bookmark and Clear Bookmark for one bookmark per book. Its icon fills
when saved and becomes an outline when cleared. Page arrows
form a separate group at the far right. `EPUBReaderControl(controls:group:inlineSearch:)` exposes individual groups.
For custom labels, icons or overflow menus compose your own buttons using `controls.send`,
`changeStyle`, `submitSearch` and the observable status, instead of duplicating state plumbing.
Do not put an inline text field inside a `Menu`; use the built-in search popover there.

Previous/next always submit logical commands. RTL books reverse the physical order and arrow
icons, independently of the app's language. Scrolled flow retains viewport-step behavior.
Known book boundaries disable turns; nil means unknown and lets the engine decide. The current
contents entry receives a checkmark when its encoded section href and, for fragments, its
current title match. Fragment precision is limited by the existing location API; duplicate
chapter titles can be ambiguous. Nested children appear in submenus and parent links remain
selectable. An empty contents menu says “No contents available”; entries without links are disabled.

Search sends commands only on Return or the Search button. Typing does not search, and no
keyboard shortcut is installed that could intercept editing keys. Search and Clear retain
focus in the field. Whitespace-only submission clears highlights. The native engine rejects
empty normalized queries and queries longer than 512 Swift characters, reports errors, and
emits `.searchChanged(.searching(query:))`, then `.completed(query:hasMatches:)` after the
whole-book scan. With the `.search` capability, submission sends `.search(text:)`, highlights
all matches, and opens the first rendered match in spine order. No matches leave the reading
position unchanged. Engines with only `.searchHighlight` retain their highlight-only behavior;
direct `.searchHighlight(text:)` calls also preserve position. Completion never relies on relocation.
Clear reports `.idle`; `.locate`
also clears search. A newer direct search/clear suppresses an older completion and navigation;
newer page navigation prevents a pending search from moving the reader back. Task cancellation
ends pending search feedback and close suppresses all subsequent callbacks. Hosts switching on
`EPUBReaderEvent` must add the new `.searchChanged` case.

The field shows pending/queued, no matches or an error. The search pane's X closes it without
clearing the query or highlights; its separate Clear Search button clears both and retains
field focus. Successful searches leave only the field and action buttons. Feedback describes the submitted query; editing text does not
replace the active highlight query.
There is no result browser, count, or next/previous-match command. Those remain follow-up APIs.

Commands submitted through one controls model execute in FIFO order. Style edits read the latest
style when they execute, preserving fields changed by earlier queued edits or host commands.
Appearance controls change font size (10–36 points) and choose System, Light or Dark. System
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
direct `session.send` calls may interleave at suspension points.

The native session maintains `readerState` for direct commands, input navigation, remounts and
close. Third-party sessions remain source-compatible via a default nil state; built-in controls
are unavailable until they opt in. An engine can retain `EPUBReaderState`, expose it on the session,
and update an `EPUBReaderStatus` using `state.update(_:)`. Publish lifecycle, capabilities, actual
style, resolved effective appearance, location, optional turn boundaries, search feedback and the number of active commands.
Update state before the corresponding event. Existing event callbacks remain host-owned.

All controls use native SwiftUI buttons, text fields and menus, semantic labels and standard
keyboard traversal. There are no page-turn shortcuts on the toolbar. Apply `epubReaderPageControls(.hostOnly)`
to the retained reading surface to disable direct input while keeping toolbar commands available,
or provide custom `EPUBPageControls` keyboard bindings in the host's integration code.
The sample reader uses the default input settings. Native reader key handlers
remain on the sibling reading surface, so focus in search uses normal editing keys. Hosts retain
ownership of persistence, library/import management, selection actions and app-specific shortcuts.
