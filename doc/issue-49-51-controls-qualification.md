# Reader controls operated live

Issues [#49](https://github.com/vocaro/EPUBLib/issues/49) and
[#51](https://github.com/vocaro/EPUBLib/issues/51) stayed open because nobody had operated the
supplied reader controls: the toolbar, the control strip, the search pane with its match count,
Previous and Next Match and the result browser. On 2026-10-11 they were operated on iPhone,
iPad and iPhone Duo simulators and in a Mac window, every tap and click made by XCTest's UI
automation on a minimal host. Four defects were found and fixed, three in the controls and one
in the reader; more observations are left with the owner. Physical hardware was not used.

This is simulator and automation evidence. It shows what the controls do, how they are laid
out and what the accessibility tree and XCTest's VoiceOver service report. It does not show a
finger's reach, a physical hinge or what a person hears.

## What was run

| Where | OS | Built with | Windows |
| --- | --- | --- | --- |
| iPhone 17 Pro simulator | iOS 27.0 `24A434` | Xcode 27.0 `27A266a` | 402 × 874, 874 × 402 |
| iPad Air 13-inch (M4) simulator | iOS 27.0 `24A434` | Xcode 27.0 `27A266a` | 1024 × 1366, 1366 × 1024 |
| iPhone Duo simulator | iOS 27.1 `24A94401` | Xcode 27.1 `27A9269` | outer 466 × 678 and 678 × 466; inner 669 × 951 and 951 × 669 |
| This Mac (`Mac17,6`) | macOS 27.0 `26A428` | Xcode 27.0 `27A266a` | 1000 × 760, 560 × 700 |

The iOS 27.1 runtime runs the iPhone Duo alone, so the other two simulators ran iOS 27.0. Each
simulator was created for these runs and deleted afterwards.

`Examples/ControlsQualification` is the host: `EPUBReaderView` in an ordinary `NavigationStack`
with `EPUBReaderToolbar` for search, contents, appearance and reading mode at `.topBarTrailing`
and the page buttons at `.topBarPinnedTrailing`, as [reader-controls.md](reader-controls.md)
shows. Launch arguments swap in the embedded `EPUBReaderControlStrip`, or a host-placed
`EPUBSearchResultNavigator` in the bottom bar with `EPUBSearchResultList` in a sheet, and add
host actions beside the supplied groups.
A line under the reader prints the reader's public state, so each control's effect can be read
back. Its three books are synthetic (`scripts/make-controls-fixture.py`):

- **The Lantern Road**: six documents, contents nested four deep with an unlinked heading and
  an unlinked entry, a page list, "lantern" 14 times (three in one paragraph), "heron" once.
- **طريق المصباح**: Arabic, with a right-to-left page progression and nested contents.
- **Two Hundred and Forty Stages**: 240 documents, 480 "lantern" and more than 10,000 "the".

`ControlsProbe`, a UI test, performs one step per line of a file (tap this name, type, rotate,
dump the tree) and keeps a log, the accessibility tree and a screenshot after each step.
`scripts/run-controls-qualification.py` runs one scenario and does what only the Mac can do
mid-run: set the simulator's text size, capture each display, fold the Duo. The probe asserts
nothing; every statement below was read from its logs, trees and screenshots.

Revisions: the reader at `5dbdedf` for the first pass on all three simulators; `145a21c`, with
the first two fixes below, for the VoiceOver service, large text, overflow, rotation and the
Mac; `f98db10`, with `main` at `9a1a797` merged and all four fixes, for the last iPhone runs,
made from `5fa8fc5`, which adds only this record. Each run's `meta.txt` holds its revision, OS
and Xcode.

## Defects found and fixed

**A refused search was stated two or three times.** A query longer than 512 characters showed
"The search text is empty or too long" twice in the search pane, on iPhone and iPad, and three
times in the control strip. The search field printed the failed search, then the command error
that carried the same words, and the strip printed the command error again. The field and the
strip now leave the command error out while the failed search states it; another command's
refusal is still shown beside it. At `145a21c` the pane and the strip each show it once.

**The search field moved about its sheet on iPhone.** The pane is a sheet there, and SwiftUI
centred it. With no results the field sat at y = 273 of 874; when results arrived it moved to
y = 78, and Clear Search sent it back, so the button left the finger that pressed it by 195
points. The pane now fills its sheet from the top: at `145a21c` the field is at y = 78 with no
query, no matches, one match, fourteen and a refusal. The iPad's popover measures the same
before and after, 316 × 93 empty and 372 × 446 with results.

**With the iPhone on its side, results pushed the field off the screen.** In landscape (874 ×
402, seen at `145a21c`) the result list asked for at least 160 points, the sheet's content came
out taller than the sheet, and the sheet cut its top off: the field was at y = −38 and Close
Search at y = −31, out of reach until the keyboard was put away. The list's minimum is now 44
points in a compact height. At `f98db10` the field is at y = 16 and Close Search at y = 22, with
the list 52 points tall above the keyboard, before and after a rotation with the pane open, and
Close Search closed it.

The keyboard leaves the sheet 177 points there, not the 225 or so this record first gave. Read
again at `e47700f`: the keys begin at y = 222, their suggestions take the 45 points over them,
the list ends at y = 161 and the sheet's padding at 177. The field, its buttons, the match
navigator and the padding take 125 of the 177, so at the default text size the list has 8
points more than its minimum.

**At larger text sizes the same sheet lost its field again**
([#291](https://github.com/vocaro/EPUBLib/issues/291)). Clear Search and the match navigator
grow with the text and only the list gave way, so from the second size above the default the
content was taller than the 177 points. Seen at `2187f80`: the field was at y = 13 at
`extra-extra-large`, y = 8 at `extra-extra-extra-large`, y = −2 at `accessibility-medium`, and
at `accessibility-extra-extra-extra-large` the field, 73 points tall, was at y = −58 and Close
Search, 66 tall, at y = −54. The list was at its 44 points throughout. Its frame in the tree
reaches y = 401 at the accessibility sizes, but its scroll bar is 44 points tall: once the
list's bottom edge passes the top of the keyboard, the system extends the scroll view under it.
An iPhone SE on its side (667 × 375) has 168 points and was 2 short at the default size, with
the field at y = 15, and at the largest size had the field at y = −63.

In a compact height whatever does not fit under the field now scrolls there, and scrolling it
puts the keyboard away. At `a81c544` on the iPhone 17 Pro the field is at y = 16 and Close
Search at y = 20 to 22 at each size from `large` to `accessibility-medium`. At the largest size
the field is at y = 18 and Close Search at y = 22, beside a Search button 78 points tall, and
their row leaves 49 points above the keyboard in which Clear Search, the navigator and the list
scroll. One drag there put the keyboard away; the pane then showed all three with the list 95
points tall, and Next Match stepped to the second match. At each size the field kept its place
when it took focus again and through a turn to portrait and back, and Close Search closed the
pane. On the iPhone SE the field is at y = 16 at the default size, where the 2 points that do
not fit scroll, and at y = 18 at the largest. An iPhone 17e on its side (844 × 390) has less
again, 166 points, and was 4 short at the default size with the field at y = 14 (read at
`aae45d2`); at `b2bbeac` its field is at y = 16 at the default size and y = 18 at the largest,
and the same steps ran there.

Nothing else moved at the default size. The iPhone 17 Pro on its side and upright, the iPhone
17 Pro Max on its side, the iPhone SE upright and the iPad's popover in both orientations (372
× 446, the list 340 × 320) have the frames they had before. The iPhone 17 Pro Max upright was
not compared: the keyboard was not up when its frames were read before the change. The iPhone
17 Pro and the iPad were read again at `31b0e7f`, built with Xcode 27.0 like the rest of this
record and the iPhone 17e's frames; the iPhone SE, the iPhone 17 Pro Max and the other frames
from before the change come from builds made with Xcode 27.1 `27A9269` on iOS 27.0, which gave
the iPhone 17 Pro the same frames.

**A regular height could be as short of room**
([#310](https://github.com/vocaro/EPUBLib/issues/310)). Outside a compact height the list still
asked for 160 points and nothing scrolled. An iPad mini on its side (1133 × 744) leaves the
search popover 284 points above the keyboard, from y = 32 to 316, which was 2 fewer than the
pane needed at the default text size: seen at `b2bbeac`, the field was at y = 47, a point of
the padding above it gone. At `accessibility-medium` the field was at y = 25 and Close Search
at y = 29. At `accessibility-extra-extra-extra-large` the field was at y = −31 and Close Search
at y = −28, above the popover with the Search button, and the popover showed Clear Search, the
navigator and part of one result. Upright, an iPhone SE (375 × 667) leaves the sheet 387 points
from y = 20 and an iPhone 13 mini (375 × 812) leaves it 425 from y = 50. Both held the pane up
to `accessibility-medium`. At the largest size the SE's field was at y = 8, its top 12 points
cut off with 9 of Close Search's, and the 13 mini's was at y = 57, whole, with 11 points of the
padding above it gone.

The list now gives way to 44 points in every height, and what still does not fit under the
field scrolls there. At `0dc1b41` with the keyboard up, the iPad mini on its side has the field
at y = 48 at the default size and at `accessibility-medium`, with the list 157 and 113 points
tall. At the largest size its field is at y = 50 and Close Search at y = 54, and their row
leaves 154 points in which Clear Search, the navigator and the list scroll. One drag there put
the keyboard away; the popover then took the 418 × 608 it asks for with the list 320 points
tall, Next Match stepped to the second match and Close Search closed the pane. At the largest
size the iPhone SE has the field at y = 38 and Close Search at y = 42 with the list 99 points
tall, and the iPhone 13 mini has them at y = 68 and y = 72 with the list 138 tall. On each,
Next Match stepped twice and Close Search closed the pane.

Nothing else moved. Upright, both iPhones have the frames they had at the default size and at
`accessibility-medium`: the list 260 and 216 points tall on the SE, 299 and 254 on the 13 mini.
The iPad mini's popover upright is 372 × 446 with the list 340 × 320, as it is on its side once
the keyboard is away, and without results it is 316 × 93 at the default size, 348 × 119 at
`accessibility-medium` and 418 × 193 at the largest, before and after. The iPhone SE on its
side has the frames given above: the field at y = 16 at the default size, where 2 points
scroll, and at y = 18 at the largest. These three simulators ran iOS 27.0 on builds made with
Xcode 27.0. On both iPhones the keyboard was sometimes down in the first tree after Return, at
the default size as well as the largest; the field was tapped and the tree taken again.

**With its own keyboard up, the control strip went off the top of the screen**
([#330](https://github.com/vocaro/EPUBLib/issues/330)). The strip was as tall as its groups
whatever it was offered. Its field raises the keyboard and kept it up after a search, and the
search adds the match row. Where that left the host's stack less height than the strip and the
host's 21-point status line need, the stack was centred on its room, and half of what was over
went off the top. Seen at `b95ed53` and `57bef2e` after a search for "lantern": an iPhone 17 Pro
on its side has 178 points from the top of the screen to the keyboard's suggestions, and the
page buttons were at y = −23 at `extra-extra-extra-large`, y = −39 at `accessibility-medium` and
y = −123 at `accessibility-extra-extra-extra-large`, where 9 of the field's 73 points were left
on screen. An iPhone SE on its side has 169 points: the page buttons had lost 10 of their 17 at
the default size, and at the largest Search and Clear Search were above the screen. At the
largest size an iPad mini on its side (284 points, from y = 32) had the page buttons at y = −38
to 16, and an upright iPhone SE (387 points, from y = 20) had them at y = −27 to 27. In each the
reader view had no height, so there was no page to tap to put the keyboard away.

On iPhone and iPad the strip now scrolls its groups where it is offered less height than they
need, and its field gives up focus when it submits a search, which puts the keyboard away. At
`ef79633` (iOS 27.0, built with Xcode 27.0), in twenty runs of the three simulators, the field
was tapped, "lantern" typed, the keyboard's own Search key touched, and the field tapped again
to bring the keyboard back over the results. With the keyboard up the strip starts at the top
of the safe area and ends at the status line, which is above the keyboard: it has 157 points
on the iPhone 17 Pro on its side, 148 on the iPhone SE, 263 on the iPad mini and 366 on the
upright iPhone SE, to the nearest point. Top and bottom edges, before and after the search
alike:

| Where | Text size | Page buttons | Field | Search | Clear Search |
| --- | --- | --- | --- | --- | --- |
| iPhone 17 Pro on its side | `extra-extra-extra-large` | 0 to 23 | 26 to 63 | 32 to 58 | 31 to 58 |
| | `accessibility-medium` | 0 to 28 | 31 to 74 | 37 to 68 | 37 to 69 |
| | largest | 0 to 54 | 59 to 132 | 65 to 125 | 64 to 126 |
| iPhone SE on its side | `large` | 0 to 17 | 19 to 53 | 27 to 46 | 26 to 46 |
| | `extra-extra-extra-large` | 0 to 23 | 26 to 63 | 31 to 57 | 31 to 58 |
| | `accessibility-medium` | 0 to 29 | 32 to 75 | 37 to 69 | 37 to 70 |
| | largest | 0 to 54 | 59 to 132 | 65 to 125 | 64 to 126 |
| iPad mini on its side | largest | 32 to 86 | 91 to 164 | 97 to 157 | 96 to 158 |
| iPhone SE upright | largest | 20 to 74 | 79 to 152 | 85 to 145 | 84 to 146 |

The groups under them scroll. After the search the match row is whole under the field on the
iPad mini, the upright iPhone SE and, up to `accessibility-medium`, both iPhones on their
sides; at the largest size on their sides it is out of sight, 5 points of it showing on the
iPhone 17 Pro. One drag on the strip, with the keyboard still up, brought the reading mode to
the strip's bottom edge wherever the strip scrolls, with Appearance, Contents and the match row
above it: all of the match row but on the iPhone SE on its side at `accessibility-medium`,
where 30 of its 33 points showed, and at the largest size on the iPhones on their sides, where
the strip showed the reading mode, Appearance and the lower third to half of Contents. Beside
the top safe area the strip scrolls under the status bar, as any scroll view does.

A touch scrolls the strip from anywhere on it, a control included, if it moves soon after it
goes down. Those runs read otherwise. The probe's drag scrolled the strip from beside a row,
between two rows and at Search and Clear Search, and not from the field on the iPhone SE on
its side or from Contents on the upright iPhone SE, where a swipe did not either, and the field
and the menus were taken to keep a touch that starts on them. On 2026-10-12 at `1eb150a` the
host recorded each touch itself ([Evidence](#evidence-and-repeating-it)): the view it went down
on, when it had moved 10 points, and when the strip's scroll view began to drag. The probe's
drag rests 0.15 s before it moves. Its swipe never touched Contents: it went down at y = 434,
on the keyboard's suggestions, whose top is at 407.

On an iPhone SE simulator (iOS 27.0) at the largest size, with the keyboard up over the
results, synthetic touches went down on each control and moved after four rests, upright,
where the strip has 95 points to scroll, and on its side, where it has 256:

| Touch went down on | Moved after 0.02 to 0.03 s | 0.05 to 0.10 s | 0.15 to 0.17 s | 0.32 to 0.45 s |
| --- | --- | --- | --- | --- |
| The field | scrolled, 2 of 2 | scrolled, 2 of 2 | scrolled, 1 of 6 | kept, 2 of 2 |
| Contents | scrolled, 3 of 3 | scrolled, 4 of 4 | scrolled, 2 of 6 | menu opened (upright) |
| Appearance | scrolled, 3 of 3 | scrolled, 3 of 3 | scrolled, 2 of 6 | menu opened (on its side) |
| The reading mode | scrolled, 2 of 2 | scrolled, 2 of 2 | scrolled, 2 of 5 | kept, 2 of 2 |
| Between two rows or beside a row | scrolled, 3 of 3 | | | |

All 21 touches on a control that moved within a tenth of a second scrolled the strip, upward
and downward, a drag at 300 points a second among them. In 20 the scroll view began to drag
0.03 to 0.12 s after the touch went down; the other was down for 0.03 s in all and had lifted
before it did. No menu opened, the reading mode stayed Paging and the keyboard stayed up. Of
the 23 that rested 0.15 to 0.17 s, 7 scrolled the strip and the control kept 16: nothing
scrolled, no menu opened and the reading mode did not change. That rest is about where a
scroll view hands a touch to the control under it: the same drag went either way from one try
to the next, which is how the probe's drag came to scroll from one place and not another. After
0.32 s or more the field and the reading mode kept the touch. A menu, after 0.38 and 0.45 s,
opened under it, which put the keyboard away as a tap on a menu does. A control in any scroll
view answers so: a swipe scrolls, and a touch that rests on a control before it moves has
pressed it.

These are XCTest's touches on a simulator, timed as a swipe and as a press; a finger was not
tried. On its side the menus were touched with the strip scrolled part of the way, 54 points
or more down the screen: in an earlier run that day a quick downward drag that began 50 points
from the top did not reach the strip, the application having left the foreground, as the host
recorded.

Three seconds after the keyboard's Search key was touched, the keyboard was down and nothing
had keyboard focus, in all twenty runs; tapping the field brought both back. Return was a
touch on that key because a Return typed by XCTest can leave the keyboard down by itself, under
a field that still has focus ([#307](https://github.com/vocaro/EPUBLib/issues/307#issuecomment-6132965039)):
at `b95ed53` the field read "Keyboard Focused" after it in every tree. In eighteen of the
twenty the strip was then whole with the page under it; the other two are the iPhones on their
sides at the largest size, below. A tap on the strip's Search button did as the key does, and
Clear Search brought the keyboard back with the field empty and in focus (iPhone 17 Pro
upright).

The search pane's field has the same rule, by the owner's second answer. At `bc83557` on the
iPhone 17 Pro, a touch on the keyboard's Search key in the pane left the keyboard down and
nothing with keyboard focus. Upright at the default size the sheet's list is then 480 points
tall. On its side at the largest size the field is at y = 18 and Close Search at y = 22 with
Clear Search, the navigator and the list, 95 points tall, all on screen, where they scrolled
in the 49 points over the keyboard until a drag put it away. The pane's own Search button did
as the key does, and Clear Search brought the keyboard back with the field in focus. On an
iPad Air upright the popover is 372 × 446 after the key with its list 320 points tall, as it
was with the keyboard up, and Clear Search brought the keyboard back there too.

The screen can be too short without a keyboard. At the largest size with results the strip's
groups are 402 points tall on the iPhone 17 Pro on its side and 403 on the iPhone SE, and the
strip has 361 and 354 points there. The page buttons are at y = 0 and the reading mode is
reached by scrolling, where the page buttons were at y = −25 on the iPhone SE before.

Where the strip has the room it needs, nothing moved. The trees of the 33 states in which the
strip was whole at `b95ed53` were compared, element by element, with those at `ef79633`: before
the field is tapped in each of that revision's fifteen runs (the five poses at `large`,
`accessibility-medium` and the largest size), with the field tapped in ten and with the
keyboard up after the search in eight. Every element has the frame it had, but for four on the
upright iPhone 17 Pro that are a point off in height or position: the Contents symbol at the
default and the largest size, the Paging symbol at the default size and the Search button at
`accessibility-medium`. The strip's groups are laid out as a stack laid them out when it
offered the strip half its height: a label too long for its line is cut short and not wrapped,
so that Appearance still reads "Appearan…" on the iPhone SE upright at the largest size and the
strip is 340 points tall there, as it was.

A host that pads the strip, as this one and the sample do, now sets the strip's layout priority
again after the padding; see [reader-controls.md](reader-controls.md). On a Mac the strip is as
it was. Nothing raises a keyboard there, and a scroll view is a scroll area in the Mac's
accessibility tree, a container round what it holds: read on macOS 27.0 from a window of a
button, a field, a menu and a segmented picker, with and without a scroll view round them.
VoiceOver was not run on it.

**Continuous scroll lost its place after an accessibility read.** On iOS the scrolled reader is
a text view whose accessibility lists every paragraph of the book, and reading that list (an
XCTest snapshot did it here; VoiceOver reads the same elements) lays the whole text out behind
the scroll view. After that, one Scroll Forward showed the right text, d04–d07 of the fourth
chapter, but reported and kept a place twelve paragraphs back in the third, and switching to
Paging then showed that place. It reproduced on every attempt on the iPhone simulator and never
without the read. The reader now reads the visible range from the lines the viewport laid out,
after settling the viewport where the view stands; AppKit, which showed the same loss in a
headless test by drawing the earlier text, holds the first visible line in place instead.
`ScrolledAccessibilityReadTests` fails on both platforms without the change. Its trigger is a
stand-in, a request for every paragraph's rectangle, because a test host has no text
accessibility to walk. At `f98db10` the same live sequence, read included, reported the fourth
chapter after each step (0.5162, then 0.5328 of the book) and showed it again in Paging
(0.5476): the values of a run without the read.

## iPhone 17 Pro

Portrait, 402 × 874, 17 points, light, at `5dbdedf` unless stated.

**Toolbar.** One capsule holds, left to right, Search, Contents, Appearance, the reading-mode
picker, Previous Page and Next Page; the book's title has no room and is not shown. Nothing is
in overflow. In landscape the title is shown as well.

| Control | Operated | Seen |
| --- | --- | --- |
| Next Page, Previous Page | Turns forward and back, then to the book's end | The location moved a page each time. Previous Page is disabled on the first page and Next Page on the last; a tap on the disabled button did nothing. |
| Contents | Part One › The harbour › The ferry; Part Two › The pass › The climb › The cairn; a part's own entry; the unlinked entry | Each submenu replaces its parent in place, headed by the parent's name, four levels deep. Each choice showed its target: the page holding "The ferry", and "The cairn" at the top of its page. A part with a link lists itself first in its submenu and opened its chapter; the unlinked heading has no such entry. The unlinked entry is disabled, and a tap on it left the menu open and the position unchanged. The chapter in view carries a checkmark, and so does the section in view inside it. |
| Appearance | Larger Text, Dark, Light, System | 17 to 19 points; the reader turned dark and light; the chosen appearance carries the checkmark. |
| Reading mode | Continuous Scroll, then Paging | The flow changed and the page buttons became Scroll Backward and Scroll Forward, each moving one viewport. From a fresh open the position survived the round trip: the chapter heading and d01–d04, d04–d07 after one step, then a page starting at d05. |

**Search pane.** Search presents a sheet with the field focused and the keyboard up. Typing
did not search: with "heron" typed and not submitted the reader's search state stayed idle.
The keyboard's search key and the pane's Search button each submitted.

| State | Shown in the pane | Reader |
| --- | --- | --- |
| No results (`zzyzx`) | "No matches" | Position unchanged |
| One result (`heron`) | "1 of 1"; Previous and Next Match enabled, each leaving it at 1 of 1 | The market, page 7 |
| Many (`lantern`) | "1 of 14"; the list grouped under Before the road, Low tide, The ferry and so on, the occurrence bold in its context, the page label beside it, a checkmark on the current one | First match shown |
| Pending (`the` in the 240-document book) | A spinner and "Searching…", in a screenshot; the tree was not read while it was up | Unchanged until it completes |
| Truncated (the same search) | "1 of 10,000+" | First match shown |
| Refused (513 characters) | The refusal in red | Unchanged |
| Whitespace only | Nothing; the search ends | Unchanged |

Next Match went 1, 2, 3 across the three occurrences in one paragraph and on into the next
chapter; Previous Match from 1 showed 14 in the Afterword and Next Match from 14 showed 1.
With 480 results the same two steps went 1 → 480 → 1. Two page turns after a result left the
count at "2 of 14", and the next step showed 3, not the match nearest the page. Choosing a row
in the list (the ninth, then the fourteenth after scrolling to it) showed that result and
closed the sheet; reopened, the pane still held the query and "9 of 14". Close Search left the
query, the highlights and the current match; Clear Search emptied the field and ended the
search with the pane still open. Since [#330](https://github.com/vocaro/EPUBLib/issues/330) a
search from the pane's field puts the keyboard away, as one from the strip's does: item 12 of
[For the owner to judge](#for-the-owner-to-judge).

After each of these the current match was on screen in paging, drawn orange against the other
matches' yellow. In continuous scroll, with the pane opened and closed around each step,
matches 3, 4 and 9 were on screen and match 7 was not; see
[For the owner to judge](#for-the-owner-to-judge).

**Control strip.** At this width the strip stacks its groups: the page buttons, the search
field with Search and Clear Search, the match row once there are results, Contents,
Appearance, the reading-mode picker. Every one operated as in the toolbar. The match row reads
"1 of 14" with Previous Match, Next Match and Search Results, which presents the browser as a
sheet titled Search Results with the count and a close button; choosing a row closed it.
"No matches" appears under the field. After a search the field kept focus then, so the keyboard
stayed over the lower half of the page until a tap on the page put it away. Since
[#330](https://github.com/vocaro/EPUBLib/issues/330) the field gives focus up when it submits a
search and the keyboard goes: item 12 of [For the owner to judge](#for-the-owner-to-judge).

**Host-placed navigator.** With `EPUBSearchResultNavigator` in the bottom bar and the pane
closed (`f98db10`, continuous scroll), Next Match went from 1 to 14 and on to 1, and Previous
Match back from 1 to 12. After each of the fourteen steps the current match was on screen, at
the top of the view. The host's own sheet of `EPUBSearchResultList` opened scrolled to the
current match.

**Right-to-left book.** Next Page is on the left with a left-pointing chevron and Previous
Page on the right, in the toolbar and in the strip, and Next Page moved forward through the
book in both. Contents and its submenu list the Arabic titles; a search for "مصباح", typed
through the keyboard, found 5 and stepped 1, 2, 3 and back with the match shown each time. In
continuous scroll the buttons keep their sides and are named Scroll Forward and Scroll
Backward.

**Overflow.** With four host actions beside the supplied groups, the bar keeps Search,
Contents, the reading-mode picker, a More button, Previous Page and Next Page; More lists
Appearance and the four host actions. Appearance opens there as a submenu with its five
entries; Larger Text and Dark, chosen through it, took effect (`f98db10`). A refused command
adds the supplied Reader Error item, which on this width also sends Appearance into More.

**Rotation.** With the pane open at "2 of 14", landscape to portrait and back kept the query
and the count each time. A contents menu open during a rotation was dismissed and the bar came
back complete.

## iPad Air 13-inch

Portrait, 1024 × 1366: a regular width, one column of text at 17 points. At `5dbdedf` unless
stated.

**Toolbar.** The title is centred and all six controls sit at the trailing edge in the order
Search, Contents, Appearance, reading mode, Previous Page, Next Page. The page buttons, the
appearance menu and the reading-mode picker behaved as on the iPhone.

**Contents.** Submenus cascade to the left of their parent rather than replacing it: the root
menu under the button, Part Two beside it, The pass beside that, The climb beside that, all
four on screen at once. The cairn, four levels down, opened on its heading; a part's own entry
opened its chapter; the unlinked entry is disabled.

**Search pane.** Search presents a popover that grows from the Search button's place in the
bar; while it is open the bar's other items are not shown and are out of the accessibility
tree. With results the popover is 372 × 446 and its list 320 points tall. Every state in the
iPhone table was seen here too, the pending one aside. Stepping kept the popover open. Choosing
a row in the list showed the result and closed the popover.

While the popover's keyboard is up the reader is shorter than it is wide and lays out two
columns; when the keyboard leaves it returns to one. The shown result stayed on screen through
both. In continuous scroll matches 3, 4, 7 and 9 were each on screen after their step.

**Control strip.** At this width the strip is one row: page buttons, search field, Search,
Clear Search, Contents, Appearance, reading mode. With results the match row appears under the
field, and Search Results presents the browser as a popover, 360 × 433, beside its button.
Choosing a row there showed the result and left the popover open.

**Right-to-left book.** As on the iPhone: Next Page on the left, Previous Page on the right,
logical steps in both flows, Arabic contents and search.

## iPhone Duo

At `5dbdedf`. The poses were set from the command line. `simctl` has no fold command, so the
hinge angle and orientation were posted with `scripts/duo-hinge.sh` of the owner's StudyWright
repository (`547c8b2e5`), which sends the simulator the device-state event Device Hub's
controls send. That is private simulator API, used here as tooling only. Device Hub was not
open. `devicectl device info displays` named the active display after each change.

In every pose all six controls were present, hittable and operated, and none moved to
overflow. The system lays them out in two ways:

| Pose | Hinge | Window | Search, Contents, Appearance | Reading mode, Previous Page, Next Page |
| --- | --- | --- | --- | --- |
| Outer, portrait | 0° | 466 × 678 | A vertical bar on the right edge, 38-point buttons from y = 175 | Top bar, right of the title |
| Outer, landscape | 0° | 678 × 466 | A vertical bar on the left edge, from y = 87 | Top bar, trailing |
| Inner flat, portrait | 180° | 669 × 951 | Top bar, before the reading-mode picker | Top bar |
| Inner flat, landscape | 180° | 951 × 669 | A vertical bar on the right edge, from y = 125 | Top bar, trailing |
| Book | 120° | 951 × 669 | As inner landscape | As inner landscape |
| Laptop | 120° | 669 × 951 | As inner portrait | As inner portrait |

Both page buttons sit side by side in the top bar in every pose, Previous Page before Next
Page, and the reading-mode picker is beside them and switched flows in each pose it was tried
in (both outer orientations, inner landscape, book and laptop). With the vertical bar the
reader's text column is narrower by the bar's width: 355 points of the outer display's 466.

In each pose a page was turned, a contents entry chosen, the text size changed and a search
stepped. On the outer display the search pane is a sheet and the menus replace in place, as on
an iPhone; on the inner display the pane is a popover.

**A fold or a turn while something is open.**

- Search open on the outer display at "2 of 14", then unfolded: the pane became a popover on
  the inner display with the query and "2 of 14" kept, and Next Match showed 3.
- Search open on the inner display in landscape at "4 of 14", then folded to the book pose:
  the popover stayed with "4 of 14", the system split the keyboard around the fold, and Next
  Match showed 5.
- Search open in the laptop pose at "6 of 14", then closed to the outer display: the pane
  became a sheet with "6 of 14", and Next Match showed 7.
- The contents menu open on the inner display, then the device turned; and open on the outer
  display, then unfolded: the menu was dismissed both times, choosing nothing, and the bar
  came back complete in the new pose.

XCTest's rotation request does nothing on this simulator. The inner display's own orientation
is a quarter turn from the outer one's.

## Large text

The simulator's text size was set to the largest accessibility size
(`accessibility-extra-extra-extra-large`) while the host was open.

- **iPhone, toolbar** (`145a21c`). The bar keeps Search, the reading-mode picker, More,
  Previous Page and Next Page; Contents and Appearance are in More. Next Page and both
  reading-mode segments operated. The search sheet's field, buttons and count grow with the
  text, each control stays on screen, and stepping worked. A result row wraps to one or two
  words a line and is about 777 points tall in a list 197 points tall with the keyboard up.
- **iPhone, strip** (`145a21c`). The stacked strip grows with the text: page buttons 38 × 54,
  the field 229 × 72. Search, Next Match, Search Results and its close button, Next Page and
  Continuous Scroll operated. The reading-mode picker does not grow.
- **iPad, toolbar** (`5dbdedf`). The bar is unchanged. Menu entries grow and wrap ("Part One: /
  The coast"), three or four to a screen, and scroll. The search popover is 418 points wide;
  its rows are as on the iPhone.
- **iPad, strip** (`5dbdedf`). The strip stacks and grows as on the iPhone and operated. The
  Search Results popover stays 360 × 433: its list is 167 points tall, a row 775.
- **iPad, the toolbar's reading-mode picker.** In two runs at this size (`5dbdedf` in portrait,
  `145a21c` in landscape) taps on either segment left the flow unchanged. The same taps
  switched it on the iPhone at this size, on the iPad at the default size and in the strip at
  this size. Not explained.
- **Search pane short of room.** With the keyboard up an iPhone on its side, a small iPhone
  upright and an iPad mini on its side leave the pane less than it needs at this size. What
  each shows is under [Defects found and fixed](#defects-found-and-fixed).
- **The strip with its own keyboard up** (`ef79633`, iOS 27.0, Xcode 27.0; an iPhone 17 Pro
  and an iPhone SE on their sides and upright and an iPad mini on its side, at `large`,
  `extra-extra-extra-large`, `accessibility-medium` and this size). Where the keyboard leaves
  the strip less height than its groups need, it scrolls them: on its side the iPhone 17 Pro
  at `extra-extra-extra-large` and both accessibility sizes, and the iPhone SE at those and,
  once a search has added the match row, at the default size; at this size the iPad mini on
  its side, and the upright iPhone SE after a search. The page buttons, the field, Search and
  Clear Search are whole at the top of the strip in every one, and a drag brings the rest up
  with the keyboard still up. The upright iPhone 17 Pro fits the strip at all four sizes: at
  this one, after a search, it takes 459 of the 463 points above the status line. Frames, and
  where a drag has to start, are under
  [Defects found and fixed](#defects-found-and-fixed).
- **The strip's Search Results with the keyboard up** (`d360069`, iOS 27.0, Xcode 27.0; each
  device on its side at `large`, `accessibility-medium` and this size). The browser asks for
  240 points at least, and it has them. On an iPhone it is a sheet, and presenting it puts the
  keyboard away: the keyboard was in the tree taken before Search Results was tapped, was not
  in the tree with the sheet open, and was back once the sheet had closed. The sheet has the
  whole height. On an iPhone 17 Pro (874 × 402) the title is at y = 16 at each size and Close
  Search Results at y = 18, 19 and 22, where it is 54 × 51, and the list is 319, 299 and 254
  points tall. On an iPhone SE (667 × 375) they are at the same heights and the list is 311,
  292 and 247 tall. On an iPad it is a popover, and the keyboard stays up under it. An iPad
  mini on its side (1133 × 744) leaves it 284 points, from y = 32 to 316, and the popover is
  373 × 284 beside its button: the 360 it asks for and its arrow. The title is at y = 48 at
  each size and Close Search Results at y = 50, 51 and 85, whole; the list is 220, 201 and 31
  points tall. At this size the title takes two lines with the count under it, and those and
  the padding take 253 of the 284. One drag in the list's 31 points put the keyboard away; the
  popover then took 373 × 420 with the list 167 tall, and Close Search Results closed it.
  Since #330 a search from the strip's field puts the keyboard away itself: at `ef79633`, on
  the iPad mini on its side at this size, Search Results tapped after the search opened a
  popover of 360 × 433 with no keyboard under it and the list 167 points tall. The keyboard
  is under the popover again only if the field is tapped between the search and Search
  Results.
- **iPhone Duo.** Not completed; see [Not verified](#not-verified).

XCTest's accessibility audit ran on the opening screen and on the search pane at this size. For
the supplied controls it reported that the search field's text "may be clipped" and that a
result row's context text failed its contrast check. Its other findings were the reader's own
text, which follows the reader's text size and not Dynamic Type, and the host's status line.

## Names, values and states

From the accessibility tree on iOS; the Mac's tree agrees where noted.

| Control | Name | Value or state |
| --- | --- | --- |
| Page buttons | Previous Page, Next Page; Scroll Backward, Scroll Forward in continuous scroll | Disabled at either end of the book |
| Reading mode | Continuous Scroll, Paging | The current one selected. On the Mac a radio group named Reading Mode with two radio buttons of those names, the current one's value 1. |
| Search, Contents, Appearance | The same | Contents and Appearance are menu buttons on the Mac |
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
VoiceOver did not stop on.

## XCTest's VoiceOver service

`XCUIDevice.shared.voiceOverService` turns VoiceOver on in the simulator, moves its cursor and
returns the phrase it would speak, up to 64 characters. Nothing was listened to. Activation was
a touch on the control, then a double tap.

**Order.** On the iPhone and the iPad the cursor went Search, Contents, Appearance, Continuous
Scroll, Paging, Previous Page, Next Page, then the page. In the right-to-left book it also met
Previous Page before Next Page. On the iPhone Duo's outer display, with the vertical bar, it
went: the title, Continuous Scroll, Paging, Previous Page, Next Page, every line of the page,
the host's status line, and only then Search, Contents and Appearance.

**Wording.**

- "Search, Button"; "Contents, Button"; "Appearance, Button".
- "Continuous Scroll, Button, 1 of 2"; "selected, Paging, Button, 2 of 2".
- "Previous Page, dimmed, Button, Previous Page. With reader focus: Le…"; "Next Page, Button,
  Next Page. With reader focus: Right Arrow, Page…". The second part is the button's help,
  which begins with its name.
- Contents: "selected, Before the road, Button"; "Part One: The coast, Button, Collapsed,
  Double-tap to expand"; "Afterword, Button"; "A map that was never drawn, dimmed, Button";
  then the system's "Dismiss context menu, Button".
- Appearance: "Smaller Text, Button"; "Larger Text, Button"; "selected, System, Button";
  "Light, Button"; "Dark, Button".
- Search pane, in order: "Search in book, Text field, Is editing, lantern, …"; "Search,
  Button"; "Close Search, Button"; "Clear Search, Button"; "Search matches, Match 1 of 14,
  first match, Before the road"; "Previous Match, Match 1 of 14, first match, Before the road,
  Button"; "Next Match, …, Button"; "Before the road, Heading"; "selected, Match 1 of 14,
  Before the road, page 1: lantern hangs a…"; "Low tide, Heading"; "Match 2 of 14, Low tide,
  page 2: Lantern after lantern is lit al…".

**Activation.** A double tap turned the page, switched to Continuous Scroll and back, opened
Contents and chose Afterword, opened Appearance and chose Light, opened Search, and stepped to
match 2. After Close Search the cursor was back on "Search, Button". After Next Match the
service's phrase was still the button's old one, "Match 1 of 14": within a second of the step
VoiceOver had said nothing about the new match.

On the iPhone Duo, after unfolding with VoiceOver on, the service's phrases named Home Screen
items although the reader was on the inner display. That session is not a result either way.

## The Mac

The owner approved each session before it ran. XCTest clicked through the same host in a Mac
window at `145a21c`, in dark appearance, standing down whenever the host was not frontmost.

- **Window, 1000 × 760.** The toolbar holds Search, Contents, Appearance, the reading-mode
  radio group and the page buttons as a pair, Previous Page first. Next Page and Previous Page
  turned pages; Continuous Scroll, Scroll Forward and Paging worked. Contents cascades to the
  right, and Part Two › The pass › The climb › The cairn opened that section at page 11; the
  unlinked entry is disabled and a click on it did nothing. Appearance lists Smaller Text,
  Larger Text and an Appearance submenu; Larger Text was chosen in the first pass.
- **Search popover.** It hangs from the Search button, 371 × 304, with the field focused, then
  Search, Close Search, Clear Search, the count and its two buttons, and the list, 160 points
  tall, in an outline. "lantern" gave "1 of 14" with the first match highlighted on the page;
  Next Match showed 2 in the next chapter and Previous Match returned; `zzyzx` and Clear Search
  and Close Search were operated in the first pass.
- **Window, 560 × 700.** A request for 420 points gave 560 again. The toolbar keeps Search, the
  reading-mode group, the page buttons and a "more toolbar items" button, whose menu lists
  Contents with its whole tree and Appearance with its entries. Next Page, Search and Next
  Match operated at this width. Nothing was chosen through the overflow menu.

Not done in these passes: choosing a result row (the sixth was outside the list's 160 points
and the probe did not scroll to it), the three appearances in their submenu, and the refused
search, which was skipped because another application had come to the front. The first pass
saved no captures, because the Mac's test runner is sandboxed out of the output folder; the
probe now keeps them in the result bundle.

**VoiceOver.** One session of `scripts/run-voiceover-mac.py` ran against
`Examples/VoiceOverVerification`, whose window shows the control strip. VoiceOver said
"VoiceOverVerificationMac not responding" as it started, then "Automation Running", and
nothing else through fourteen Control-Option-Left steps. Four other test hosts were running on
the Mac. No control was spoken, so this session establishes nothing; VoiceOver was restored to
off and checked.

**Keyboard-only traversal** was not attempted. Keyboard navigation is off in this Mac's
settings (`AppleKeyboardUIMode` 0), so Tab stops only at text fields and lists, and the
setting is the owner's to change.

## For the owner to judge

Described, not decided. None of these was changed.

1. **Focus order on the iPhone Duo.** With the vertical bar, VoiceOver reaches Search,
   Contents and Appearance after the whole page. The system owns that adaptation; the page
   buttons and the reading-mode picker come before the page in every pose.
2. **Focus order in a right-to-left book.** On iOS VoiceOver meets Previous Page, then Next
   Page, the logical order, with Next Page drawn on the left. The Mac's order in such a book
   was not checked here.
3. **Choosing a result closes the toolbar's popover on iPad.**
   [reader-controls.md](reader-controls.md)
   says the pane closes "in a compact width, where the pane covers the reader". The toolbar's
   popover does not cover the reader on iPad and closes all the same, while the strip's
   Search Results popover on the same iPad stays open. A toolbar item's content reports a
   compact width there. Left open, the popover can cover a result at the top right of the
   page.
4. **A shown result can end up just above the view in continuous scroll on iPhone.** After two
   Previous Match steps in the sheet and Close Search, match 7 was one line above the top of
   the view (`5dbdedf`); matches 3, 4 and 9 in the same run were on screen, and all four were
   on the iPad. The sheet and its keyboard resize the reader under them. At `f98db10`, stepped
   with the host-placed navigator and no sheet in the way, all fourteen were on screen; the
   sheet case was not repeated there.
5. **The reader reflows under the search keyboard.** On iPad the page goes from one column to
   two while the popover's keyboard is up, and back. On iPhone the same resize happens behind
   the sheet.
6. **Stepping says nothing to VoiceOver.** After Next Match the count changes on screen and in
   the tree; the service heard no new phrase.
7. **The page buttons' help repeats their name.** VoiceOver speaks "Next Page, Button, Next
   Page. With reader focus: …".
8. **Touch targets in the strip.** At the default text size the strip's page buttons are
   12 × 17 points, 20 apart; Previous and Next Match 18 × 11; Search, Clear Search and Search
   Results about 20 × 19. The toolbar's are 30 to 44 points.
9. **Result rows at the largest text size** are one or two words a line and far taller than
   their list, on iPhone and in both iPad popovers. Every result is reachable; few are
   readable at a glance.
10. **The toolbar's reading-mode picker on iPad at the largest text size** did not answer taps
    in two runs. It may be the simulator or the automation; it needs a finger.
11. **The error item shifts the bar.** After a refused command the toolbar gains Reader Error,
    and on iPhone that moves Appearance into More until the error is cleared.
12. **The keyboard stayed up after a search in the strip** on iPhone, since the field kept
    focus; a tap on the page dismissed it, and at larger text sizes on an iPhone on its side
    the strip filled what the keyboard left, with no page to tap. Decided by the owner on
    2026-10-12 ([#330](https://github.com/vocaro/EPUBLib/issues/330)): on iPhone and iPad
    Return puts the keyboard away, and the Mac keeps focus in the field as before. Asked the
    same day whether the search pane's field should do the same, he answered "yes, same rule
    for the pane". The Search button of either field does as Return does, and Clear Search
    returns focus to the field, to type again; those two follow from his answers and were not
    put to him. While the reader types, before any search, the keyboard is up and the strip
    scrolls; a drag on it does not put the keyboard away.
13. **The page label after a search.** On a first page that starts before the book's first
    page marker, the reader's location reads "no page" when opened, "page 1" once a result on
    that page is shown, and "no page" again after the pane closes.
14. **The strip's Search Results list under the keyboard at the largest text size** is 31
    points tall in an iPad mini's popover on its side, less than a line of a row, where the
    search pane keeps its list 44. A drag in it puts the keyboard away and gives it 167.
    Judged at the owner's request: the browser's layout stays as it is. Nothing is cut off,
    and making its title row scroll would give up a Close Search Results that is always on
    screen. What is out of place is a keyboard under a list that takes no typing, which is
    item 12's question. Item 12's answer removes it after a search: the keyboard is away
    before Search Results can be tapped, and the list is 167 points tall. A reader who taps
    the field again and then Search Results has the keyboard under the list as before.

## Not verified

- Physical iPhone, iPad and iPhone Duo: touch reach, the hinge, real rotation, spoken
  VoiceOver, Switch Control, a hardware keyboard.
- VoiceOver's audio and anything past the 64 characters the service returns, including the
  rest of each hint.
- Mac VoiceOver over the controls, and Mac keyboard-only traversal, as above. Focus after
  closing Search on the Mac is covered by the regression of #58, not here.
- On the Mac: choosing through the toolbar's overflow menu, a result row, the appearance
  submenu, a refused search, a right-to-left book, large text and windows narrower than 560
  points.
- The iPhone Duo at the largest text size. One run opened the contents menu there, whose
  entries no longer fit the outer display without scrolling, and went no further; a second
  did not start. The Duo's inner display under VoiceOver, as above.
- iPad windows narrower than full screen (Split View, Slide Over, resized windows).
- The control strip's Search Results popover under a keyboard taller than the simulator's
  English one. At the largest text size an iPad mini on its side leaves the popover 31 points
  more than its title, count and padding take.
- The pending search's accessibility tree, and an error other than a refused query.
- Choosing a row in a host's own sheet of `EPUBSearchResultList`, and the host-placed
  navigator on iPad and the iPhone Duo.
- The control strip under the VoiceOver service.
- A finger on the strip, and the strip on a device. What scrolls it was settled with XCTest's
  touches on an iPhone SE simulator, where the rest before a touch moves decides it and the
  host recorded that rest for every touch. A swipe is a touch that moves at once, and one that
  moved within a tenth of a second scrolled the strip every time; a finger's own timing was
  not measured. Nor was the strip under a keyboard taller than the simulator's English one, in
  an iPad window smaller than the screen, with host views in it, or under the reader instead
  of over it.

## Evidence and repeating it

Logs, trees, screenshots and result bundles are under `.build/qualification/runs/` of the
verifying checkout, one folder per scenario with its `meta.txt`; the Mac VoiceOver transcript
is under `.build/voiceover/results/`. None of it is committed. The Mac's screenshots show the
whole screen and stay local.

```sh
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
python3 scripts/make-controls-fixture.py
xcodegen generate --spec Examples/ControlsQualification/project.yml
DEVICE=$(xcrun simctl create "controls-$$" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
  com.apple.CoreSimulator.SimRuntime.iOS-27-0)
xcrun simctl boot "$DEVICE"
xcodebuild -project Examples/ControlsQualification/ControlsQualification.xcodeproj \
  -scheme ControlsProbeIOS -destination "platform=iOS Simulator,id=$DEVICE" \
  -derivedDataPath .build/qualification/derived build-for-testing
printf 'tap=Search\ntype=lantern\ntap=search\ndump=results\ntap=Next Match\nstatus\n' > steps.txt
python3 scripts/run-controls-qualification.py --device "$DEVICE" --name search \
  --args "-QualificationBook ltr" --steps steps.txt
xcrun simctl delete "$DEVICE"
```

The first line is the default of `scripts/test-ios.sh`; the runner has it too, whatever
`xcode-select` names, and does not run a probe that another Xcode built. `tap=search` presses
the keyboard's own key: a Return typed with `\n` in a `type=` step can leave the keyboard down
under a field that still has focus, and
[#307](https://github.com/vocaro/EPUBLib/issues/307#issuecomment-6132965039) has the counts.
Each `dump` line of the log says whether the keyboard was on screen and what had keyboard
focus, and on iOS every scenario starts upright.

The probe's steps are documented where they are handled, in
`Examples/ControlsQualification/UITests/ControlsProbe.swift`. Host arguments:
`-QualificationBook ltr|rtl|long`, `-QualificationHost toolbar|strip|navigator`,
`-QualificationPlacement automatic|leading|bottom`, `-QualificationHostItems <count>`,
`-QualificationFlow scrolled`, `-QualificationFontSize <points>`, `-QualificationTitle NO`,
`-QualificationTouchTrace YES` and, on the Mac, `-QualificationWindowSize <width>x<height>`.
UIKit's own `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`
gives the host the largest text size without a change to the simulator; on the iPhone SE the
strip's frames were those `signal=content_size` gave. For the iPhone Duo set `DEVELOPER_DIR`
to Xcode 27.1 for the build and the run, and pass `--hinge-script`; never send that simulator
`simctl io screenConfig`, which crash-loops its SpringBoard. For the Mac pass `--mac` in place
of `--device`, with a signed build, and ask whoever is using the Mac first: the probe takes its
pointer and keyboard. A new simulator shows the keyboard's first-run card once; tap its Continue
before typing. A run stopped part-way leaves the simulator as it was, with VoiceOver on or the
text size large: restore both before the next run, because with VoiceOver on a tap only moves
its cursor.

A tree and a screenshot show where things stand after a touch, not what became of the touch.
With `-QualificationTouchTrace YES` the host records every touch where the application
receives it: the view it went down on, when it had moved 10 points, when each scroll view
began to drag, and the scroll views, the keyboard and any menu before it, as it lifted and a
second later, with a picture of the window then and the touch drawn on it. It also records
the application leaving the foreground and its main thread standing still, either of which
makes a touch go nowhere. The lines go to the host's standard output and, with the pictures,
to `Documents/touch-trace-<launch time>/` in its container:

```sh
ls "$(xcrun simctl get_app_container "$DEVICE" org.epubreaderlib.controlsqualification data)/Documents"
```

A `drag` step rests a tenth of a second before it moves, which the host measures as 0.15 to
0.17 s. That is about as long as a scroll view holds a touch back from the control under it,
and a drag that starts on a control is taken by one or the other from one try to the next. Two
more numbers set the rest in seconds and the speed in points a second, and a seventh keeps the
touch down at the end, which leaves a scroll view where the touch took it and not where a
fling would:

```sh
printf 'drag=0.5,0.52,0.5,0.22,0,1500\ndrag=0.75,0.27,0.75,0.46,0,300,0.6\n' > steps.txt
```

The first is a swipe of 200 points from the middle of an upright iPhone SE; the trace gave its
rest as 0.02 s. With a rest of 0.05 the trace gave 0.08 to 0.10 s, and with 0.3, 0.32 to
0.45 s. The second moves the strip of an iPhone SE on its side 64 points and leaves it there.
A `swipe` step starts where XCTest puts it, which with the keyboard up was on the keyboard. On
an iPhone SE on its side a quick downward drag that started 18 or 50 points from the top of
the screen made the host inactive each of eleven times and sent it to the background in ten;
none of three from 54 points did. The same host runs on a device, for a finger: build the
`ControlsQualification` target for it, install and launch it with `devicectl`, and copy the
trace back with `devicectl device copy from --domain-type appDataContainer`. It recorded one
tap on an iPhone 17 Pro Max (iOS 27.2) that way, and nothing more was tried there.
