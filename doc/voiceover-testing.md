# VoiceOver testing

Use real VoiceOver speech to verify the paginated reader on a Mac, physical iPhone and
physical iPad. Native accessibility API tests support this work but do not establish what
VoiceOver reads. A [simulator's VoiceOver](#simulators) does read, with no device, window or
sound, but it activates nothing, and its sessions are not acceptance evidence. The sessions
are recorded in the
[Mac verification](issue-55-voiceover-mac.md) and the
[iPad and iPhone verification](issue-28-voiceover-devices.md); the acceptance matrix is in
[#28](https://github.com/vocaro/EPUBLib/issues/28).

## Isolated reader and fixture

`Examples/VoiceOverVerification` reuses the normal reader sample's shared interface with
separate application identifiers and a bundled synthetic EPUB. It opens the fixture at launch
without a file-picker interaction. The book contains `word0001` through `word1200` in one
justified paragraph, a heading, an internal **Verification link**, and an image labeled
**Blue verification square**. Its long paragraph retains the continuation context that
originally exposed off-page text. A second section, **Hidden labels** (`OPS/labels.xhtml`),
holds what a book hides from the page and keeps for assistive technology: a heading and a
byline parked at `left: -999em` above an image with an empty `alt`, as a Standard Ebooks title
page has them, words clipped to nothing inside a line, and a parked link. It also holds what a book hides from everyone: a
`visibility: hidden` paragraph and an `aria-hidden` one. A third, **Hidden heading over a
table** (`OPS/table.xhtml`), opens with a parked heading and then a table, so the heading is
hidden labels alone on a line of no height. A second table stands between shown lines on the
section's first page, its last cell a link, and the section goes on for more than a screen. A
fourth, **Pictures and their words** (`OPS/pictures.xhtml`), holds what a book can say of a
picture: nothing, that it is decoration (an empty `alt`), or words. Each stands in a line of
text; a decorative one is also all that a link holds, and stands beside words in a link; and
two come from a file that has a title of its own, one with an empty `alt` and one with none.
None of the section's words is one VoiceOver uses for a picture or a link, so those in a
transcript are VoiceOver's own. A fifth, **Scenes set apart** (`OPS/scenes.xhtml`), holds
rules: an `<hr>` between two paragraphs, one the book gives `role="presentation"`, and one
alone on a page of its own, with a last paragraph on the page after it. None of its words is
one a screen reader uses for a rule either. A sixth, **What each line offers**
(`OPS/offers.xhtml`), shows every kind of item at once, on one page and one
screen, for what VoiceOver's rotor offers on each: its heading, lines of words ("Plain words
above." and "Plain words below."), a link inside a line (**Lone jump**), a picture with words
(**Square with words**) and one with none, and a table row whose second cell is a link ("Left
cell" and "Right cell jump"). Sixty short lines follow ("Below line 01."), so the section's
first line can be shown at the top in continuous scroll. None of its words is one VoiceOver
uses for an action, a picture or a link. A seventh, **Things inside
entries** (`OPS/entries.xhtml`), the book's last, holds a table whose cells hold what a cell
can besides words, one kind to a cell: a rule between two paragraphs and a formula in the
first row, a described picture and a hidden label in the second, decoration and a picture
nobody describes in the third, and a table of its own in the fourth. "Entries follow."
stands before the table and a second formula after it, in the page's own text, and the
section goes on for more than a screen. It has no heading, so the book's headings are those
of the sections before it. None of its words is one a screen reader uses for a rule, a
picture, a formula, a table or a text. A second
bundled book, opened with
`-VerificationBook paragraphs`, is for continuous scroll: chapters of forty, forty and six
ordinary paragraphs of forty numbered words each (`p017w23` is the seventeenth paragraph's
twenty-third), so a line in the middle of a paragraph can be told from its first, and the end
of the book is a few screens from the start of its last chapter. The first book's headings
are "Page boundary verification" (level 1), which opens it, "Link target reached" (level 2)
after the numbered paragraph, the two parked ones (level 1), each opening its section, and
"Pictures and their words", "Scenes set apart" and "What each line offers" (level 1), each
opening one of the three sections before the last, which has none; the second book's are "Chapter one", "Chapter two" and "Chapter three", screens apart.
Do not import private books for this check.

On a Mac the same application can show AppKit's own text view in the reader's place, with
none of the reader's code: `-VerificationPlainText YES` a TextKit 2 view, as the reader's
are, and `-VerificationPlainText TextKit1` a TextKit 1 view. Its text has a link of words,
"reference link", and a link that is a picture. Following either writes "Followed" and the
link's name at the start of the text, which changes the text's value. What VoiceOver says and
does there is AppKit's and VoiceOver's doing: compare it before calling a behaviour the
reader's ([Links](#links)).

Use Xcode 27, OS 27, XcodeGen, Python 3, and a graphical Mac login. Select a signing team for
the UI-test runners and physical-device app. Signed Mac UI tests worked in the initial
session; unsigned runs did not complete. A [hosted Mac session](#hosted-mac-sessions) needs
neither a workstation nor a team: its build is signed ad hoc. Build and generate from the
repository root:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export VOICEOVER_TEAM_ID=YOUR_TEAM_ID
python3 scripts/make-voiceover-fixture.py
xcodegen generate --spec Examples/VoiceOverVerification/project.yml
xcodebuild -project Examples/VoiceOverVerification/VoiceOverVerification.xcodeproj \
  -scheme VoiceOverProbeMac -destination 'platform=macOS' \
  -derivedDataPath .build/voiceover/mac -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$VOICEOVER_TEAM_ID" build-for-testing
```

The fixture is deterministic and original to this repository. Generated Xcode projects,
build products, logs and result bundles are ignored by Git. Keep configuration changes in
`project.yml`; do not commit a personal team identifier.

## Mac speech capture

A Mac session takes over the machine it runs on. Unless someone has to listen or step by
hand, run it on a hosted runner, which needs no workstation and counts as acceptance evidence:
see [Hosted Mac sessions](#hosted-mac-sessions). On a workstation, proceed as follows.

Reserve an interval with exclusive control of the Mac's keyboard focus. Use one automation
controller: no competing agents, other `swift test` or simulator UI runs, or manual VoiceOver
commands during a session. VoiceOver announces their windows and menus too, and any window or
system dialog that takes keyboard focus ends the session. Normally launch a fresh reader
before each case; close previous verification instances first.

```sh
open -na "$PWD/.build/voiceover/mac/Build/Products/Debug/VoiceOverVerificationMac.app" \
  --args -SampleFlow paginated -SampleFontSize 23
python3 scripts/run-voiceover-mac.py --timeout 240 ax:next ax:lines ax:focus \
  in line right left left lastword line nextline
```

The outer Python runner reads the original VoiceOver state, temporarily toggles it through
the approved System Events shortcut if needed, and restores that state in `finally`. It
stops only its own process groups when the deadline expires. It never edits system
preferences or enables VoiceOver's AppleScript-control setting. Native `enable()` timed out
on the Mac in the initial session, so the outer runner owns the Mac toggle. If VoiceOver is
not back in its original state five seconds after the shortcut, the runner prints the reason,
writes the transcript all the same with the reason in a `NOT_RESTORED` line, and exits with
status 126: VoiceOver is then still on, or still off, and is yours to put back. Ordinary
process cleanup cannot recover from forcibly killing the runner itself; verify restoration
independently:

```sh
defaults read com.apple.universalaccess voiceOverOnOffKey
```

This is a read-only check: `0` means off and `1` means on. Restore the original state, rather
than always disabling VoiceOver. Close only the isolated test reader when finished. If a new
Accessibility, Automation or device-authentication permission is needed, use the normal OS
approval flow; do not edit TCC databases or enable broad developer permissions as a workaround.

The probe only records. It polls `XCUIVoiceOverService.currentSpeech()` and prints each new
phrase as a timestamped `VOICEOVER_EVENT`, while the runner sends its steps in order and
waits `--pause` seconds after each VoiceOver command. With `--advance-after SECONDS` it sends
the next step that long after a key's first new phrase, and waits out the pause only when no
new phrase is recorded:

- `in`, `out`: start or stop interacting with the item in the VoiceOver cursor.
- `right`, `left`: the next or previous item; inside text, the next or previous word.
- `line`, `nextline`, `previousline`: read the current line, or move a line and read it.
- `word`, `firstword`, `lastword`: read the word, or move to the first or last visible word.
- `textstart`, `textend`: move to the beginning or end of the text (Control-Option-Shift-Home
  or End).
- `linecount`: Control-Option-F3 twice, the total and visible line counts.
- `readall`: read from the cursor onward.
- `nextheading`: VoiceOver's own move to the next heading, Control-Option-Command-H. There is
  no step for the one before: with Shift added VoiceOver asked the reader for the next heading
  again (macOS 27.0.1). Go back with the rotor's list. In pages a move to a heading on
  another page turns to that page, and VoiceOver reads the page from its top: follow the
  step with `line`, which reads the heading, and `ax:lines`, which shows the page. With
  VoiceOver's cursor on a link, reached by `nextlink`, the step goes to a heading's element
  among the text's children and VoiceOver says the level first, "heading level 2 Link
  target reached": follow it with `describe`, which says what is in the cursor. `line` and
  `right` then read from the insertion point, which is not on the heading.
- `rotor`: Control-Option-U, which opens VoiceOver's rotor: lists of what the item under its
  cursor holds, the reader's Headings among them. `listright` and `listleft` go from list to
  list, `listdown` and `listup` along one, `listchoose` (Return) moves VoiceOver to the item
  named and `listclose` (Escape) closes the rotor. These six are plain keys. Send them only
  while the rotor is open: otherwise the reader takes an arrow as a page turn. The Headings
  list opens on its first item, the book's first heading, wherever VoiceOver's cursor is. A
  list with nothing in it stays open after `listchoose`: where the rotor says "No items in
  Heading menu", as it did on a page with no heading while a page's rotor held that page's
  headings alone, Return chooses nothing. VoiceOver ignores its own Command-F5
  while the rotor is open, so the runner closes one before it restores VoiceOver. After the
  steps of a session that sent `rotor` and no `listclose` after it, the runner sends Escape
  itself, writes `STEP listclose, sent by the runner in case the rotor is still open` and
  waits one pause; a session stopped before the end of its steps gets the same key as the
  runner cleans up. Where `listchoose` had closed the rotor, the reader takes that Escape and
  does nothing with it: VoiceOver said nothing and stayed on its line.
- `activate=LABEL`: Control-Option-Space, sent only if one of VoiceOver's last two phrases
  contains LABEL, as in `"activate=Next Page"`. Without a label it is sent whatever was said.
- `nextlink`, `previouslink`: VoiceOver's Find Next Link and Find Previous Link,
  Control-Option-Command-L and the same with Shift. They move to a link of the text under the
  cursor and name it.
- `describe`: Control-Option-F3 once, what is in the VoiceOver cursor. `attributes`:
  Control-Option-T, the text attributes there.
- `actions`: Control-Option-Command-Space, VoiceOver's Actions menu, which holds the actions
  of the item under its cursor. VoiceOver says "Actions menu" and how many items it has.
  `listdown` and `listup` say each one, `listchoose` performs the one last said, and
  `listclose` closes the menu, at which VoiceOver says "Closing Actions menu".
  `"listchoose=show menu"` sends Return only if one of VoiceOver's last two phrases contains
  the label, as `activate=LABEL` does. On a group the menu held the actions of what the
  group holds, one after another, and on the sample's group with its controls embedded
  VoiceOver said nothing and opened no menu: the list keys after it went to the reader, where
  Down Arrow moves the insertion point. The runner closes a menu a session can have left
  open as it does a rotor, with `STEP listclose, sent by the runner in case the Actions menu
  is still open`.
- `pagedown`, `pageup`: the reader's own page keys, without VoiceOver modifiers.
- `ax:STEP`: a step of the observer described below, through the accessibility API.

Before every key the runner checks that the reader is frontmost and that no password dialog
holds secure keyboard input, and stops the session otherwise. Leave several seconds between
sessions: VoiceOver ignores the shortcut while it is still quitting. Each run writes
`mac-STAMP.transcript.txt` beside its log, observer events and result bundle in
`.build/voiceover/results/`: the steps, heard phrases, value and layout events and fresh
column states merged by time. A session that completes is not an acceptance result. Read the
transcript against the visible text, starting with its first phrases and any `OTHER_TESTS`
lines, which name unit-test hosts of other sessions.

VoiceOver enters a column at its insertion point, and a page turn resets that to the first
line. Start a case with a turn and `ax:focus`, never a click. Eight `left` steps from the
left column, nine from the right, reach **Next Page** in the sample's control strip; eight
`right` steps return from it to the left column. **Previous Page** is one step further.

`"ax:press=Use Toolbar"` moves the sample's controls to the window's toolbar, outside the group
that holds the columns. From the left column, `out out`, five `left`, `in` and six `right`
reached Next Page there in three sessions on a reader with the fix of #337; on one without
it the same keys went elsewhere twice. `activate=Next Page` stops such a session.

A table's row is one character of its page's text, and each of its cells on screen is a text
area of its own. Moving by word (`right`) VoiceOver stops on a row and says "Table row
group", once for rows that follow one another, because the probe records a repeated phrase
once. `in` there says "In Table row group 2 items text" and the first cell's words, and puts
the cursor on that cell; `right` goes to the row's next cell; `in` again reads inside the
cell, by word and by line as in the page's text; `out` leaves the cell, and a second `out`
the row. With the cursor at the cell's first word, `firstword` says "beginning of text".

A session can open with VoiceOver's cursor on a control, on the reader's group or already on
the text, and what VoiceOver keeps of a column depends on how it got there. For a case in which
VoiceOver leaves a column and comes back, bring it to the column by a focus change from
somewhere else, `ax:focus=search ax:focus=0`: when it was on the text from the start, it came
back at the page's first line even on a reader with the fault of
[#337](https://github.com/vocaro/EPUBLib/issues/337).

Use a 600-point window for one column and 1100 points for two (`ax:width=600`),
`-SampleFontSize 17` and `23`, and `ax:larger` or `ax:smaller` for a change while the reader is
open. Take the column count and visible ranges from the `STATE` and `LINE` lines, because
wrapping and viewport height change the numbered boundaries.

## Page actions and value notifications

Observe the real application's accessibility transport with the Mac observer, alone or as
the runner's `ax:` steps:

```sh
VOICEOVER_READER_PID=$(pgrep -x VoiceOverVerificationMac)
xcrun swift scripts/voiceover-ax-observer.swift "$VOICEOVER_READER_PID" 60 \
  lines next lines previous larger smaller width=600 width=1100 \
  > .build/voiceover/ax-events.log
```

The observer accepts only the verification reader's bundle identifier and runs for a bounded
duration. It registers for value, selection and layout notifications on every column and on
the application, then performs its steps and prints each event with its time, the column's
selection and the numbered-word span of its value:

- `next`, `previous`: press the page buttons, found by label or help rather than index.
- `press=LABEL`: press any other button by its label, as in `"ax:press=Use Toolbar"`, which
  moves the sample's controls from the reader's group to the window's toolbar, or a segment
  of Reading Mode: `"ax:press=Continuous Scroll"` and `ax:press=Paging` change the flow
  while the reader is open.
- `larger`, `smaller`: choose the Appearance menu's text-size items.
- `width=POINTS`: resize the window.
- `focus`, `focus=COLUMN`, `focus=search`: give the last column, a numbered column or the
  search field keyboard focus, without a click.
- `lines`: print every accessibility line of each column.
- `links`: print what each column gives an assistive client for its links and attachments.
  A `CHILD` line is one of the text's own children, which Find Next Link moves through. A
  `LINK` line is a run of the text's accessibility string with the element given as its
  link, the element given as its attachment, or both: each one's role, what it is called,
  and its actions.
- `actions`: print each column, everything that holds it up to the window, and any other
  element with a named action, as an `ELEMENT` line: its number in the order an assistive
  client meets it, its depth under the window, its role, what it is called and its actions,
  one an application names itself in quotation marks. VoiceOver's Actions menu holds the
  actions of the item under its cursor, so the lines show where the cursor would have to be
  for a named action to be offered. `actions=all` prints every element of the window.
- `action=NAME`: perform a named action on the first of those elements that has it, without
  VoiceOver, as in `"ax:action=Next Page"`. It prints `MISSING` when no element has one of
  that name.
- `caret=WORDS`: put the insertion point before the first of these words, as in
  `"ax:caret=Bare jump"`. VoiceOver enters a text at its insertion point, so `in` then starts
  on that line and `right` reads the word.
- `follow=WORDS`: press the link that names the words or holds them, by its own action and
  without VoiceOver.
- `wait=SECONDS`: only observe. Without steps the observer only observes; a single step of
  `-` reads steps from standard input.

After each step, `STATE` lines give fresh external reads of every column: width, character
and line counts, selection and word span. Check for `AXValueChanged` with the new bounded text
after every page turn, resize and text-size change; a final changed value alone does not prove
that the notification was delivered. These native presses verify the reader's actions and
notifications, not VoiceOver's own activation: for that, move the VoiceOver cursor to the
button and use `activate` in a runner session.

`--xctest-values` adds XCTest's own snapshot of each column to the transcript whenever it
changes. Use it with `ax:` steps only: once the probe queries the application, XCTest's
**Automation Running** banner takes the VoiceOver cursor about every thirty seconds while the
runner types. The runner stops a session, with exit status 125, as soon as VoiceOver has named
the banner, because the speech after that may be the banner's; only `--xctest-values` with
`ax:` steps alone is exempt. Snapshots re-queried for each read matched the observer after every native page
turn, text-size change and resize, with and without the reader's notifications. Read an
element again rather than reuse a value, and treat neither XCTest nor the observer as speech.

## Continuous scroll

In continuous scroll one text area holds the whole book. VoiceOver on the Mac enters it at its
insertion point, which the reader keeps on the first line on screen (see
[the native viewer](native-viewer.md), "Continuous scroll"). Launch the reader in that flow and
compare what VoiceOver says on entering with what is on screen:

```sh
open -na "$PWD/.build/voiceover/mac/Build/Products/Debug/VoiceOverVerificationMac.app" \
  --args -SampleFlow scrolled -SampleFontSize 23
python3 scripts/run-voiceover-mac.py --timeout 240 --pause 4 ax:width=600 ax:next ax:next \
  ax:focus in line nextline nextline pagedown line nextline out right ax:next left in line
```

There the observer's `next` and `previous` press Scroll Forward and Scroll Backward. Every
`STATE` line gives `VISIBLE`, the text area's visible characters, and `ENTRY`, the line of its
insertion point, and the transcript carries each `AXSelectedTextChanged`, so the insertion
point can be followed beside the speech.

1. Scroll before the first `in` of a session. VoiceOver keeps a text cursor of its own once
   it has been in a text area, so only a first entry shows where the insertion point takes it.
   The phrase after `in` is the `ENTRY` line of the `STATE` before it, the first on screen.
2. `nextline` reads the following lines in order while `SELECTION` follows VoiceOver. The
   first one after entering repeats the rest of the entry line, as in paging.
3. `pagedown` while interacting moves `SELECTION` to the new first line; `line` then reads it.
4. `out`, `right` to leave the text, a scroll step, `left` and `in`: VoiceOver enters at the
   new first line. Each of the reader's own moves shows as `AXLayoutChanged`.

`VISIBLE` is AppKit's own account and counts whole paragraphs: the fixture's 1,200-word
paragraph is visible from its first character while any of it is on screen, and VoiceOver's
first and last visible word, and a text cursor it brings back into view, go by that. The text
area's lines are the whole book's, so a `STATE` read is slow in a long book; the fixture has
269 at this size.

On an iPhone or iPad VoiceOver walks the scroll view's accessibility elements instead, and the
reader lists the lines on screen and the fifty after them, with the fifty before the screen
as well while VoiceOver's cursor is in the text (see [the native viewer](native-viewer.md),
"Continuous scroll", for why fifty). Run the probe (see "Physical iPhone and iPad") in that
flow, on the book of ordinary paragraphs, by adding to its command:

```sh
TEST_RUNNER_VOICEOVER_FLOW=scrolled TEST_RUNNER_VOICEOVER_BOOK=paragraphs \
TEST_RUNNER_VOICEOVER_FONT_SIZE=17 \
TEST_RUNNER_VOICEOVER_STEPS='activate=Scroll Forward,activate=Scroll Forward,wait=2,visible,screenshot,forward=9,visible,screenshot,forward=30,visible,backward=44,visible,screenshot'
```

1. Two scroll steps end in the middle of a paragraph. The first `visible` gives the first and
   last lines on screen. Nothing above them is listed; the fifty lines after them are, and
   are counted as outside the window.
2. Eight moves forward from Scroll Forward cross the sample's other controls and the ninth
   enters the text. Its phrase is the first line on screen, not `w01` of that line's
   paragraph, and the screenshot after it shows the same lines as the one before: coming in
   scrolled nothing.
3. The second `visible` counts fifty more lines, those before the screen, and says how many
   are outside the window.
4. The moves forward give every line once, in order, while the view follows; the moves back
   pass the line VoiceOver came in at and go on above it. A phrase repeated, a line missing,
   or a control's name among them is a failure.
5. `backward=1` straight after coming in returns to the control before the text. A touch on
   a control (`touch=Bookmark`) takes the cursor out, and `visible` then lists nothing above
   the first line on screen; the next move forward comes in at that line.
6. `activate=Contents,activate=Chapter two` moves the reader with the cursor on a control, and
   `point=0.5:0.8` touches a line directly: VoiceOver reads the line under the finger.
7. Straight after a menu closes VoiceOver asks for fifty items at once and reads through
   them. `activate=Contents,activate=Chapter two,wait=2,visible,forward=5,forward=62,visible,backward=72`
   comes into the text at the chapter's heading on the fifth move and must go on past the
   last line that was on screen when the menu closed, a line at a time. "Vertical scroll
   bar" among the lines is the failure of
   [#339](https://github.com/vocaro/EPUBLib/issues/339). On an iPad run it on its side as
   well, with `rotate=landscape` first and `rotate=portrait` last.
8. `touch=LABEL` on an item below the reader and `backward=30` come into the text from below:
   the scroll bar, then the last line that was on screen, then every line above it in order,
   on past the top of the screen. Run it where the view has room to go back, after two
   scroll steps, and at the end of the book
   (`activate=Contents,activate=Chapter three,wait=2` and three scroll steps). "Bookmark"
   straight after the scroll bar, or after one line, is the failure of
   [#367](https://github.com/vocaro/EPUBLib/issues/367): as the cursor went to the scroll
   bar UIKit took the view back 88 points, which it no longer does (step 10). The line after
   the scroll bar is
   the last line in the reader's own view. `visible` gives a later one as the window's last:
   with the cursor on a control before the text it counts every listed line that lies inside
   the window, and the first lines listed after the screen lie under the sample's footer.
9. No line of plain text has "Actions available" after it, and `flick=down` with the cursor on
   one reads no action: it steps by the rotor's own setting, a character of the line on a
   simulator. An iPhone's lines are short enough to show the whole phrase in the 64
   characters a transcript keeps. In the first book the picture's own line says it, and
   `flick=down` there reads "Inspect Image: Blue verification square" and then "Activate".
10. At the end of the book (`activate=Contents,activate=Chapter three,wait=2` and scroll
    steps until Scroll Forward is dimmed) put the cursor on a line near the last, with
    `touch=p086w36` on an iPad at 23 points or `point=0.5:0.6` on an iPhone, and move
    forward past the last line, back and forward again (`forward=12,backward=8,forward=10`
    on the iPhone): the book's last line, "Vertical scroll bar", then the item below the
    reader, where VoiceOver stays; back, the scroll bar, the last line and the lines above
    it in order; forward, the same lines, the scroll bar and the item below. The first line
    on screen straight after the scroll bar, or a jump up the screen one move after coming
    back to the last line, is the failure of
    [#342](https://github.com/vocaro/EPUBLib/issues/342). Then touch the bar itself, at the
    reader's right-hand edge (`point=0.955:0.6` on an iPhone 17 Pro, `point=0.982:0.6` on
    an iPad upright): `backward=4` reads the last line listed and the lines above it, where
    it read "Bookmark", and `forward=1` from the bar reads the item below the reader. Do
    the same after two scroll steps, where the last line listed is the last in the reader's
    view. Nothing scrolls as the cursor goes to the bar: at the end of the book the bar reads
    100%, where it read 99% while the view went back for it. `flick=down` on the bar scrolls
    by a page and reads the new value.

Drive at least one session with `flick=right*20` and `flick=left*30` in place of `forward`
and `backward`: those are VoiceOver's own gestures for the next and previous item, where the
others are the test service's moves. They take about six seconds each under XCTest.

## Links

On a Mac a link is found, named and followed through elements the reader gives VoiceOver
([the native viewer](native-viewer.md), "Links for VoiceOver on Mac"). VoiceOver's own part
was heard first, in AppKit's text view (`-VerificationPlainText`), and a session on links is
read against it:

- Moving by word or by line, and in Read All, VoiceOver says the words of a link of words and
  nothing of the link. It announces an element given as a character's attachment, so a link
  that is a picture or a hidden label is said as "hyperlink" and its name there.
- `nextlink` moves through the links of the text on screen. VoiceOver says the name and
  "hyperlink", then the hint "You are currently on a hyperlink, inside of a text area. To
  click this link, press Control-Option-Space", of which the probe records the first 64
  characters. Past the last link it begins again with the first. `previouslink` went
  forward too, in AppKit's own elements as in the reader's (macOS 27.0.1).
- `activate` follows the link under the cursor. With the cursor on a word it follows a link
  on that word's line, the word's own or not, and on a line without a link it does nothing.
  AppKit's own text view does the same.
- `rotor` has no list of links. For the reader's text it lists the book's headings.

`ax:links` prints what the text gives for its links before anything is said: each link once
as a `CHILD`, called by its words and never by U+FFFC, with `AXPress` among its actions; and
in the `LINK` lines the same element as the link of its characters and, where the link has an
attachment, a link element as that character's attachment. The text's headings are `CHILD`
lines too, `AXHeading` with the heading's words as `LABEL`, each where it stands among the
links: those on the page, and in continuous scroll those on screen and the next one below. `ax:follow=WORDS` presses a link
without VoiceOver. `ax:caret=WORDS` before `ax:focus in` starts VoiceOver on a link's line, so
a few `right` steps reach it. After a link is followed the transcript has `AXValueChanged`
with the page that holds the target, in the fixture the one with "Link target reached".

What VoiceOver says of a link as it reads depends on a setting: VoiceOver Utility, Verbosity,
Text, "When encountering a link/attachment", which can be Speak, Change Pitch, Play Tone or Do
Nothing. A transcript holds speech and neither tones nor pitch, so every hosted run reads the
setting and writes it to `runner.txt` as `LINK VERBOSITY`. On the runner it is Speak, the
setting of a Mac whose VoiceOver has never been configured. The workflow's `links` input
chooses another. `scripts/voiceover-link-verbosity.swift` does both through VoiceOver
Utility's own window and refuses to run anywhere but on a hosted runner. Do not write the
setting with `defaults`: a `com.apple.VoiceOver4/default` domain written before VoiceOver had
ever run left it silent for the whole run, `ERROR 3` after every key.

## Hosted Mac sessions

The same reader, probe, observer and runner script record real VoiceOver speech on GitHub's
hosted `xcode-27` runner. A session there takes over no workstation, and the standard runner
costs nothing in this public repository. It is acceptance evidence for the Mac, under the
same rules as a workstation session; see [Acceptance and evidence](#acceptance-and-evidence).
The [Mac VoiceOver workflow](../.github/workflows/voiceover-mac.yml) builds the reader at a
ref, runs one or more sessions and uploads their transcripts.

The runner is shared. GitHub runs five macOS jobs at a time for the whole account, for the
runs of every agent's session together, and its queue has no priorities. So one run holds
every session a piece of work needs, whatever their window widths, text sizes, flows and
launch arguments, and it is started through `scripts/hosted-run.py`, which looks at what is
running first; [Sharing the runner](#sharing-the-runner) has the rules. The workflow starts
only by hand:

```sh
python3 scripts/hosted-run.py voiceover-mac.yml -f width=600 -f text_size=17 \
  -f steps='ax:next ax:lines ax:focus in line nextline ; ax:next ax:focus in lastword line nextline
            width=1100 text_size=23 ax:next ax:lines ax:focus in line nextline
            flow=scrolled ax:next ax:next ax:focus in line nextline'
gh run watch RUN_ID --exit-status
gh run download RUN_ID --name voiceover-mac-transcripts --dir .build/voiceover/hosted/RUN_ID
```

That is four sessions in one run: two in a window 600 points wide at 17 points, one in a
window 1100 wide at 23, and one in continuous scroll. The script takes the `-f` inputs of
`gh workflow run`. It checks the steps as the runner would and prints each session with its
settings, starts the run unless the branch already has its share in flight, and prints the
run's number. It starts the run from the branch checked out, or from the one `--ref` names.
That branch's workflow file is used, and that branch is built unless the `ref` input names
another one. The inputs, all optional:

- `ref`: a branch, a tag or a full commit SHA whose reader and probe are built. The runner,
  observer, session and link-setting scripts still come from the `--ref` branch, so a commit
  older than this workflow can be heard, and two commits compared, with one harness.
- `steps`: the steps `scripts/run-voiceover-mac.py` takes, quoted as on a command line, as in
  `"activate=Next Page"`. A `;` or a line break starts another session. Each session gets a
  fresh reader, and `ax:width` with its width before its own steps. Left empty, one
  session checks a page boundary: the left column's entry line and two lines down, a Next Page
  activated through VoiceOver, and the new page's entry line and second line. The entry line
  after the turn must be the page's first: with the fault of
  [#337](https://github.com/vocaro/EPUBLib/issues/337) it is the third. The session brings
  VoiceOver to the column by `ax:focus=search ax:focus=0`, without which it can pass on a
  reader that has the fault.
- `width` and `text_size`: the window width and the launch text size in points, 1100 and 23
  unless given, for a session that gives none.
- `flow`: `paginated`, or `scrolled` for [continuous scroll](#continuous-scroll), which needs
  its own steps, for a session that gives none.
- `launch`: further launch arguments of the reader, quoted as on a command line, for a
  session that gives none. `-SampleHref OPS/labels.xhtml` opens the book at a section, with
  no page turns to reach it, and `-VerificationBook paragraphs` opens the other book.
- `links`: how VoiceOver announces a link or an attachment in text: `Speak`, `Change Pitch`,
  `Play Tone` or `Do Nothing`. `Unchanged`, the default, leaves the runner's own setting. See
  [Links](#links). It is set once, before the first session, so it is the one thing sessions
  of a run cannot differ in.
- `pause`: the runner's `--pause`, 5 seconds unless given, for a session that gives none.
- `advance_after`: the runner's `--advance-after`, for a session that gives none. Empty keeps
  the fixed pause.

A session can open with settings of its own, in any order before its first step: `width=600`,
`text_size=17`, `flow=scrolled`, `"launch=-SampleHref OPS/labels.xhtml"`, `pause=3` and
`advance_after=0.5`. `launch=` with nothing after it is no further argument, and
`advance_after=` the fixed pause. The inputs of those names are what a session has when it
gives none, so one run holds sessions that differ in them. A setting that follows a step, is
given twice or has a value it cannot have is refused before anything is built, and a session
of settings alone is the page-boundary session with them. The job's log, `sessions.txt` and
the run's summary page give each session's settings before its outcome, where the run's name
gives the `width` and `text_size` inputs only:

```text
Session 3: 600 wide at 17 points, scrolled, 4 s pause; completed (exit 0) in 45 s; mac-20261013-042246-037894.transcript.txt; -SampleFlow scrolled -SampleFontSize 17 --pause 4 ax:width=600 ax:next ax:next ax:focus in line nextline
Session 4: 1100 wide at 30 points, paginated, 3 s pause, next key 0.5 s after a phrase; completed (exit 0) in 29 s; mac-20261013-042347-959280.transcript.txt; -SampleFlow paginated -SampleFontSize 30 --pause 3 --advance-after 0.5 ax:width=1100 ax:next ax:lines ax:focus in line nextline
```

A job has twenty minutes and a session at most 300 seconds, the runner script's limit.
Preparing the runner and building take about two minutes and the boundary session about three
at the fixed pause, so a run of that one session has uploaded its transcript about five minutes
after it has a runner. A session that could not end three minutes before the job's limit is
reported as not run, and the job fails. That leaves the sessions of a run about fifteen
minutes between them: four of the boundary session's length, or a dozen short ones. On
2026-10-13 four sessions of five or six steps, each with a width, text size, flow or pause of
its own, took 239 seconds of a job of 5 minutes 50 seconds, the build 82 of them (run
38344667427); as four runs they would have built four times, on four runners. Nothing cancels
a run but `gh run cancel RUN_ID`: a second run from a branch does not replace its first,
whatever their inputs, so cancel a run that a newer one makes useless.

With `advance_after` set to `0.5`, stepping took about a quarter of the time in four pairs of
sessions, and 95 of 97 keys recorded the same first phrase as at the fixed pause. The hint that
follows a move is cut short, and a phrase VoiceOver repeats is not recorded again. It suits
exploring and walks across controls. A transcript offered as acceptance evidence is recorded
at a fixed pause; see [Acceptance and evidence](#acceptance-and-evidence).

The job fails unless every session exits 0. `sessions.txt` in the download gives each
session's settings, outcome, transcript and command: 124 means the deadline was reached, 125
that the runner script stopped the session, 2 that it refused the steps, and 126 that VoiceOver
would not switch back off after it ("VoiceOver not restored"). Such a session still has its
transcript, with the reason in a `NOT_RESTORED` line, and the sessions after it in the job
begin with VoiceOver already on and leave it on. The download also holds a
`mac-STAMP.transcript.txt` for each session in order, `runner.txt` with the commit, the runner
image and its version, macOS, Xcode, System Integrity Protection, the screen and VoiceOver's
[link setting](#links), the observer, `xcodebuild` and build logs, and a screenshot of the
runner's screen at the end. The job's log
prints each transcript, and the script writes each session's steps and speech to the run's
summary page, under its settings and outcome. The artifacts expire after five days; copy what
must be kept. A failed job also uploads
`voiceover-mac-result-bundles`, 100 MB for four short sessions, and adds
`banner-and-dictation.log` to the transcripts: the banner's starts and anything from Dictation
in the system log. A stopped session's bundle has no `Info.plist`, so `xcresulttool` cannot
open it, but its log archive opens with `log show --archive`.

A hosted session differs from one on a workstation:

- The screen is 1920 × 1080 and the reader's window 850 points high, where the recorded
  workstation sessions have 882. A full column holds one line fewer, 17 at 23 points; the
  column widths are the same. Take every boundary from the session's own `STATE` and `LINE`
  lines.
- macOS and Xcode are the image's, recorded in `runner.txt`: on 2026-10-12, macOS 27.0.1
  (`26A434`) where the recorded workstation sessions used 27.0 (`26A428`).
- Nobody listens and nothing is stepped by hand: a step list goes in and a transcript comes
  out. Whatever needs a person's ear or a decision between two steps needs a workstation.
- The build is signed ad hoc, without a team.
- The three-processor runner is slow to start the reader. Seven of 26 sessions opened with
  "VoiceOver on VoiceOverVerificationMac not responding"; every later phrase was the reader's.
- `xcode-27` is a public-preview image. Its privacy grants, its automation mode without
  authentication and the behaviour of XCTest's banner belong to the image version and can
  change; `runner.txt` names the version.

The workflow prepares the runner before it builds. Each step is there for a failure seen
without it:

1. `defaults write com.apple.VoiceOverTraining doNotShowSplashScreen -bool true`: a Mac that
   has never run VoiceOver opens its welcome dialog first. No session was tried without this.
2. `defaults write com.apple.HIToolbox AppleDictationAutoEnable -int 0`: every VoiceOver
   command presses Control, and after about four of them "Do you want to enable Dictation?"
   took the VoiceOver cursor.
3. `launchctl bootout gui/$(id -u)/com.apple.dt.AutomationModeUI`: XCTest's Automation
   Running banner is a system launch agent with `KeepAlive` for as long as
   `/var/db/com.apple.dt.automationmode/automation-enabled` exists, and `EnablePressuredExit`.
   On this image it is killed and restarted about every ten seconds during a UI test, and
   VoiceOver moves to an instance that survives and stays there. That lost three sessions of
   seven. `launchctl disable` does not stop the banner. Unloading the agent works only because
   the runner has System Integrity Protection disabled, which `runner.txt` records. A Mac with
   it engaged refuses and changes nothing: "Boot-out failed: 150: Operation not permitted
   while System Integrity Protection is engaged". The job fails if the launch agent is still
   loaded, and the runner script stops any session in which VoiceOver names the banner.
4. `displayplacer` sets the screen to 1920 × 1080: the image's 1024 × 768 screen held the
   window to 1024 × 674, and `ax:width=1100` reported success without resizing it. The job
   fails if the screen is not that size afterwards.
5. `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` for the build: an ad hoc signature needs no team,
   certificate or secret, and the image's own privacy grants were enough for the UI test.
6. The runner script reads a missing `voiceOverOnOffKey` as off when no `VoiceOver` process
   exists, which is the state of a Mac that has never run VoiceOver.
7. `scripts/voiceover-link-verbosity.swift` opens VoiceOver Utility to read, and when the
   `links` input asks to choose, how VoiceOver announces a link ([Links](#links)). Written
   with `defaults` instead, the setting left VoiceOver silent.

These commands change settings of the logged-in user and belong on a disposable runner. Do
not run them on a workstation, where the third does nothing in any case; the workflow's first
step refuses a machine that is not GitHub's. Keep `runs-on: xcode-27`: a larger runner, such
as `xcode-27-xlarge`, is billed even in a public repository. To see what a run cost, expect
`"billable": {}` from:

```sh
gh api repos/vocaro/EPUBLib/actions/runs/RUN_ID/timing
```

### Sharing the runner

GitHub runs five macOS jobs at a time for the whole account, on its Free, Pro and Team plans
([its limits](https://docs.github.com/en/actions/reference/limits)). The VoiceOver runs of
every agent's session draw on those five, and nothing else runs there
([notes for agents](../AGENTS.md#the-hosted-runner)). A run beyond the five waits for a
runner. The queue has no priorities: runs get a runner in the order they were started,
whatever they are for.

While fewer than five jobs ran, a job started within ten seconds. On the evening of
2026-10-12, when the unit tests ran there too, all five were busy for hours and a job waited
a median of 13 minutes for a runner and 75 at worst. Four runs in five were VoiceOver runs
even so, and a single branch started four to nine of them within 90 seconds on sixteen
occasions, each on a runner of its own with a build of its own.

So a run is started with `scripts/hosted-run.py`:

```sh
python3 scripts/hosted-run.py
python3 scripts/hosted-run.py voiceover-mac.yml -f steps='width=600 text_size=17 in line ; in line'
```

With no workflow it prints how many runs are on a runner and how many wait, then each run in
flight, and starts nothing; `gh run list --status in_progress` and
`gh run list --status queued` list the same runs. With the workflow it prints the two counts
and starts the run, unless a rule below is against it: then it says why, starts nothing and
exits with status 1. It sees this repository's runs only. The rules, with what the script
does about each:

- Look at what is running and waiting before you start a run. The script prints it each time.
- Put the sessions you need into one run. Each can have its own window width, text size, flow
  and launch arguments, so that step lists that differ in them share one run, one build and
  one runner. The script checks the steps as the runner would, before anything waits for a
  runner, and prints each session with its settings.
- Keep at most two runs in flight for a branch, and one while any run is waiting for a
  runner. The script starts no run beyond that and lists the branch's runs.
- Cancel a run as soon as it is no longer needed, with `gh run cancel RUN_ID`. Nothing else
  cancels one.

`--force` starts a run the script would refuse; a slow queue is not a reason for it. The
script also says when GitHub's copy of the branch is not the commit checked out, because a
run uses what is pushed.

## Physical iPhone and iPad

Choose each connected device explicitly and run the native probe on it:

```sh
TEST_RUNNER_VOICEOVER_STEPS='visible,touch=Page boundary,read,activate=Next Page,visible,touch=word,read' \
xcodebuild -project Examples/VoiceOverVerification/VoiceOverVerification.xcodeproj \
  -scheme VoiceOverProbeIOS -destination 'platform=iOS,id=YOUR_DEVICE_ID' \
  -derivedDataPath .build/voiceover/ios -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$VOICEOVER_TEAM_ID" \
  -only-testing:VoiceOverProbeIOS/VoiceOverProbe/testCaptureNavigation \
  -resultBundlePath .build/voiceover/iphone-session.xcresult test
```

Use a new result-bundle path for each run, including the iPad. The native service enables
VoiceOver if necessary and restores its original state on normal test completion; the
transcript's `voiceOver` line says which. Put a deadline around device runs and independently
check the device state afterward, especially after cancellation. A user must enter any
required XCTest UI Automation passcode directly on the device. Never collect it in logs or chat.

A probe that fails or is stopped part way leaves VoiceOver on, on a device its owner then
picks up. Read the state from the Mac and switch it off there:

```sh
xcrun devicectl device info voiceover --device YOUR_DEVICE_ID
xcrun devicectl device settings voiceover --device YOUR_DEVICE_ID --disable
```

Count the start into the deadline. On a busy Mac `xcodebuild` took nearly five minutes to
begin a session on an iPhone whose steps then took one, and a deadline of five minutes
stopped it in the middle. While VoiceOver is on it also reads whatever else the device shows:
a notification that arrives, or the app that was in front when it came on. Such a phrase
takes the place of the one a step should have recorded. Its text is the device owner's and
not the book's, so leave it out of every record, and a screenshot that shows it with it.

The probe launches the reader and performs the comma-separated steps, recording VoiceOver's
phrase after each, and ends with `finished`: a transcript without that line stopped early.
Without `TEST_RUNNER_VOICEOVER_STEPS` it reads forward from the first item.

- `read`: move forward until VoiceOver stays on the last item. There it repeats that item's
  phrase, but so does a second item with the same label. One move back tells them apart: from
  the last item it reaches the item before, and a move forward returns. Where that settles
  nothing, because the item before says the same or VoiceOver does not move back, three more
  repeats end the read, as three did before. A `read` line says which way it ended.
- `forward=COUNT`, `backward=COUNT`: that many moves to the next or previous item, where
  `read` would go on through a whole book in continuous scroll.
- `visible`: the window size and each column's first and last numbered lines as XCTest sees
  them, to compare with the speech. Lines listed above or below the window, as continuous
  scroll lists them, are counted apart.
- `touch=LABEL`: touch the first item whose label begins with LABEL. Under VoiceOver a touch
  moves its cursor there; `touch=word` is the first numbered line.
- `activate=LABEL`: touch the item, then double-tap, which is VoiceOver's activation. The
  probe goes on once the screen has changed and held still for half a second, after two
  seconds at most, and a `settled` line says which.
- `point=X:Y`: touch a place in the window, as fractions of its width and height, whatever is
  listed there.
- `flick=down`, `flick=up`: one finger steps through the rotor. With the cursor on a line of
  a page it offers the line's actions, Next Page first; `doubletap=LABEL` on that same line
  then performs the chosen one without moving the cursor. After the last of an item's actions
  VoiceOver says "Activate Default" and starts again, so a list has been heard whole once
  that phrase comes. A line with no action, as plain
  text is in continuous scroll, leaves the rotor on its own setting, and the flick steps by
  that. On an iPhone in landscape only the
  upward flick registered, which reaches the same actions.
- `flick=right`, `flick=left`: VoiceOver's next and previous item; `flick=right*12` repeats it.
- `rotor=LABEL`: two fingers turned on the glass, which turns VoiceOver's rotor, repeated
  until VoiceOver's phrase begins with LABEL, thirty turns at most: `rotor=Headings`.
  `flick=down` and `flick=up` then move by that setting, heading to heading. Without a label
  it turns the rotor once. Turn it after the touch that places the cursor: a touch on an item
  with actions put an iPad's rotor back on Actions. A turn of one size moved a simulator's
  rotor one setting in some sessions and three in others, which went round past Headings, so
  the turns are of several sizes. On a physical iPad the first turn reached Headings; on a
  physical iPhone no turn moved the rotor, and the step ends in `MISSING`.
- `rotate=landscape`, `rotate=portrait`: an iPad shows two columns in landscape and one in
  portrait. The probe waits for the screen as after `activate`, three seconds at most. End a
  session in the orientation it started in.
- `listen=SECONDS`: every phrase VoiceOver speaks in that time, each as a `heard` line, where
  another step records the one phrase standing when it ends. Use it after a step that makes
  VoiceOver speak by itself, as a page turn under its cursor does.
- `wait=SECONDS`, and `screenshot`, attached to the result bundle: what is on the glass,
  independent of every accessibility snapshot.

`TEST_RUNNER_VOICEOVER_FONT_SIZE` sets the launch text size, `TEST_RUNNER_VOICEOVER_FLOW=scrolled`
opens the book in continuous scroll, `TEST_RUNNER_VOICEOVER_HREF` opens a section other than
the first (`OPS/labels.xhtml`) and `TEST_RUNNER_VOICEOVER_BOOK=paragraphs` opens the book of
ordinary paragraphs. `TEST_RUNNER_VOICEOVER_OFF=1`
leaves VoiceOver off, so the same steps are plain touches: use it to tell a VoiceOver failure
from one of the reader's own. The probe stops when the reader is no longer in the foreground.
Another session's tests on the same device bring their own app forward or switch VoiceOver
off; discard such a run.

XCTest cannot perform VoiceOver's three-finger scroll, and its synthesized hardware keys
(Control-Option-Space, Option with an arrow) did not reach VoiceOver on an iPad. The probe
turns pages by activating the page buttons or a line's Next Page action. A transcript that
begins in an editing field, with the keyboard's keys after the page, is not a reading-order
result. Use physical-device sessions for acceptance.

## Simulators

`scripts/run-voiceover-simulator.py` runs the same probe on simulators of its own, with no
device, no Simulator window and no sound. It is a quick check of what VoiceOver reads, not
acceptance evidence:

```sh
python3 scripts/run-voiceover-simulator.py
python3 scripts/run-voiceover-simulator.py --device iPad-Air-13-inch-M4 --font-size 23 \
  --steps 'rotate=landscape,visible,touch=Page boundary,read,rotate=portrait'
```

The runner generates the fixture and project if they are missing or stale and builds the probe
once; a simulator build needs no signing team. It creates an iPhone 17 Pro and an iPad Air
13-inch (M4) on the iOS 27.0 runtime (`--device` and `--runtime` choose others), boots them
with `simctl` alone, sets each one's volume to 0 and runs one `xcodebuild
test-without-building` for each at the same time, under `--timeout`. It deletes its simulators
however the run ends, also when it is terminated, and never boots, changes or deletes one it
did not create. `--steps`, `--font-size`, `--flow scrolled`, `--href OPS/labels.xhtml` and
`--voiceover-off` are the probe's settings above. Each simulator gets `simulator-TYPE-STAMP.transcript.txt` beside its
log and result bundle in `.build/voiceover/results/`: the device, revision and steps, the
probe's lines, then the result, with VoiceOver's state and the volume as `devicectl` reports
them. The exit status is 0 only when every probe ran all its steps and passed, VoiceOver is
off again and no simulator lost its mute.

Four things went wrong in the first runs, and the runner and probe now allow for each:

- **Sound.** A simulator's VoiceOver speaks through the Mac's own output device, at volume
  60 unless told otherwise. Nothing runs until the volume reads 0, and the runner reads it
  again every second and at the end. A simulator whose `backboardd` restarts comes back at 60
  within six seconds, VoiceOver still on: it aborted once in some thirty rotations, in Metal,
  with VoiceOver on. The runner then mutes the simulator again and the transcript has an
  `UNMUTED` line. A check that gets no answer in five seconds is a `VOLUME gave no reading`
  line instead: a few in most runs, while xcodebuild starts its test, and two thirds of them
  on a saturated Mac. This reads a setting. Nothing listens to the Mac.
- **A VoiceOver that is on and silent.** On a newly booted simulator VoiceOver's first start
  took 40 to 60 seconds, by its own log waiting for the voice database, while XCTest's
  `enable()` returned in a few. On a Mac other sessions had saturated it took 170, and the
  default `--timeout` of 300 seconds then passed before the probe had finished. Until
  VoiceOver is up, touches reach the reader as plain touches and every move fails with
  "Failed to send moveForward command". The probe waits for VoiceOver's first phrase, three
  minutes at most; the `voiceOver` line then says `silent for its first 44 s`. Switching
  VoiceOver off and on again did not help: one session stayed silent through three starts.
- **An xcodebuild that does not end.** After a test that recorded any issue, a warning
  included, xcodebuild runs `simctl diagnose --timeout=600` and waits for it. A rotated iPad
  logs such a warning in a probe that passes ("Support for all orientations will soon be
  required"), and xcodebuild then ran on for 22 seconds, 30 seconds, a minute, twice more than
  five minutes, when it was stopped, and once the collector's whole ten. The runner passes
  `-collect-test-diagnostics never`, with which the same run ended within a second of its
  probe. If xcodebuild has still not ended `--exit-grace` seconds after the probe, the runner
  stops it and its collector, takes the speech from xcodebuild's output or from the
  unfinished result bundle (`Staging/*/Diagnostics/**/StandardOutputAndStandardError.txt`),
  whichever holds more, and says so in a `STOPPED` line.
- **Other sessions.** XCTest fails a UI test when a process it calls critical crashes while
  the test runs. One probe failed with "Critical process xctest crashed" while other sessions'
  unit tests were running on the Mac; its own transcript was complete. `FAILURE` lines give
  XCTest's reasons.

A simulator session establishes what VoiceOver reads and in what order: each line, the end of
the page, both columns of an iPad's landscape spread, and the page after a turn. It does not
establish that VoiceOver can activate anything. On these simulators a double tap under
VoiceOver does not perform the cursor item's action. The reader receives one plain touch
where the double tap landed, about a quarter of a second later: with the cursor on Next Page
and the double tap on the heading, the touch arrived on the heading and the page stayed.

- `activate=Next Page` turns the page in portrait because that touch lands on the button it
  names. The page that follows is real, and so is VoiceOver's reading of it. That VoiceOver
  activated the button is not shown.
- In landscape the touch arrives a quarter turn away, at (height − y, x) for a double tap at
  (x, y): on the iPad at (890, 43) for the button at (43, 134), where nothing is. The page
  does not turn. On the iPhone it lands in the search field and brings up the keyboard.
- The rotor offers a line's actions and speaks them (`flick=down` says "Next Page"), and
  `doubletap` performs none: the touch goes to the line, and neither the reader's action nor
  its `accessibilityActivate` is called. Turning the rotor and moving by it need no
  activation and do work: `rotor=Headings` and a flick moved VoiceOver, and the reader with
  it, to the book's next heading.
- XCTest's Control-Option-Space reaches VoiceOver, whose log names it Activate, and nothing
  reaches the reader. Control-Option with an arrow does move the cursor, in 0.4 seconds.

With VoiceOver off the same touches turn the page in both orientations, and on physical
devices VoiceOver performs every one of these
([iPad and iPhone verification](issue-28-voiceover-devices.md)), so the difference is the
simulator's and not the probe's or the reader's. Page actions, the rotor and turns in
landscape need a device. To read a later landscape spread on a simulator, turn pages in
portrait and then rotate: the reader keeps its place.

A move costs half a second and a touch about five and a half, most of it XCTest waiting for
an event that VoiceOver keeps from the reader. The end of a `read` costs 3.3 seconds and an
`activate` or `rotate` a little over one after the gesture. The simulators are not the
devices of the record: an iPhone 17 Pro shows 402 × 874 points and its pages hold fewer lines
than the iPhone 17 Pro Max's. In landscape the sample's control strip stacks and leaves its
reader one line at 17 points, so `visible` finds no numbered line on the first spread. All of
this is the iOS 27.0 runtime. The 27.1 runtime of Xcode 27.1 offers only the iPhone Duo and
was not compared.

## Acceptance and evidence

For each device, exercise supported one- and two-column layouts, normal and larger text,
and a text-size change while the reader is open. Record the build revision, OS/Xcode versions,
device, window size/orientation, font size and visible first/last numbered words.

For the Mac, a speech session run on the hosted `xcode-27` runner is acceptance evidence, as
one on a workstation is. Record its runner image and image version, such as `xcode-27-arm64`
20261006.0244.1, beside the OS and Xcode versions; `runner.txt` in the run's download has all
three, and the job's "Set up job" log prints the image. Everything else here applies to it
unchanged. A hosted session that completes is no more an acceptance result than any other:
read its transcript against the visible text. The iPhone and iPad still need physical devices.

Sessions that show a change by what VoiceOver said before and after it are recorded on the
same main. Merge main into the branch first, and take as "before" a commit that holds main
and nothing of the change but its fixture. Main gains commits within the hour, and one that
landed between two such recordings changed what VoiceOver did in continuous scroll, which
was then taken for the change's own. A second worktree at that commit keeps the branch free;
the probe built there in under two minutes.

Record a Mac transcript offered as evidence at a fixed pause, the runner's default, on a
workstation or hosted. `--advance-after` is for exploring: it cuts short whatever follows a
key's first phrase, and in the paired sessions it once recorded a control's hint in place of
its name. Run a failure first seen with it again at a fixed pause before reporting it.

1. Capture the first spoken line upon entering each column, before advancing. The first
   numbered word must match that column's first visible word.
2. Read successive lines in logical column order. Reach the last visible word, then attempt
   another line; hidden continuation must not become reachable.
3. Activate Next through VoiceOver and verify that the next visible/spoken word is exactly
   the successor of the prior page's last word, without duplication. Check Previous as well.
   On an iPhone and iPad also turn the page from a line: with the cursor on a line of the
   page, choose Next Page in the rotor (`flick=down`) and perform it (`doubletap=LABEL`).
   VoiceOver then reads the first line of the page shown by itself (`listen=4`), a
   screenshot shows its cursor on that line, and each move forward reads the next line of
   that page. Do it from the first page and from a line in the middle of a later page,
   whose lines hold the same characters as the next page's, and with Previous Page.
4. Confirm heading order, the link's label/action and the image's spoken label.
5. Resize or change typography, wait for the new layout, and repeat the boundary and ordering
   checks. On Mac verify corresponding value-change notifications and fresh text values.
6. On the hidden-labels section, in pages and in continuous scroll: VoiceOver reads "Parked
   title heading" and "By the parked author." and then "Shown opening words.", with nothing
   for the image between them, which has an empty `alt`; "Clipped words in the line."
   between the two shown sentences, and "Parked link to the target" as a link before "Shown
   last words."; it never reads "Words nobody is given." or "Words kept from assistive
   technology."; and a screenshot shows the image and none of the hidden words. On the section with a
   hidden heading over a table, opened in continuous scroll, VoiceOver moving into the text
   meets "Parked table heading" before the table's first row, and the view does not move.
   In pages and in continuous scroll alike, each row of that section's tables is one item
   where it stands, read as its cells' words and not as an image: "First cell Second cell"
   and "Third cell Fourth cell" after the heading, "Fifth cell Sixth cell" and "Seventh cell
   Eighth cell link" between "Line 02 after the table." and "Line 03 after the table.". No
   cell is an item by itself, and moving back gives the same items in reverse. On the last
   row the rotor offers Select Table Text for its two cells and Follow Table Link: Eighth
   cell link, which opens the first section at "Link target reached"; a line beside the
   tables offers none of them.
7. On the section of pictures, in pages and in continuous scroll. VoiceOver stops between
   "Undescribed picture" and "stands here." and says that an image is there, with no name.
   It reads "Decoration" and "passed over." with nothing between them, and the same for
   "Titled decoration". After "Bare jump:" it stops on a link that is an image without a
   name, and activating it goes to "Link target reached". It reads "Jump with decoration"
   and "Described jump" as links, the second also as an image, and "Square with a title of
   its own" as an image between "Titled picture" and "stands here.". It never says "Book
   image", and says "Square with a title of its own" once.
8. On the section of scenes, on an iPhone and iPad, in pages and in continuous scroll.
   VoiceOver stops between "First scene ends." and "Second scene starts." and says
   "Separator", and never "Image". It says the same before "Words after an ornament.",
   where the rule has `role="presentation"`, which the reader does not read. On the page
   that holds a rule alone it says "Separator" and nothing else in the text, and Next Page
   from there shows "Last words of the scenes.". On a Mac, in a window 600 points wide at
   17 points, open the reader at the section (`"launch=-SampleHref OPS/scenes.xhtml"`).
   Moving by line VoiceOver says "Separator" between "First scene ends." and "Second scene
   starts." and again before "Words after an ornament."; moving by word a rule is one stop
   that says the same; and `readall` from the page's first word says it in both places. On
   the page that holds a rule alone, one `ax:next` step on, it says "In text Separator" on
   entering and "end of text" on the next line. In continuous scroll, where thirty
   `ax:next` steps from the start of the book and `lastword` put VoiceOver on "scenes.", it
   says "Separator" on each of the three lines between "Last words of the scenes." and
   "First scene ends.". No transcript has "splitter", "collapsed" or "image" at a rule.
9. Headings. On an iPhone or iPad VoiceOver says "Heading" after a heading's words, shown or
   hidden, and reads a heading that takes several lines as one item. With the rotor on
   Headings (`rotor=Headings`, turned after the touch that places the cursor), `flick=down`
   moves to the next heading on the page or screen and then to the next one in the book,
   turning the page or scrolling to it, and `flick=up` goes back the same way; `visible`
   after a move shows the page or screen the reader went to. Past the book's last or first
   heading VoiceOver says "Heading not found". Wait a few seconds after the book opens
   (`wait=8`): a chapter not built yet ends the search. On a Mac `nextheading` moves
   VoiceOver to the book's next heading, to "Heading not found" past the last, and the view
   shows the heading. In continuous scroll, and in pages where the heading is on the page,
   VoiceOver reads the heading's words. In pages where it is on another page the reader
   turns to it and VoiceOver reads that page from its top: `line` then reads the heading,
   and `ax:lines` shows the page with the insertion point on the heading's line. `rotor`
   opens on the Heading menu, which lists the whole book's headings in both flows, each by
   its words and level, and `listchoose` moves to the one named, turning the page for it.
   From a page in the middle of the book, with VoiceOver's cursor resting on the column
   (`ax:focus=0` without `in`), `nextheading` goes to the first heading after the top of
   that page, not to the book's first. From a link (`nextlink` first) `nextheading` says a
   heading's level and then its words, "heading level 2 Link target reached": in continuous
   scroll the book's next heading after the link, in pages the next one on the page, or the
   page's first when none follows the link. One `right` puts VoiceOver back in the text, and
   `nextheading` from there goes on through the book. `rotor` from a link has the same
   Heading menu. VoiceOver opens its rotor on the menu it showed last, so a session that
   has gone to another menu with `listright` starts the next one there.
10. Links on a Mac, in pages and in continuous scroll, with VoiceOver's link setting at Speak
    ([Links](#links)). `ax:links` lists each link on screen once as a `CHILD`, by its words:
    "Verification link" on the first page, "Parked link to the target" on the hidden-labels
    section, and "image", "Jump with decoration" and "Described jump, image" on the section
    of pictures. None is called U+FFFC. `nextlink` moves to each in turn, VoiceOver says its
    name and "hyperlink", and `activate` from there shows the page with "Link target
    reached". Moving by word and by line VoiceOver says "hyperlink Parked link to the
    target", "hyperlink image" after "Bare jump:", "hyperlink" before "Jump with decoration",
    and "hyperlink Described jump, image". It reads "Verification link." as its words and
    nothing else, and `activate` with the cursor on either word follows that link too.
11. Actions, on an iPhone and iPad. A line is offered what is in it and nothing else. On a
    page, with the cursor on a line of plain text, `flick=down` reads "Next Page", "Previous
    Page" and "Activate", and then "Next Page" again: each once, and no picture or link that
    stands elsewhere on the page. On the picture's own line it reads "Inspect Image: Blue
    verification square" after the two. In continuous scroll VoiceOver says no "Actions
    available" after a line of plain text or a link, and `flick=down` there reads no action;
    the picture's line says it and offers the inspection alone. A reader that offered more
    said, on any line of continuous scroll, "Previous Page", "Next Page", and the book's
    links by their words.
12. What each kind of item offers, on an iPhone and iPad, on the section "What each line
    offers", which shows them all at once. With the cursor on an item, step through the rotor
    (`flick=down`) until VoiceOver says "Activate Default": what came before it is everything
    the item offers. In pages "Plain words above.", the link "Lone jump" and "Plain words
    below." offer Next Page and Previous Page and no more; "Square with words" offers those
    and Inspect Image: Square with words; the picture without words, one move forward from
    "Nameless picture", those and Inspect Image; and the table's row those, Select Table
    Text: Left cell, Select Table Text: Right cell jump and Follow Table Link: Right cell
    jump. In continuous scroll each offers the same without the two page turns, so a line of
    words and the link offer nothing: the rotor has no Actions setting on them
    (`rotor=Actions` ends in `MISSING`). No item offers a picture or a link that is not its
    own, or "Verification link", which is in the book's first section. On a device, choose
    Inspect Image on a picture and double-tap, and the inspector opens; choose Next Page on a
    line of a page and double-tap, and the page turns.
13. Attachments in a table cell, on a Mac, in a window 600 points wide at 17 points, with
    the reader opened at the section of entries (`"launch=-SampleHref OPS/entries.xhtml"`).
    Three `right` steps from the text's first line reach the table's first row, and `in`
    there says "In Table row group 2 items text Upper part closes." and then "Separator".
    Inside that cell VoiceOver says "Upper part closes.", "Separator", "Lower half opens." by
    line and with `readall`, and by word "Separator" between "closes." and "Lower". In the
    cell beside it: "Sum x squared image stated.", and "x squared image" by word. In the
    second row: "Drawn Blue entry square image shown.", and "Blue entry square image" by
    word; then "Parked entry words. Seen entry words.", the hidden label first. In the
    third: "Ornament passed.", with one step by word that has no phrase, for decoration;
    then "Undescribed image stands.", and "image" by word. In the fourth, whose first cell
    holds a table: "Inner one Inner two". After the table, in the page's own text, "Beyond
    them y cubed image ends.": a formula is read in a cell as it is outside one. In
    continuous scroll the first row's cell reads the same. A reader whose cells keep none of
    their elements says nothing in each of those places: a phrase with nothing in it by line
    and with `readall`, and a step with no phrase by word.
14. Restore all original VoiceOver/scripting settings and independently verify restoration.

Keep logs and `.xcresult` bundles under `.build/voiceover/`. Export text attachments with:

```sh
xcrun xcresulttool export attachments --path PATH_TO_SESSION.xcresult \
  --output-path .build/voiceover/evidence --filter '*.txt'
```

Do not confuse a fresh AX label with actual spoken evidence. Capture screenshots only of the
isolated reader after checking the target bounds: the initial Mac XCTest app frame was invalid
and its screenshot included the desktop. The committed diagnostic probe takes no screenshots.
The Mac runner's transcript is plain text and needs no export.

## Harness pitfalls and current results

- Control–Option–Shift–Down enters text; repeating it does not read successive lines.
  Control–Option–L reads the current line and Control–Option–Down moves to the next line.
  The first Control–Option–Down after entering reads the rest of the current line from the
  insertion point instead. See [Apple's text commands](https://support.apple.com/en-ca/guide/voiceover/cpvokys06/mac).
- XCTest returns from a synthesized VoiceOver key about ten seconds later, because VoiceOver
  consumes the key. VoiceOver speaks a hint about two seconds after a move, such as "You are
  currently in a text area", and `currentSpeech()` then returns the hint. The runner sends
  keys through System Events and the probe polls, so each phrase is recorded as it is spoken.
- `currentSpeech()` returns at most 64 characters of a phrase. A phrase identical to the one
  before it is recorded once: Control–Option–Left after Control–Option–Right repeats the word.
  `ERROR 3` records that VoiceOver had nothing to say.
- A focus click moves the insertion point, and VoiceOver enters and reads from there: the
  original `word0012…` capture was the rest of the first line after such a click. Clicks near
  the left edge also turned back a page. Use `ax:focus`.
- The native `moveIn()` returned the previous phrase without entering when called right after
  VoiceOver started, and `testmanagerd` crashed once after five native moves while another
  session's tests were running. Neither was isolated; the probe uses `currentSpeech()` only.
- VoiceOver's `last phrase` AppleScript property and clipboard copying produced no usable
  speech in the initial probes, even with the scripting setting temporarily changed. They are
  not a verified replacement for native speech capture. If exploring that route, record and
  restore the setting and clipboard, and reject an unchanged clipboard sentinel.
- VoiceOver keeps its own text cursor for a column it rests on. If the page changes while it
  is not interacting, it re-enters at its previous character offset, or on the last line of a
  shorter page; `firstword` returns to the first visible word. A window resize moved a
  resting cursor to the window's first control. Neither is a page-boundary failure. It kept
  one for a column it had left too, until the canvas posted its layout change from the element
  that holds the columns ([#337](https://github.com/vocaro/EPUBLib/issues/337)).
- VoiceOver ignores its own Command-F5 while its rotor is open, whether the list holds an item
  or none, so a session that ends under an open rotor leaves VoiceOver on
  ([#399](https://github.com/vocaro/EPUBLib/issues/399)). On 2026-10-13 [hosted
  sessions](#hosted-mac-sessions) on `xcode-27` (image 20261006.0244.1, macOS 27.0.1), in
  pages in a window 600 points wide at 17 points, at the fixed pause, ended so twice at
  `75272d3` (runs 38333839407 and 38333848757): after `ax:focus in rotor` on the first page,
  whose list holds one heading, and after fourteen `ax:next` steps and `ax:lines ax:focus in
  nextheading rotor listchoose line` on a page with no heading, where VoiceOver said "No items
  in Heading menu" and then nothing to Return or to Control-Option-L. Each ended in
  `NOT_RESTORED` with exit status 126, its transcript written, and VoiceOver was still on when
  the job ended. With `listclose` before the end of the same steps VoiceOver went back to the
  text on both pages, saying "Closing Heading menu" over the list of one, `line` read the line
  it had been on, and VoiceOver switched off. At `753999e` (run 38334200030) the runner closed
  the rotor itself: the session on the page with no heading ended with the runner's
  `listclose`, "Closing Heading menu" and VoiceOver off, exit status 0. An Escape sent after
  `listchoose` had moved VoiceOver to the first page's heading, with no rotor open, drew no
  speech and no event from the reader, and `line` read the heading again. The day before, the
  same steps on the page with no heading had ended two sessions (runs 38321608082 and
  38322808793) with a traceback and no transcript, the restore having failed ahead of the
  lines that write one. Nobody listened, and no workstation was used.
- On 2026-10-11 the Mac sessions verified first and last lines, word order, end of text,
  line counts and page-turn continuity in one and two columns at 17 and 23 points, with value
  notifications for page turns, text-size changes and resizes. See the
  [Mac verification](issue-55-voiceover-mac.md). The same day a physical iPad and iPhone
  passed reading order, page boundaries and VoiceOver-activated page turns in both
  orientations at 17 and 23 points; see the
  [iPad and iPhone verification](issue-28-voiceover-devices.md).

- On 2026-10-12 three Mac sessions heard continuous scroll at 23 points in a 600 × 882 window,
  with the insertion point kept on screen. On opening: "In text Page boundary verifica". A
  first entry after two Scroll Forward steps: "In text word0072 word0073 word0074 word0075
  word0076", the `ENTRY` line. Page Down while interacting: `SELECTION` at the new first line,
  then "word0141 word0142 word0143 word0144 word0145" for `line`. After leaving the text, two
  Scroll Forward steps and returning: "In text word0072…" with the reader's layout change;
  without it, VoiceOver's own previous line, "In text word0146…", with the view scrolled back
  to it. On each of the reader's moves VoiceOver says the word before the insertion point
  ("word0071") and repeats the item under its cursor. Read All went on in order, moving the
  insertion point sentence by sentence; the numbered paragraph has no full stop, so the view
  jumped to its end. With the VoiceOver cursor resting on the text area during a move, and no
  layout change, entering went to the first visible character by AppKit's account, the
  numbered paragraph's first line. Not heard: that resting case with the layout change,
  scrolling by hand, contents navigation, a change from paging, a book of ordinary paragraphs.
- On 2026-10-12 [hosted sessions](#hosted-mac-sessions) on `xcode-27` (macOS 27.0.1, windows
  850 points high) heard the page boundary in both layouts. Two columns at 23 points: "In text
  word0093 word0094 word0095 word0096", a right column ending at `word0228`, "2 updated items"
  for a Next Page activated through VoiceOver, then "In text word0229 word0230 word0231
  word0232" and "word0233 word0234 word0235 word0236". One column at 17 points, with
  `advance_after` at 0.5: "In text word0055…", a last line "word0165…word0171" followed by "end
  of text", then "In text word0172…" after the turn. Continuous scroll at 23 points in a
  600-point window entered at "In text word0072 word0073 word0074 word0075 word0076" after two
  Scroll Forward steps, as on the workstation. With the banner's launch agent left loaded on
  purpose, one session of four heard "application Automation Running" and was stopped.
- On 2026-10-12 [hosted sessions](#hosted-mac-sessions) on `xcode-27` (image 20261006.0244.1,
  macOS 27.0.1) heard VoiceOver come back to a column after a page turn, on `740c073` and with
  the fix of [#337](https://github.com/vocaro/EPUBLib/issues/337), at the fixed pause. Two
  lines were moved in the column before leaving it. `740c073` set the insertion point to the
  offset it had before the turn and read from there: "In text word0237 word0238 word0239
  word0240" on a left column starting at `word0229`, "In text word0305…" on a right one
  starting at `word0297`, and in one column at 17 points "In text word0179…" on a page starting
  at `word0172`. The fix set none and said "In text word0229 word0230 word0231 word0232", "In
  text word0297…" and "In text word0172…". Previous Page, and Larger Text chosen from one item
  away, went the same way on each. Page Down and Page Up while interacting read the new first
  line, and continuous scroll entered at "In text word0072 word0073 word0074 word0075
  word0076", as before. With the cursor resting on the column during the turn both said "In
  text word0237…". The
  [Mac verification](issue-55-voiceover-mac.md#coming-back-to-a-column-after-a-page-turn) has
  each case.
- On 2026-10-12 hosted sessions on the same image, at the fixed pause, heard what a review of
  that fix had left open ([#373](https://github.com/vocaro/EPUBLib/issues/373)). With the
  sample's controls in the window's toolbar and two lines moved in the left column: `740c073`
  came back at "In text word0237 word0238 word0239 word0240" after a native press of Next Page
  from one item away; the fix said "In text word0229 word0230 word0231 word0232" there, with
  VoiceOver's cursor on the toolbar during the press, and with Next Page activated through
  VoiceOver inside the toolbar. In continuous scroll on `1b7bf07`, where the window still
  posts, VoiceOver brought to the text by a focus change entered at the new first line, "In
  text word0131 word0132 word0133 word0134 word0135", after Scroll Forward activated from
  eight items away and after a native press from one item away: that flow did not have the
  fault.
- On 2026-10-12, continuous scroll on a physical iPhone 17 Pro Max (iOS 27.2, 440 × 956,
  17 points) and iPad Air 13-inch (iPadOS 27.2, 23 points), the book of ordinary paragraphs,
  through XCTest's VoiceOver service with VoiceOver switched on for each session; its phrases
  were recorded and nobody listened. Before the scroll view listed its lines, two Scroll
  Forward steps on the iPhone left `p003w01` to `p008w40` on screen, and the ninth move
  forward from Scroll Forward gave "C hapter one", then the whole of `p001`, with the reader
  back at the top of the book ([#301](https://github.com/vocaro/EPUBLib/issues/301)).
  With the lines listed, on the iPhone: after two steps the first line of the reading area
  was `p005w21 … p005w25`, the fifth of its paragraph, and the ninth move gave that line; the
  screenshots before and after it differ only in VoiceOver's cursor. `backward=1` returned to
  Bookmark. Twenty-eight moves forward and forty back gave every line once and in order, the
  view following, back past the line VoiceOver came in at to `p004w01`. After
  `activate=Contents,activate=Chapter two` the fifth move from Contents gave "Chapter two",
  twenty-four more read on past the last line that had been on screen, and thirty back
  passed the heading into the chapter before. A touch on Bookmark left the twenty lines on
  screen listed alone, `point=0.5:0.8` gave the line under it, and twenty-two `flick=right`
  and twenty-eight `flick=left` read on and back as the service's moves had.
  On the iPad upright (1024 × 1366): after two steps the ninth move gave `p010w15 … p010w21`,
  the third line of its paragraph and the first of the reading area; forty-four moves
  forward and sixty back gave every line once and in order. In the first book at 23 points
  the lines read "Page boundary verification", "Verification link Link", ". Image:", "Blue
  verification square Image", and after three steps the ninth move gave `word0550 …
  word0555`, the first on screen.
- The same day, with the scroll view listing the lines on screen alone, on the iPad on its
  side (1366 × 1024), straight after `activate=Contents,activate=Chapter two`: the fifth move
  gave "Chapter two" and the moves after it the lines down to `p043w36 … p043w40`, the last
  that had been on screen when the menu closed. The next gave "Vertical scroll bar" and the
  one after the sample's footer; the lines after `p043w40`, listed by then, were passed
  over. Moving back from there gave the lines in order to "Chapter two", then three of them
  a second time, then went on above the heading without a gap. An iPhone 17 Pro simulator
  (iOS 27.0) did the same after any menu closed, even when the chapter chosen was the one on
  screen, and read on, as the devices did, when VoiceOver came into the text after a step of
  the reader's own or without a menu having closed. Posting a layout change, with no element
  or with the line under the cursor, did not change that in the simulator; a page-scrolled
  notification made VoiceOver skip lines; giving it new elements for the same lines once its
  cursor had moved on made it lose its place
  ([#339](https://github.com/vocaro/EPUBLib/issues/339)).
- What VoiceOver asks for, from a build that logged UIKit's answers to it (not committed; it
  replaced `_accessibilityElementsInDirectionWithCount:options:` to log the count and what
  came back), in the simulator and on the iPad alike. As its cursor lands on an item it asks
  for the two items after it and the two before; at each move after that, for the one item
  beyond those it holds. At its first move after a menu has closed it asks for fifty each
  way and goes through them without asking again, then goes back to one at a time. With the
  lines on screen listed alone, the fifty after Contents were four controls, those lines,
  the scroll bar and the footer. It goes through the same fifty after a touch on one of
  them: in the simulator after the menu, `activate=Scroll Forward` and eight moves went
  through the controls it had been given, the ninth said "Chapter one", a line no longer
  listed, and the tenth was Scroll Forward again, from where it asked afresh. UIKit's hit
  test of the text view reads every element listed, twice at each move, and so does XCTest's
  snapshot. The scroll view measured a list of some 120 lines in about 11 ms on the iPad and
  5 ms in the simulator, in debug builds, a little more than once a move.
- With the fifty lines after the screen listed, and fifty each side while the cursor is on a
  line, the same day, through XCTest's VoiceOver service, VoiceOver switched on for each
  session and off after it; nobody listened. The iPad's two sessions were run at `667b110`
  and again at `b2760c6` and `bcc55f3`, each with main merged in, with the same phrases but
  for "Chapter two Heading" once main had headings as elements. iPad on its side at 23
  points,
  `rotate=landscape,activate=Contents,activate=Chapter two,wait=2,visible,screenshot,forward=5,screenshot,forward=62,visible,backward=72,visible,rotate=portrait`:
  the fifth move gave "Chapter two", the sixty-two after it every line once and in order
  from `p041w01` to `p051w08 … p051w14`, past `p043w36 … p043w40` to `p044w01` and on with
  no scroll bar among them, and seventy-two back every line in order to `p039w21`, through
  the heading into the chapter before. The first `visible` counted 68 numbered lines, those
  on screen and the fifty after them. The screenshots before and after the fifth move
  differ only in VoiceOver's cursor, and in one run the status bar's clock. iPad upright, the two-step session above with forty
  moves forward and fifty-six back: the ninth move gave `p010w15 … p010w21`, as before the
  change, with every line once and in order both ways, and the screenshots before and after
  coming in differ only in the cursor. With an earlier build that listed the same lines,
  twenty-seven of VoiceOver's own flicks after the menu on the iPad on its side
  (`flick=right*27`) gave the four controls, the heading and twenty-two lines in order to
  `p044w22 … p044w28`. iPhone 17 Pro simulator (iOS 27.0), at `667b110`: after
  `activate=Contents,activate=Chapter one`, seventy lines forward from `p001w01` to
  `p008w22`, in order, where it had stopped at `p002w29 … p002w33`, and sixty-nine back to
  the heading in order. In one run of two the service gave a phrase twice where
  `p004w39 p004w40` was due, on a move that took 2.4 s with the Mac's load average at 750.
  The two-step session, a touch on Bookmark, `point=0.5:0.8` and six and eight flicks: in
  order.
- Coming into the text from below, the same day at `667b110`, from the sample's footer
  (`touch=VoiceOver Paragraph,backward=6`). At the top of the book, in the simulator: the
  scroll bar, the last line on screen and the lines above it in order. Further in, on the
  iPad upright after two scroll steps and in the simulator: the scroll bar and then
  Bookmark. With an earlier build, on the iPad on its side after a menu and a walk through
  the text: "Vertical scroll bar", `p045w15 … p045w21`, the last line on screen, then
  Bookmark. The
  logging build showed the scroll view 88 points back by the time VoiceOver asked for the
  line before the one it had been given: UIKit scrolls the scroll bar into view as it does
  a line, by the 48-point top inset and 40 more, and the line was then below the screen and
  not listed ([#367](https://github.com/vocaro/EPUBLib/issues/367)). The scroll view has
  listed the lines on screen alone there since #301, and this is not changed. A first
  attempt listed the fifty lines before the screen there as well, to mirror the lines after
  it; the move back went wrong in the same way, and they were taken out.
- With the list keeping its last line while VoiceOver's cursor is after the text
  ([#367](https://github.com/vocaro/EPUBLib/issues/367)), the same day at `916e4cd`,
  through XCTest's VoiceOver service, VoiceOver switched on for each session and off after
  it; nobody listened. On the physical iPad Air 13-inch (M3), iPadOS 27.2, at 23 points in
  the book of ordinary paragraphs, each session ended with `touch=VoiceOver Paragraph` and
  moves back:
  - Upright after two scroll steps, 44 moves: "Vertical scroll bar", `p015w15 … p015w21`,
    the last line in the reader's view, and 42 lines above it once each and in order to
    `p008w20`, past `p010w15`, the first that had been on screen; then six forward in order.
  - Upright after fifteen scroll steps, 46 moves: the scroll bar, `p078w36 … p078w40` and 44
    lines above it in order to `p071w22`, past `p074w01`.
  - Upright at the end of the book
    (`activate=Contents,activate=Chapter three,wait=2,activate=Scroll Forward`, the button
    dimmed), 46 moves: the scroll bar, `p086w36 … p086w40`, the book's last line, and the
    lines above it in order through "Chapter three Heading" to `p079w29`, past `p082w08`.
  - On its side after two scroll steps, 40 moves: the scroll bar, `p010w22 … p010w28` and 38
    lines above it in order to `p004w07`, past `p007w08`.
  - On its side at the end of the book, 40 moves: the scroll bar, `p086w36 … p086w40` and
    the lines above it in order through the heading to `p080w28`, past `p083w36`.

  The upright session at the end of the book was run thirteen times. Twelve read every line
  in order, 11 to 44 of them. In the first of the thirteen, four lines up, after
  `p086w15 … p086w21`, the next move gave "Open EPUB… Button", the first item on the screen,
  and VoiceOver's cursor stayed there. Seven of the twelve were then run with the logging
  build to catch it, and none did: the cause is not known. The log could be fetched from
  four of the seven, and in those the lists were thrown away at launch and never after.
  It has the change at work: a list of 29 lines ending at `p086w36` as the cursor came to
  the footer; the view 88 points back at the move to the bar, and a list of 31 from the
  new first line on screen to the same element for `p086w36`, so that the line before it
  was `p086w29`; then UIKit bringing `p086w36` back into view before the cursor came to
  it. VoiceOver asked for two items as its cursor landed and one at each move, and twice
  for ten after the menu; it did not ask for fifty.
- The same change in simulators of the session's own (iOS 27.0), the iPhone 17 Pro at 17
  points. The issue's steps,
  `activate=Scroll Forward,activate=Scroll Forward,wait=2,visible,touch=VoiceOver Paragraph,backward=30,visible,forward=8`:
  before the change "Vertical scroll bar" and then "Bookmark"; with it the scroll bar,
  `p006w01 … p006w04`, 28 lines above it in order to `p003w05` and eight forward. The log:
  the view at 775 and a list of 18 ending at `p006w01`; at 687 a list of 20, from
  `p004w01` to `p006w01`; then UIKit taking the view to 962 for `p006w01`, where the screen
  held the line VoiceOver asked from next. With the footer touched a second time after one
  move to the bar (`…,backward=1,wait=1,touch=VoiceOver Paragraph,backward=7`) the view
  went back 88 points at each move to the bar, to 599, with `p006w01` still the last of 24
  listed, and the lines were read in order from it. At the end of the book: before the
  change the scroll bar, `p086w40` and Bookmark; with it the scroll bar, `p086w40` and
  eleven lines above it in order. After a menu
  (`activate=Contents,activate=Chapter two,wait=2,touch=VoiceOver Paragraph,backward=26`):
  the scroll bar and 24 lines in order through "Chapter two Heading" into the chapter
  before. The two-step session and the menu session of #339 read on and back in order as
  before. On the iPad Air 13-inch (M4) simulator at 23 points, 44 moves back gave the
  scroll bar and 40 lines in order, with three moves that took over two seconds and gave
  the phrase before them again, at a load average of 860; no line was missing.
- The scroll bar itself, in the simulator's log, and not changed by #367. UIKit asks the
  scroll view for the bar's place with `index(ofAccessibilityElement:)` and gets
  `NSNotFound`, from UIKit's own implementation as from the reader's. Asked for the item
  before the bar it then gave Bookmark, and for the item after it the first line listed.
  So forward past the book's last line
  (`activate=Contents,activate=Chapter three,wait=2` and three scroll steps,
  `point=0.5:0.6,forward=14,backward=8`): `p086w40`, "Vertical scroll bar", then
  `p085w01`, the first line on screen, and on down the screen a second time; and back from
  there the scroll bar and then Bookmark, not `p086w40`
  ([#342](https://github.com/vocaro/EPUBLib/issues/342)). The bar's accessibility frame was
  the height of the scroll view, which is why UIKit moves the view for it: the top inset
  cuts it.
- The scroll bar's place among the lines
  ([#342](https://github.com/vocaro/EPUBLib/issues/342)), 2026-10-12 and 13, through XCTest's
  VoiceOver service; nobody listened. Simulators of the session's own on iOS 27.0, the
  iPhone 17 Pro at 17 points and the iPad Air 13-inch (M4) at 23, in the book of ordinary
  paragraphs. A build that logged UIKit's requests and its own enumeration of an item's
  neighbours (not committed) showed why the bar stood where it did:
  - The scroll view's `_accessibilitySupplementaryHeaderViews` held the vertical bar. Asked
    for the item after the bar, UIKit enumerated from the reader's canvas, a child of the
    host's view, with the bar as that child's header 0, and gave the canvas's first leaf:
    the first line listed. Asked for the item before, it gave the child before the canvas,
    Bookmark. `index(ofAccessibilityElement:)` was asked for the bar only as an attribute
    of the bar, as VoiceOver's cursor went to it, and never while UIKit looked for the
    bar's neighbours: answered with one past the last line, the transcript was unchanged.
  - With the bar's `accessibilityElementsHidden` set, the header list was empty, and UIKit
    asked the scroll view for the bar's index and enumerated from there. An index equal to
    the count gave the sample's footer as the item after and still Bookmark as the item
    before; with the bar listed at that index, the last line. A bar hidden from the start
    was never read: the last line, the footer, and back.
  - The bar hidden and listed from that first question until the cursor was elsewhere read
    every session right, the physical iPad Air 13-inch (M3) on iPadOS 27.2 among them, on
    2026-10-12 at `3fa3121`, VoiceOver switched on for each session and off after it. At
    the end of the book, upright: `p086w36 … p086w40`, "Vertical scroll bar, 15 pages 99%",
    "VoiceOver Paragraph Verification", where VoiceOver stayed; back, the bar, the last
    line and six lines above it in order; forward the same. On its side the same with 22
    pages, and from a touch on the bar the last line and three above it. It was dropped
    all the same. It rested on VoiceOver asking for the bar's index before anything else,
    the view still went back 88 points at every move to the bar, and in one simulator
    session of six a touch on the bar took VoiceOver's cursor to the bar and, 150 ms
    later, to the line under the finger: hidden, the bar was no longer what the finger
    was on.

  With the bar hidden for good and the reader's own element listed for it, at `9a2ce50`,
  in the simulators:
  - iPhone, the end of the book
    (`…,point=0.5:0.6,forward=12,backward=8,forward=10,point=0.955:0.6,backward=5,forward=8`):
    nine lines to `p086w40`, "Vertical scroll bar, 41 pages 100%", "VoiceOver Paragraph
    Verification" twice; back, the bar, `p086w40` and six lines above it in order; forward,
    the same lines, the bar and the footer; from the touch on the bar, `p086w40` and four
    above it. The view's offset did not change once in the session. It went back 88 points
    at each move to UIKit's own bar, which is why that bar read 99%.
  - iPad, the end of the book (`…,touch=p086w36,forward=3,backward=8,forward=10,point=0.982:0.6,backward=4,forward=6`):
    the same, with "15 pages 100%".
  - Mid-book from below, step 8's session with touches on the bar added
    (`…,touch=VoiceOver Paragraph,backward=30,visible,forward=8,point=0.955:0.6,backward=6,forward=9,point=0.955:0.6,forward=2`):
    the bar, `p006w01 … p006w04` and 29 lines above it in order, eight forward; from the
    bar by touch, `p004w31` and five above it; and the footer after the bar. On the iPad
    44 moves back from the footer gave the bar and 43 lines in order from `p015w22`.
  - The top of the book, the two-step session and the menu session of step 7: in order as
    before, with no scroll bar among the lines.
  - Eight touches down the bar's place after two scroll steps (`point=0.955:Y` for Y from
    0.45 to 0.8). On main: the bar eight times. With the element and the lines listed
    whole: the bar five times and a line three times, each a five-word line ending 6
    points from the finger. With the lines listed clear of the bar: the bar eight times,
    and at `point=0.93:0.7`, where a full line's frame used to reach, the bar. At
    `point=0.955:0.4`, under the top inset, main gave the bar and the element is not
    there.
  - Adjusting the bar (`point=0.955:0.6,flick=down`) read the new value, "13%" or "15%",
    with the view some three screens on, and VoiceOver's cursor still on the bar. Moving
    back from there gave the last line on screen and the line above it, and at every
    further move back VoiceOver stayed on that line, in three sessions of three; moves
    forward went on. The log has the line it asked the index of as the element listed,
    on screen, and nothing after the question. This is not understood, and the iPad did
    the same (below). With UIKit's own bar the same flick read nothing and left the
    cursor on no item, in the one simulator session that tried it.

  The same element on the physical iPad Air 13-inch (M3), iPadOS 27.2, at 23 points, on
  2026-10-13 at `b5e135f` (the simulator sessions' code with main merged in), VoiceOver
  switched on for each session and off after it, and the transcripts passed through a
  filter that keeps the book's and the sample's words alone:
  - Upright at the end of the book
    (`…,touch=p086w36,forward=3,backward=8,forward=10,point=0.982:0.6,backward=4,forward=6`):
    `p086w36 … p086w40`, "Vertical scroll bar, 15 pages 100%", "VoiceOver Paragraph
    Verification" twice; back, the bar, the last line and six lines above it in order;
    forward, the same lines, the bar and the footer; from the touch on the bar, the last
    line and three above it, and forward to the bar and the footer. The bar read 99% in
    the dropped attempt's sessions, with the view 88 points back for it.
  - On its side, the same steps between `rotate=landscape` and `rotate=portrait`, with
    `point=0.987:0.6`: the same, with "22 pages 100%". The phrase at the turn to landscape
    was not one of the book's or the sample's and was withheld unread, as in the session
    of the day before.
  - Upright after two scroll steps
    (`…,touch=VoiceOver Paragraph,backward=12,forward=5,point=0.982:0.6,backward=3,point=0.982:0.6,flick=down,wait=2,backward=5,forward=3`):
    "Vertical scroll bar, 15 pages 15%", `p015w15 … p015w21`, the last line in the
    reader's view, and ten lines above it in order; five forward; from the touch on the
    bar, `p016w08` and two above it. After the flick the bar read 27%, from 17%. The
    phrase at the flick itself was withheld: the filter knows no bare percentage. Then
    back: `p023w36 … p023w40`, `p023w29 … p023w35`, and that line again at each of three
    further moves; forward, the line after it, the bar and the footer. So the stop after
    an adjustment is the device's too.
- The two lines that used to be listed each side were one short when VoiceOver moved back up
  the screen, menu or no menu. With its cursor on a line it asks for the item before the
  line two above, so three lines above the cursor must be listed, and two were unless more
  of the screen lay above the cursor. UIKit scrolls the line the cursor is going to into
  view before VoiceOver asks, which lists two more, so the answer was usually right. On
  2026-10-12 another session saw VoiceOver leave the text for Bookmark at "Line 02 after the
  table." or "Line 01" in two of three simulator sessions on main
  (`TEST_RUNNER_VOICEOVER_HREF=OPS/table.xhtml`, `touch=Bookmark,forward=16,backward=16`,
  with a second table added to the section, as #382 does), and one of ten did here. In the
  six of those that were logged, the line VoiceOver asked from was the first line listed
  until the view had scrolled, and the list was made again only as the question arrived.
  With fifty lines listed, four sessions of the same steps read back to the heading, and
  the list began fifty lines above that line before the scroll as after it. Two more sessions gave no transcript: VoiceOver's automation
  failed at the third move in one and the reader did not start in the other, at load
  averages of 800 to 1,000.
- `xcodebuild`'s console output lost three of one device run's 160 `VOICEOVER_EVENT` lines,
  three moves back in a row. The transcript attached to the result bundle had them all.
  Check a break against the attachment before taking it for VoiceOver's.
- In the simulator, UIKit scrolled the line VoiceOver's cursor came to until the area inside
  the scroll view's insets held its frame, and then until the line was 40 points below the
  top of that area or about 120 above its bottom. A line that was the first listed when
  VoiceOver took it led back to the control before the text on the next move back, though
  lines had been listed before it since: it had asked for the two items before that line as
  it landed. When the list shrank to the screen between the two halves of a move, VoiceOver
  stopped at a line it had reached above the screen.
- Not done on a device: a larger text size, VoiceOver's three-finger scroll and its read-all
  gesture, which XCTest cannot make, a book whose lines hold floats or tables, and listening.
- On 2026-10-12 the hidden-labels section was read on a physical iPhone 17 Pro Max and a
  physical iPad Air 13-inch (M3), both on OS 27.2, through XCTest's VoiceOver service and not
  by ear. At 17 points, moving forward from the Bookmark control, in pages and in continuous
  scroll with its lines listed: "Parked title heading", "By the parked author.", "Book Image",
  "Shown opening words.", "Clipped words in the line.", "Shown closing words.", "Parked link
  to the target Link", "Shown last words.". In continuous scroll the lines on screen above
  the section came first, ending "Link target reached" and "This is the end of the numbered
  paragraph.", and moving back gave the same items in reverse. Pages were read at 28 points
  too, and on the iPad in landscape with two columns: on the iPhone the line wraps at that
  size, and the clipped words came between "Shown opening words." and "Shown". Before the
  scroll view listed its lines, continuous scroll read a paragraph at a time, at 17 and 28
  points, with each label in the paragraph it stands in: "￼ Parked title heading ￼ By the
  parked author. ￼", "Shown opening words. ￼ Clipped words in the line. Shown closing words.",
  "￼ Parked link to the target Shown last words. Double tap to activate embedded link".
  Neither label hidden from everyone was read in any run, the screenshots show the image and
  the shown words only, and VoiceOver was off on both devices afterward. On the iPad the
  probe needs `touch=Bookmark` before `read`: from the first item its cursor stayed on the
  window's resize control in a simulator. The iPad refused UI automation twice that day
  ("Timed out while enabling automation mode") and ran half an hour later with nothing
  changed from the Mac.
- The same day, on both devices, the section with a hidden heading over a table, at 17
  points. Opened in continuous scroll, the first move forward from Bookmark gave "Parked
  table heading", then "First cell Second cell Image", "Third cell Fourth cell Image",
  "Shown words after the table." and the lines after it, and moving back returned through
  the rows to "Parked table heading". The screenshots before and after are the same but for
  VoiceOver's cursor, a point above the table: the view did not move. In pages the table's
  four cells came first, each an item, then "Parked table heading", then the rows: a
  table's cells are read before the lines of their page there, whatever those are. That is
  since changed; see the entry on a table's rows below.
- The same day the section was heard on a Mac: GitHub's hosted `xcode-27` runner (image
  `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), in three
  [hosted sessions](#hosted-mac-sessions) at `d010812`, in a window 600 points wide at 17
  points. The section was then the book's last: fourteen `ax:next` steps reached its page
  (twelve turn pages), and in continuous scroll `textend` put VoiceOver on "Link target
  reached", three lines above it. In pages, on entering: "In text Parked title heading By the parked author. Book
  image im", the 64 characters the probe records. By line: "Parked title heading By the
  parked author. Book image image", "Shown opening words. Clipped words in the line. Shown
  closing w", "Parked link to the target Shown last words.", "end of text". By word each
  label is one stop: "Parked title heading", "By the parked author.", "Book image image",
  "Shown", "opening", "words.", "Clipped words in the line.", "Shown", "closing", "words.",
  "Parked link to the target", "Shown", "last", "words.". In continuous scroll the lines
  after "This is the end of the numbered paragraph." were the same three, and Read All gave
  them in order, a sentence at a time. Neither label hidden from everyone is in any
  transcript. A fourth session, at `1e44a71`, read the page that opens with a hidden heading
  over a table (thirteen `ax:next` steps): on entering, "In text Parked table heading"; by
  line, "Parked table heading", "Table row group", "Shown words after the table."; by word,
  "Parked table heading", "Table row group", "Shown", "words". Nobody listened, and no
  workstation was used.

- The same day a book's headings were heard on a Mac: GitHub's hosted `xcode-27` runner (image
  `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), in four
  [hosted sessions](#hosted-mac-sessions) at `41a458f`, in a window 600 points wide at 17
  points, at the fixed pause. In continuous scroll `rotor` opened on "Page boundary
  verification, heading level 1" and `listdown` went on through "Link target reached, heading
  level 2", "Parked title heading, heading level 1", "Parked table heading, heading level 1"
  and "Pictures and their words, heading level 1". `listchoose` on the fourth moved VoiceOver
  to "Parked table heading", which `line` read back. `nextheading` from the first paragraph
  gave "Link target reached", then "Parked title heading", "Parked table heading", "Pictures
  and their words" and "Heading not found". At `8baffa1`, with the book a section shorter,
  the observer's `STATE` after the first of those moves had the insertion point on the
  heading and the heading's line the first on screen, and the moves were the same from the
  text area without interacting. In pages the first page's rotor opened on "Page boundary
  verification, heading level 1" and `nextheading` from that heading gave "Heading not
  found", the page holding no other; the page that opens with a hidden heading over a table
  (thirteen `ax:next` steps) listed "Parked table heading, heading level 1" alone, and
  `listchoose` moved to it. VoiceOver read a heading's words on moving to it and by line,
  and said its level nowhere but in the rotor's list. At `53a7cbe`, before the list began
  with the first heading, the page whose only heading was its first line gave "No items in
  Heading menu" and the scroll view's list lacked the heading that opens the book.
  Control-Option-Command-Shift-H moved to the next heading, not the one before. Not heard:
  two columns, a larger text size, a move back by a VoiceOver command, and the hidden-labels
  page in pages, whose session ended twice in the runner script's check of VoiceOver's state
  with no transcript written: the rotor was still open, as the pitfall above describes.
  Nobody listened, and no workstation was used.
- The same day a move by heading was heard to go through the whole book in pages on a Mac:
  the hosted `xcode-27` runner (image `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0),
  in six [hosted sessions](#hosted-mac-sessions) at `08cd4a7`, at the fixed pause, in a
  window 600 points wide at 17 points, which is one column, and 1100 wide at 23, which is
  two. From the first page `rotor` opened on "Page boundary verification, heading level 1"
  and `listdown` went on through "Link target reached, heading level 2", "Parked title
  heading, heading level 1", "Parked table heading, heading level 1", "Pictures and their
  words, heading level 1" and "Scenes set apart, heading level 1": the whole book's, with
  the first page still on screen. `listchoose` on the last turned to its page, where `line`
  read "Scenes set apart". The rotor opened there on the book's first heading again, and
  `listchoose` turned back to the first page. From the first page's heading `nextheading`
  turned to the page of `word1187` to `word1200`, where `line` read "Link target reached"
  and `STATE` had the insertion point on that line; then to the pages of "Parked title
  heading", "Parked table heading", "Pictures and their words" and "Scenes set apart"; and
  then gave "Heading not found". At each turn VoiceOver read the new page from its top, as
  after any page turn ("text word1187 word1188", "text Parked table heading" and "Table row
  group"), and `line` read the heading. From the page of `word0286` to `word0395`, with
  VoiceOver's cursor resting on the column, three `nextheading` steps went to "Link target
  reached", "Parked title heading" and "Parked table heading". In two columns `nextheading`
  from the left column went through the same five to "Heading not found"; with VoiceOver in
  the right column the rotor listed the same six, and `listchoose` on the last turned to
  its page and put VoiceOver in the left column, on the heading; and from the right column
  of the spread of `word0229` to `word0364`, at rest, `nextheading` went to "Link target
  reached" and then "Parked title heading". Two more sessions, at `36573a5` in two columns
  at 21 points, met "Link target reached" where it opens its page: `nextheading` from the
  first page, and `listchoose` on it with VoiceOver in the right column, each gave "text
  Link target reached" and then "This is the end of the numbered paragraph.", the heading's
  words first. Every heading was in the left column of the spread turned to, at 17, 21 and
  23 points. Four earlier runs, on a throwaway branch that wrote each of the rotor's
  queries to a file, found how VoiceOver asks ([native viewer](native-viewer.md#input-and-accessibility),
  Headings). It loaded a heading given as a token only on moving to it, the element and
  then the range, and never while it listed the rotor's items. At `6e2c1f0`, and on that
  branch with the same code, a token's result had no range: the list showed all six labels
  and VoiceOver read each row of another page out as the column's own text, "text Page
  boundary verification" from the first page and "text word0076 word0077" from a right
  column. There too the search took a cursor resting on a column for nowhere, and
  `nextheading` from the page of `word0286` went back to the first page. Leaving out the
  reader's layout-change notice for the page turned to, or putting the insertion point on
  the heading before posting it, did not change what VoiceOver read on arriving. At
  `c3313e2`, with the link elements of #412 merged, a session in one column repeated the
  list, a choice from it and two moves, with the same result. With VoiceOver's cursor on a
  link, reached by `nextlink`, `nextheading` said "Heading not found" there, and so did
  main at `150698b` in continuous scroll, where the same step from the text gave "Link
  target reached": a link's element has no rotor
  ([#431](https://github.com/vocaro/EPUBLib/issues/431)). Not heard: a heading that lands
  in the right column of a spread, a book still being built, a section that page turns
  step over, words typed in the rotor's list, and a move back by a VoiceOver command.
  Nobody listened, and no workstation was used.
- On 2026-10-13 a move by heading from a link was heard on a Mac
  ([#431](https://github.com/vocaro/EPUBLib/issues/431)): the hosted `xcode-27` runner
  (image `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), in a window 600 points wide
  at 17 points, at the fixed pause. Before, `ax:focus in nextlink nextheading` gave
  "Verification link hyperlink" and "Heading not found", on main at `150698b` in continuous
  scroll (run 38348707110) and at `c3313e2` in pages (run 38348132407).
  At `9520fa2`, with each heading an element among the text's children, in continuous
  scroll (run 38358638705). `ax:links` gave three children: the heading "Page boundary
  verification", the link, and the heading "Link target reached", the next one below the
  screen. `nextlink nextheading` gave "Verification link hyperlink" and "heading level 2
  Link target reached", then "word1151": VoiceOver had scrolled, the reader had put the
  insertion point on the first line on screen, which begins `word1152`, and VoiceOver says
  the word before it. `describe` gave "Link target reached heading level 2 is in the
  VoiceOver cursor", and `right` and `line` read "word1152" and its line. Two more
  `nextheading` steps went on to "heading level 1 Parked title heading" and "heading level
  1 Parked table heading". With the reader opened at the pictures, three `nextlink` steps
  and `nextheading` gave "Described jump, image hyperlink" and "heading level 1 Scenes set
  apart"; opened at the hidden labels, "Parked link to the target hyperlink" and "heading
  level 1 Parked table heading". From the text `nextheading` still said the words alone,
  "Link target reached" and "Parked title heading", and the pictures read by line as
  before, with `nextlink` after them "image hyperlink".
  In pages (run 38359816674) the first page's children were its heading and its link, and
  `nextlink nextheading` gave "heading level 1 Page boundary verification": the page's
  only heading, which stands before the link. On the pictures' first page the same steps
  gave "image hyperlink" and "heading level 1 Pictures and their words"; `right` then gave
  "Pictures", back in the text, and `nextheading` turned to the page of "Scenes set
  apart", which `line` read. From the text `nextheading` turned to the page of `word1187`
  as before, and `line` read "Link target reached".
  `rotor` from a link (run 38360731125): in continuous scroll "Heading menu", "On item
  Page boundary verification, heading level 1", `listdown` twice "Link target reached,
  heading level 2" and "Parked title heading, heading level 1", and `listchoose` moved
  there, where `line` read "Parked title heading By the parked author."; in pages the list
  opened on the same row, five `listdown` steps named the rest of the book's headings to
  "Scenes set apart, heading level 1", and `listchoose` turned to its page, where `line`
  read "Scenes set apart". Main gives that list from a link too: VoiceOver asks the text
  for its rotors as well as the link. VoiceOver opens the rotor on the menu it showed
  last: two other sessions, each after one that had gone on to Window Spots with
  `listright`, opened there. At `1d5b131` (run 38362891089) the first move was the same
  in each flow, and `ax:follow=Parked` on the hidden-labels page, whose first child is now
  the heading "Parked title heading", pressed the link: the observer passes over a
  heading when it looks for a link by its words.
  Four earlier runs, on a throwaway branch that wrote what VoiceOver asked to a file,
  found how the move goes ([native viewer](native-viewer.md#input-and-accessibility),
  Headings). With the text's rotors given to a link's element in three ways, the move
  still said "Heading not found" and asked for no rotor (run 38352084124); the rotor's
  list asked the link's element for them. From the text VoiceOver asked the text area for
  its rotors, searched from the range of its cursor's line and set the selected range to
  the heading; from a link it asked the link for the names of its parameterized
  attributes, then the text area for its children, and read each child's subrole and title
  (run 38353914086). With a heading element for every heading of the book among the
  children, the move went to the next one after the link. The view scrolled from
  `-[NSScroller accessibilitySetValueAttribute:]`: VoiceOver sets the scroll bar's value
  (run 38355673448). With a link's element offering `AXUIElementsForSearchPredicate` and
  answering for headings alone, Find Next Link asked it for the next link and said "Link
  not found" (run 38357037596; [#454](https://github.com/vocaro/EPUBLib/issues/454)).
  In pages on that branch, where a column's rotor still held its page alone and the search
  stood at the link, the rotor's list from the first page's link said "Heading menu" and
  no row, and `listchoose` chose nothing: the search had answered the question VoiceOver
  asks from the link's element with no item. That was heard once.
  Not heard: a heading that follows a link on the same page in pages, which the book has
  none of and the unit tests read; a link after the book's last heading; two columns; a
  larger text size; a link in a table cell, which is the cell's own text view's; and
  listening. Nobody listened, and no workstation was used.
- To see what VoiceOver asks of the reader, have the reader write it to a file. `log show`
  on the hosted runner returned no line the sandboxed reader logged. A throwaway branch
  that appends each query to a file in `FileManager.default.temporaryDirectory`, with a
  workflow step after the sessions that finds the file under `~/Library/Containers` and
  copies it into the results as a `.log`, records them; with times in the transcript's
  format the two sort into one account. VoiceOver's rotor is a window of its own and shows
  in nothing but a screenshot, which the observer can take with `screencapture -x` into the
  results folder. A run builds the commit its branch had when it was started; to build what
  the branch holds when the job begins, give the branch's name as the `ref` input too.
  A rotor's delegate sees only what VoiceOver asks of the rotor. To see everything it asks
  of an element, override AppKit's old attribute methods on the throwaway branch, log, and
  call `super`: `accessibilityAttributeValue(_:)`, `accessibilityAttributeValue(_:forParameter:)`,
  `accessibilityAttributeNames()`, `accessibilityParameterizedAttributeNames()`,
  `accessibilitySetValue(_:forAttribute:)` and `accessibilityPerformAction(_:)`. Every
  request to a view passes them, and so do some of those to an `NSAccessibilityElement`,
  though not the ones for its frame. A launch argument read with `UserDefaults`, given to
  a session as `"launch=-Name value"`, puts several variants of the reader in one run. A
  call stack logged from the reader's own handler says who moved something: VoiceOver's
  scroll arrives as a set of the scroll bar's value.
- The same day they were read on a physical iPad Air 13-inch (M3) (iPadOS 27.2), upright at
  17 points, at `41a458f`, through XCTest's VoiceOver service; nobody listened. In pages a
  touch on the first page's heading gave "Page boundary verification Heading Use the rotor to
  access Headings", and one turn of the rotor gave "Headings". Each `flick=down` then moved on
  through the book: "Link target reached Heading", with the page of `word1013` to `word1200`
  on screen, "Parked title heading Heading", "Parked table heading Heading", on the page
  that opens with the table, "Pictures and their words Heading" and "Heading not found".
  `flick=up` went back through the same four to "Page boundary verification Heading", the
  first page on screen again, and then gave "Heading not found". In continuous scroll, in
  the book of ordinary paragraphs: "Chapter one Heading Use the rotor to access Headings",
  then "Chapter two Heading" with `p040w28` to `p048w40` on screen, "Chapter three Heading"
  with `p079w29` to `p086w40`, and "Heading not found"; back to "Chapter two Heading"; two
  moves forward into the chapter's lines, the rotor turned to Headings again, and from a
  line that is no heading "Chapter two Heading", "Chapter one Heading" and "Heading not
  found". VoiceOver said a level nowhere. At `64a012b`, where the search looked among the
  lines listed, the move on from "Parked title heading" gave "Heading not found" on this
  iPad and on both simulators: VoiceOver asked the rotor twice for the one move, and the
  second answer, from the same item on a page no longer shown, was not the first.
- On a physical iPhone 17 Pro Max (iOS 27.2), the same day and commit, a touch on the heading
  gave "Page boundary verification Heading Actions available Use the rotor to access
  Headings" in pages. XCTest's two-finger turn did not move VoiceOver's rotor there in thirty
  turns of several sizes, nor made on the window or on the text, so no move by heading was
  made on the phone: with the rotor still on Actions `flick=down` gave "Next Page". One run
  ended in an exception XCTest raised for a gesture, without the probe's `defer`, and left
  VoiceOver on: it was switched off with `devicectl device settings voiceover --disable`
  and read back as off, and the probe now restores VoiceOver from a teardown block.
- The [simulator lane](#simulators) read them the same day at `8c19f15`, on an iPhone 17 Pro
  and an iPad Air 13-inch (M4) (iOS 27.0), when the book had no section of pictures. In
  pages at 17 points both gave "Page boundary verification Heading Actions available Use the
  rot", then with the rotor on Headings "Link target reached Heading" (`word1177` to
  `word1200` on the iPhone's page, `word1040` to `word1200` on the iPad's), "Parked title
  heading Heading" and "Parked table heading Heading", and back through them to "Page
  boundary verification Heading" and "Heading not found". On the iPhone the move to the page
  that opens with the table left VoiceOver on "Open EPUB… Button", and the next
  `flick=down` gave "Parked table heading Heading". In continuous scroll both gave "Chapter
  two Heading", "Chapter three Heading", "Heading not found" and "Chapter two Heading"
  again, with the screens the iPad showed, and from a line of the chapter "Chapter two
  Heading". At 28 points the heading takes the whole of the iPhone's first page: one move
  forward from it gave "Read the numbered words Actions available" and one back "Page
  boundary verification Heading Actions available", so its lines are one item. At
  `9b155ec`, with a heading's label ending in its paragraph's break and no rotor of the
  reader's, the same touch recorded "Page boundary verification" alone, and VoiceOver's
  own rotor gave "Heading not found" past the last heading on screen.
- Not done for headings: listening, a move by heading on an iPhone, landscape and two
  columns, and a larger text size on a device.
- On 2026-10-12 the [simulator lane](#simulators) (Xcode 27.0, iOS 27.0) recorded, at 17
  points: on an iPhone 17 Pro word0001–word0016 in 4 lines and, after Next Page,
  word0017–word0080 in 16; on an iPad Air 13-inch (M4) in portrait word0001–word0301 in 36
  lines, then word0302–word0670 in 45 and word0671–word1037 in 44, and in landscape
  word0358–word0567 beside word0568–word0777, 60 lines read left column first. At 23 points
  the iPad showed word0001–word0146 in 24 lines and then word0147–word0345 in 33; the iPhone
  no numbered line on its first page and word0001–word0036 in 12 on its second. VoiceOver
  spoke every numbered line once and in order, then the book title, where it stayed, and
  XCTest's view of the columns agreed. A phrase is cut at 64 characters, so an iPad line
  shows its first seven words. No page action, rotor action or landscape turn was performed
  by VoiceOver there; see the section.
- On 2026-10-12 the hidden-labels section and the section of pictures were read at 17 points
  after an image with an empty `alt` was left out of what VoiceOver is given and an image with
  no `alt` lost its made-up name. Nobody listened, no workstation was used and no physical
  device: the iPhone and iPad here are the [simulator lane](#simulators)'s, which establishes
  what VoiceOver reads and not that it can activate anything.
  On an iPhone 17 Pro and an iPad Air 13-inch (M4) simulator (iOS 27.0, Xcode 27.0), moving
  forward from the Bookmark control. Hidden labels, in pages and in continuous scroll, at
  `1213dd0`: "Parked title heading", "By the parked author.", "Shown opening words.", "Clipped
  words in the line.", "Shown closing words.", "Parked link to the target Link", "Shown last
  words."; the "Book Image" that came after the author is gone. Pictures, in pages (the iPad
  at `0819ce1`; the iPhone, whose first page ends at "Described jump", at `1213dd0` with Next
  Page between its two pages) and in continuous scroll at `1213dd0`: "Pictures and their
  words", "Undescribed picture", "Image", "stands here.", "Decoration  passed over.", "Bare
  jump:", "Link Image", "Jump with decoration Link", "Described jump Link Image", "Titled
  decoration  passed over.", "Titled picture", "Square with a title of its own Image",
  "stands here.", "Last words about pictures.". "Image" and "Link Image" alone are
  VoiceOver's words for the traits: those elements have no label. In continuous scroll on the
  iPad, read on from the hidden labels, VoiceOver went from the twenty-ninth line after the
  table to the scroll bar, as in [#339](https://github.com/vocaro/EPUBLib/issues/339); the
  pictures were read there with the reader opened at their section.
  On the Mac: GitHub's hosted `xcode-27` runner (image `20261006.0244.1`, macOS 27.0.1
  `26A434`, Xcode 27.0), a window 600 points wide, at `81b9401`, runs 38321044607 (pages) and
  38321046784 (continuous scroll). The labels' page is twelve `ax:next` steps in and the
  pictures' first page twenty; the pictures take two pages there. Hidden labels by line:
  "Parked title heading By the parked author. ", "Shown opening words.  Clipped words in the
  line. Shown closing w", "Parked link to the target Shown last words."; by word: "Parked
  title heading", "By the parked author.", a step with no phrase, "Shown", "opening",
  "words.", "Clipped words in the line.", and on as before. The step with no phrase is
  VoiceOver's cursor crossing the image's character, where "Book image image" was said before.
  Pictures by line: "Pictures and their words", "Undescribed picture  image  stands here.",
  "Decoration   passed over.", "Bare jump:  image ", " Jump with decoration", "Described jump
  image ", "Titled decoration   passed over.", and on their second page (run 38319634156, at
  `55b16e0`) "Titled picture  Square with a title of its own image  stands her", "Last words
  about pictures.", "end of text". By word: "Undescribed", "picture", "image", "stands",
  "here.", "Decoration", a step with no phrase, "passed", "over.", "Bare", "jump:", "image", a
  step with no phrase, "Jump", "with", "decoration", "Described jump image", "Titled",
  "decoration", a step with no phrase, "passed". Continuous scroll gave the same lines, the
  labels' after "This is the end of the numbered paragraph." and the pictures' at the end of
  the book. No transcript has the word "link": on the Mac "Parked link to the target", "Jump
  with decoration" and the linked images are read as text and images. At `55b16e0`, before
  an image without words lost its help text, run 38319737879 heard it as "Undescribed picture
  Double-click or choose Inspect Image to enl": VoiceOver reads the help of an element that
  has no label in the label's place.
  Not heard: VoiceOver activating the link that is an image without a name, which needs a
  device; a note's popover or a table cell with an image in it.
- On 2026-10-12 the section of scenes was read at 17 points before and after a rule was
  given a stop that names it. Nobody listened, no workstation was used and no physical
  device: the iPhone and iPad here are the [simulator lane](#simulators)'s (an iPhone 17 Pro
  and an iPad Air 13-inch (M4), iOS 27.0, Xcode 27.0), which establishes what VoiceOver reads
  and not that it can activate anything. Both sides were recorded on the same `main`
  (`2db7754`).
  Before, at `81f8d88`, moving forward from the Bookmark control, in pages on both: "Scenes
  set apart", "First scene ends.", "  Image", "Second scene starts.", "  Image", "Words
  after an ornament.", then the book's title under the page; on the page that holds a rule
  alone "  Image" and nothing else of the text; on the last "Last words of the scenes.".
  "Image" after two spaces is VoiceOver's word for the image trait of an element that has
  no label, as in the pictures' transcripts. In continuous scroll, where the section is one
  run of lines, the same with a third "  Image" before "Last words of the scenes."; the iPad
  read the lines on screen above the section first, from "Line 57 after the table.".
  After, at `d432df6`: "Separator" in each of those places and "Image" in none, in pages and
  in continuous scroll on both: "Scenes set apart", "First scene ends.", "Separator",
  "Second scene starts.", "Separator", "Words after an ornament."; on the page of a rule
  alone "Separator"; and Next Page from there showed "Last words of the scenes.". The rule
  before "Words after an ornament." has `role="presentation"`, which the reader does not
  read. At `253c79a`, whose reader is that of `d432df6`, in pages on both: from a touch on
  "Second scene starts." three moves back gave "Separator", "First scene ends.", "Scenes set
  apart" and four forward "First scene ends.", "Separator", "Second scene starts.",
  "Separator"; a touch on the rule gave "Separator", and one finger down from there
  "Next Page" and then "Previous Page", the stop's actions; on the page of a rule alone a
  touch on the rule gave "Separator Swipe up or down to select a custom action", and the
  screenshot shows VoiceOver's cursor round the line and nothing else on the page.
  VoiceOver says "Actions available" after an item only where its actions differ from those
  of the item before, so the phrase comes and goes along one page. The continuous-scroll
  transcripts at `81f8d88` and `d432df6` have `-dirty` in their build line: each ran the
  probe as the pages run a few minutes before had built it, at the clean revision, and the
  working tree had been edited since. In continuous scroll VoiceOver went on from the
  section's last line to the scroll bar and then, on the iPad both times and on the iPhone
  before the change, round to the lines above the section and through it again before it
  reached the book's title; moving back from the title it reached the Bookmark control past
  the scroll bar and at most the section's last line. The transcripts before the change
  have both, so neither is the rule's doing. Three further sessions, at load averages near
  1,000, read nothing: two ended with "VoiceOver is on but says nothing" after three
  minutes of silence, and one was not started, because a simulator gave no answer in twenty
  seconds when its volume was set. Moving back across a rule in continuous scroll was to be
  read in the last two, and was not.
  On the Mac: GitHub's hosted `xcode-27` runner (image `20261006.0244.1`, macOS 27.0.1
  `26A434`, Xcode 27.0), a window 600 points wide, run 38327683951 at `81f8d88` (pages) and
  runs 38328830423 (pages) and 38328832799 (continuous scroll) at `d432df6`. The scenes'
  first page is 22 `ax:next` steps in, the page of a rule alone 23 and the last 24. In
  continuous scroll 28 `ax:next` steps reach the end of the book, where `lastword` puts
  VoiceOver on "scenes."; `textend` goes to the end of the book's first section instead. The
  reader gives a rule no element there, and both revisions read the same. Pages by line:
  "Scenes set apart", "First scene ends.", a phrase with nothing in it, "Second scene
  starts.", a phrase with nothing in it, "Words after an ornament.": VoiceOver stops on the
  rule's line and says nothing. By word: "Scenes", "set", "apart", "First", "scene",
  "ends.", a step with no phrase, "Second", "scene", "starts.", a step with no phrase,
  "Words", "after", "an", "ornament.", a step with no phrase, "end of text". On the page of
  a rule alone: "In text" and no more on entering, a phrase with nothing in it for the line,
  no phrase for the word or for a move right, and "end of text" for the next line.
  Continuous scroll by line, back from the end: "Last words of the scenes.", a phrase with
  nothing in it, "Words after an ornament.", the same, "Second scene starts.", the same,
  "First scene ends.", "Scenes set apart", "Last words about pictures.". No Mac transcript
  has "Separator" or "image" at a rule.
  Not heard: a physical device; VoiceOver reading on by itself across a rule; a rule in a
  note's popover or in a table cell; a rule that is all a link holds; and what Safari or
  Books says at an `<hr>` on an iPhone, which was not compared.
- On 2026-10-12 the [simulator lane](#simulators) read what VoiceOver offers on a line,
  before and after a line was left with its own actions alone: an iPhone 17 Pro simulator
  (iOS 27.0, Xcode 27.0, 402 × 874) at the launch text size, a touch or a move to the line
  and then `flick=down` to read the rotor. A physical iPad read the change afterwards, as
  told below. Nobody listened.
  Before, at `fc8ed77`. Continuous scroll, the book of paragraphs: "p001w11 p001w12 p001w13
  p001w14 p001w15 Actions available", and the rotor read "Previous Page", "Next Page",
  "Activate Default". Continuous scroll, the first book: "Read the numbered words across two
  consecu Actions available", and the rotor read "Verification link", "￼", "￼", "￼ Jump with
  decoration", "￼", "Inspect Image: Blue verification square", "Previous Page", "Next Page",
  "Activate Default", and the same on "Verification link Link" and on ". Image:"; on the
  picture's own line it read the picture's inspection and then those nine. The first
  five are UIKit's own for a text view, one for each link of the book by its words, with "￼"
  for a picture or a hidden label in the link: "Jump with decoration" is a link of the
  book's fourth section, offered on a line of its first. In pages, on "Read the numbered
  words across two consecu": "Next Page", "Previous Page", "Inspect Image: Blue verification
  square", "Previous Page", "Next Page", "Activate Default". On the picture's own line the
  inspection came twice: "Next Page", "Previous Page", "Inspect Image: Blue verification
  square", the same again, "Previous Page", "Next Page", "Activate Default".
  The phrases and the rotor were the same at `cfc7768`, before the Headings rotor, and the
  physical iPhone 17 Pro Max of the sessions above said "p005w21 p005w22 p005w23 p005w24
  p005w25 Actions available" in continuous scroll that morning. Neither the rotor nor the
  simulator is the cause.
  A reader built at `cfc7768` to write down what it gives VoiceOver, and to change one thing
  at a time, showed what is. With the cursor on a line of the book of paragraphs the line
  had no action of its own and its text view none; the canvas had "Previous Page" and "Next
  Page", put there by SwiftUI for the reader's surface; and UIKit handed VoiceOver those two
  for the line. In the first book the scroll view had UIKit's five and the reader's "Inspect
  Image: Blue verification square", and a page column the reader's alone. A line cut off
  from what holds it, still answering with an empty list and still answering activation
  itself, was read as "p001w11 p001w12 p001w13 p001w14 p001w15" and no more, and the rotor
  stepped by character ("p Papa", "0", "0"). A line that answered with no list at all, and
  nothing else changed, said "Actions available" as before.
  After, at `69230b2`. Continuous scroll, the book of paragraphs: "Chapter one Heading Use
  the rotor to access Headings", then "p001w01 p001w02 p001w03 p001w04 p001w05", "p001w06
  p001w07 p001w08 p001w09 p001w10" and "p001w11 p001w12 p001w13 p001w14 p001w15" with
  nothing after them, and the flicks read "0", "0", "1", characters of the line. The first
  book: "Read the numbered words across two consecu", and ten flicks read "R Romeo", "e
  Echo", "a Alpha", "d Delta" and on along the line; "Verification link Link", and the
  flicks read "V Victor", "e Echo", "r Romeo"; "Blue verification square Image Actions
  available", and the rotor read "Inspect Image: Blue verification square" and "Activate
  Default" in turn, five times. In pages: "Read the numbered words across two consecu
  Actions available", and the rotor read "Next Page", "Previous Page", "Activate Default"
  and the three again; on "Blue verification square Image" it read "Next Page", "Previous
  Page", "Inspect Image: Blue verification square", "Activate Default" and the first three
  again. At `7934820`, with fifty lines past the screen listed while the cursor is in the
  text, continuous scroll in the first book read the same: "Read the numbered words across
  two consecu Use the rotor to acce" and "R Romeo", "e Echo", "a Alpha"; "Verification link
  Link" and "V Victor", "e Echo", "r Romeo"; "Blue verification square Image Actions
  available" and "Inspect Image: Blue verification square", "Activate Default", "Inspect
  Image: Blue verification square".
  The Mac's load averages were in the hundreds throughout. Three more sessions read
  nothing and were run again: one was not started, one ended with "Failed to send
  moveForward command" and one with "VoiceOver is on but says nothing" after three minutes.
  One session's result is "Critical process xctest crashed" with all its steps in the
  transcript, as under "Other sessions" in [Simulators](#simulators). In the after session
  of the book of paragraphs each phrase was recorded a step late, so the first line is
  there twice and the first flick has the third line's phrase. One simulator came back at
  volume 60 before its VoiceOver had been switched on, and was muted again. After most
  sessions `devicectl` gave no answer in twenty seconds when asked for the simulator's
  VoiceOver state; the simulator was then deleted, as every one was.
  The same evening the physical iPad Air 13-inch (M3) of the sessions above (1024 × 1366,
  upright, 17 points) read the change, built at `8d7397b`, through XCTest's VoiceOver
  service. In pages, with the cursor on "Read the numbered words across two consecutive
  pages. …", four flicks read "Next Page", "Previous Page", "Activate Default" and "Next
  Page", and a double tap on the line then performed Next Page: the page went from
  `word0001`–`word0293` to `word0294`–`word0654`. In continuous scroll the same line left
  the rotor on Headings: the flicks read "Link target reached Heading", "Parked title
  heading Heading", "Parked table heading Heading" and "Pictures and their words Heading",
  the reader scrolling to each, and no action. On the picture's line there the flicks read
  "Inspect Image: Blue verification square" and "Activate Default", and with the first
  chosen a double tap opened the inspector: VoiceOver was on "Zoom Out Button" and a touch
  found "Zoom In Button". An iPad's phrase for a line does not tell whether the line has
  actions. It ended in "Use the rotor to access Headings" for the page's line, which has
  two, and for the same line in continuous scroll, which has none; the rotor tells.
  VoiceOver was off after each session. A first session in pages was deleted with its log
  and result bundle, and run again: a notification arrived on the iPad and was read in
  place of the first flick's phrase.
  Not established: a physical iPhone after the change; a table row's actions under
  VoiceOver, which a unit test holds; and anything on a Mac, where the text areas and the
  surface's two actions are unchanged.
- The same day the section of what each line offers, which shows every kind of item at
  once, was stepped through with the rotor at 17 points in the
  [simulator lane](#simulators) (Xcode 27.0, iOS 27.0, an iPhone 17 Pro and an iPad Air
  13-inch (M4)), before and after the same change made on the branch that reads a table by
  its rows. Nobody listened. The lists are XCTest's record of VoiceOver's phrase after
  each step of one finger down; a phrase that comes twice running in a transcript is one
  entry, heard before and after a step that did not register.
  Before, at `073f2b0`, in pages on both, on "Plain words above.", on the link "Lone jump"
  and on "Plain words below.": "Next Page", "Previous Page", "Inspect Image: Square with
  words", "Inspect Image", "Previous Page", "Next Page", "Activate Default", and round
  again. "Square with words" offered its own inspection third and then the same two
  inspections; the picture without words likewise; the table's row "Select Table Text: Left
  cell", "Select Table Text: Right cell jump" and "Follow Table Link: Right cell jump" after
  the first pair, then the two inspections and the second pair. In continuous scroll on
  both, on a line of words: "Verification link", "￼", "￼", "￼ Jump with decoration", "￼",
  "Lone jump", "Inspect Image: Square with words", "Inspect Image", "Previous Page", "Next
  Page", "Activate Default". Ten actions, none of them the line's; the pictures and the row
  offered their own first and then the same ten.
  A build that put a letter before every action's name for the object that gave it
  (`5c01fa8`, on the iPhone simulator) settled where each came from. On a line of a page:
  "L Next Page" and "L Previous Page" from the line's own element, "K nil" for what UIKit
  returned to the text view, "T Inspect Image: Square with words" and "T Inspect Image"
  from the text view, and "S Previous Page" and "S Next Page" from the reader's SwiftUI
  view. On a line of continuous scroll: "K Verification link", "K ￼", "K ￼", "K ￼ Jump with
  decoration", "K ￼", "K Lone jump" and "K count 6", then the same two T and two S. UIKit's
  six are the book's six runs of text that are links, in the book's order: the first
  section's, the parked link of the hidden labels, the three of the pictures (two of them a
  picture alone) and this section's own. A link in a table cell is not among them, and no
  picture that is not a link.
  After, at `5e6834c` on both, in pages: "Next Page", "Previous Page", "Activate Default"
  on a line and on the link; "Inspect Image: Square with words", or "Inspect Image" on the
  picture without words, before "Activate Default" on a picture; the three table actions
  there on the row; and one turn of the rotor on a line came to Actions. In continuous
  scroll: a step on a line or on the link read the line a character at a time ("P Papa",
  "l Lima"), and thirty turns of the rotor on a line went round Containers, Lines, Words,
  Characters, Headings and Speaking Rate and never came to Actions (`rotor=Actions:
  MISSING`); "Square with words" said "Actions available" and offered "Inspect Image:
  Square with words" and then "Activate Default", the picture without words "Inspect
  Image", and the row its three. `5e6834c` is the change on the table branch's own merge
  with `main`; a session in pages at `918ec8b`, the same change on an earlier merge, read
  the same on both simulators.
  The physical iPad Air 13-inch (M3) of the sessions above (1024 × 1366, upright, 17
  points) read the section in pages at `331c326`, which has the table's rows and the other
  branch's change merged in. "Plain words above." offered "Next Page", "Previous Page" and
  "Activate Default"; "Square with words" those two, "Inspect Image: Square with words" and
  "Activate Default"; and the row began "Next Page", "Previous Page", "Select Table Text:
  Left cell". With Next Page chosen on "Plain words above." a double tap changed the screen,
  and the screenshot shows the page that begins "Below line 18.", where the one before ended
  at "Below line 17.": VoiceOver performed the line's own page turn. VoiceOver was off
  afterward.
  That turn was made with text selected: before it, Select Table Text: Left cell had been
  chosen on the row and performed by a double tap. A second session ran the same two steps
  on a build whose line still turned the page as it used to (`18323fd`, the same revision
  with that one call put back, not in the branch), and there the double tap on Next Page
  changed nothing: "nothing on screen changed in 2.0 s", the first page still in the
  screenshot, and "Words before" for the next move forward. So VoiceOver performs Select
  Table Text on a device, the selection held back a line's page turn as it was, and it does
  not now. The selection itself is not to be seen in either screenshot.
  One thing was seen and not looked into: after the turn VoiceOver's cursor was still drawn
  where the line had stood, and a move forward from it went to the book's title under the
  page. The record of 2026-10-13 below has what it was.
  Most sessions started that evening did not run. At load averages of 600 to 1,000
  `devicectl` gave no answer in the runner's twenty seconds when a simulator's volume was
  set, and later failed with "Timed out waiting for CoreDeviceService to fully initialize";
  the iPad simulator's VoiceOver said nothing in three minutes twice; and XCTest failed two
  sessions after their last step ("Critical process xctest crashed"), whose transcripts are
  whole. After the last sessions in continuous scroll `devicectl` could not read back the
  simulators' VoiceOver state; they were deleted, as every one was. One iPhone simulator came back at volume 60 during the labelled continuous-scroll
  session and was muted again by the runner within a second (an `UNMUTED` line).
- On 2026-10-12 the section of scenes was read on a Mac before and after a rule was given an
  element that says a separator is there, and with each other element that was tried.
  GitHub's hosted `xcode-27` runner (image `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode
  27.0), a window 600 points wide at 17 points, at the fixed pause. Nobody listened and no
  workstation was used. Before and after were recorded on the same `main` (`5b096d8`).
  Before, at `5b096d8`, runs 38333729257 (pages) and 38333734464 (continuous scroll): as in
  the record above, a phrase with nothing in it on each rule's line, a step with no phrase
  by word, and on the page of a rule alone "In text" and then "end of text". `readall` from
  the page's first word, which that record did not have: "Scenes set apart", "First scene
  ends.", a phrase with nothing in it, "Second scene starts.", the same, "Words after an
  ornament.".
  After, at `e3f5240`, runs 38342098837 (pages) and 38342104207 (continuous scroll). Pages
  by line: "Scenes set apart", "First scene ends.", "Separator", "Second scene starts.",
  "Separator", "Words after an ornament.". By word: "Scenes", "set", "apart", "First",
  "scene", "ends.", "Separator", "Second", "scene", "starts.", "Separator", "Words",
  "after", "an", "ornament.", a step with no phrase, "end of text". `readall` from
  "Scenes": the six phrases heard by line, in order. On the page of a rule alone: "In text
  Separator" on entering, "Separator" for the line and for the word, no phrase for a move
  right, and "end of text" for the next line. Continuous scroll, back by line from
  "scenes.": "Last words of the scenes.", "Separator", "Words after an ornament.",
  "Separator", "Second scene starts.", "Separator", "First scene ends.", "Scenes set
  apart". `readall` from there: a phrase with nothing in it where "First scene ends." is
  read, which the session before the change has too, then "Separator", "Second scene
  starts.", "Separator", "Words after an ornament.", "Separator", "Last words of the
  scenes.". Back by word from "scenes.": a step with no phrase, as before the change, then
  "the", "of", "words", "Last", "Separator", "ornament.", "an", "after", "Words",
  "Separator", "starts.", "scene", "Second". The pages' `LINE` and `STATE` lines are the
  same before and after: a rule's line is two characters of the text area's value, the rule
  and the break after it.
  With `main` at `a49d12e` merged in, which marks headings in the same rich text, at
  `e4b1e22`, run 38342923798, pages: the same six phrases by line and with `readall`, and
  on the page of a rule alone "In text Separator", "Separator" for the line and for the
  word, no phrase for a move right and "end of text". Those two revisions also gave a rule
  in a table cell the element, which the change as it is does not; the scenes hold no
  table. The change as it is, at `6e9b055`, run 38346365216, pages: the same phrases by
  line, by word, with `readall` and on the page of a rule alone as at `e3f5240`. With
  `main` at `449182f` merged in as well, which gives the links of the same rich text
  elements of the reader's own, at `14b2696`, run 38349644406, three sessions in one run:
  "Separator" at every rule in pages by line, with `readall` and by word, on the page of a
  rule alone, and in continuous scroll back by line, with `readall` and back by word. And
  with `main` at `8d78dc1`, whose fixture has a second table in the section before the
  pictures, at `86a5121`, run 38353724021: the scenes' first page is still 22 `ax:next`
  steps in; opened at the section with `-SampleHref OPS/scenes.xhtml`, the same phrases by
  line, with `readall` and by word, and the page of a rule alone one `ax:next` step on; in
  continuous scroll thirty `ax:next` steps and `lastword` gave "scenes.", and the lines
  back from there and `readall` were as before.
  The other elements, each a commit that differs in nothing but what a rule's character
  carries, heard in pages by line, by word, with `readall` and on the page of a rule alone.
  AppKit's splitter role and nothing else, `3073331`, run 38333879354: "horizontal splitter
  collapsed on top" at each rule, with two spaces after "splitter", and "horizontal
  splitter" for `word` on the page of a rule alone; continuous scroll said the same (run
  38333881836). The splitter role with the subrole `AXContentSeparator`, `d664ccf`, run
  38333889187: the same. Those two with the role description "separator", a horizontal
  orientation and not enabled, which is all that WebKit gives an `hr`, `efb3747`, run
  38333903411: "horizontal separator no action available collapsed on top". Static text
  with the value "Separator", `1dd8ea3`, run 38333917655: "Separator", as after. AppKit's
  unknown role with the role description "separator", `563bc29`, run 38339554059:
  "separator" in the same places. Not heard: WebKit's attributes on an element left
  enabled, and any of these but the first in continuous scroll. Their runs were stopped
  while they waited for a runner, once the pages had shown what each says.
  A table cell. At `5b096d8`, run 38333986334, on the page that opens with a table: a move
  by word onto a row said "Table row group", `in` on the second row "In Table row group 2
  items text Third cell" and a move right "text Fourth cell". A row is a group, and each
  cell a text area in it. For two sessions the scenes were given a table at their end, one cell holding
  "Cell scene ends.", a rule and "Cell scene starts."; the fixture in the repository has
  none. At `3f77069`, run 38340763586, with the cell as it is: `in` on the row said "In
  Table row group 2 items text Cell scene ends.", `in` again "In text Cell scene ends.",
  then by line "Cell scene ends.", a phrase with nothing in it, "Cell scene starts.", by
  word a step with no phrase after "ends.", and `readall` the same three phrases as by
  line. At `e1d32b7`, run 38342113877, with the cell's rule given the element a rule has
  outside a table: the same, phrase for phrase.
  Not heard: a physical Mac, or anyone listening; a rule in a note's popover; VoiceOver in
  a language other than English or with its verbosity changed; and what Safari or Books
  says at an `<hr>` on a Mac, which was not compared.
- On 2026-10-12 and 13 links were heard on a Mac: GitHub's hosted `xcode-27` runner (image
  `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), in a window 600 points wide at 17
  points, with VoiceOver's link setting at Speak, as the runner has it. Nobody listened, and
  no workstation was used.
  First what VoiceOver does with AppKit's own text view (`-VerificationPlainText`), with
  TextKit 2 and with TextKit 1, at `e3efd8a`, `a72154c` and `71f9b77`. By word: "the", "reference",
  "link", "after". By line: "Reference opening words. Before the reference link after it."
  and "Picture link:   closing words.". Read All said the same lines. Nothing said that a
  link was there. Find Next Link: "reference link hyperlink", the hint "You are currently on a
  hyperlink, inside of a text area. To clic", then "￼ hyperlink" for the link that is a
  picture. Control-Option-Space after Find Next Link followed the link, and so did
  Control-Option-Space with the cursor on "Reference", the first word of the line that holds
  "reference link", and on "after"; on "Reference" in the last line, which has no link,
  nothing was followed. The rotor listed Window Spots.
  The reader before the change, at `e3efd8a` (main's reader then) and for the pictures at
  `62ea392`: the first page as AppKit's view, "Verification", "link." by word and
  "Verification link hyperlink" for Find Next Link. Its links that are attachments were
  called by their character: `ax:links` gave the titles "￼" and "￼ Jump with decoration",
  and Find Next Link said "￼ hyperlink", "￼ Jump with decoration hyperlink" and "￼
  hyperlink" on the section of pictures, the last for "Described jump". On the hidden-labels
  section Find Next Link did not move to the parked link: VoiceOver said the text area's
  first line again. By word the label was "Parked link to the target" and the pictures
  "image" and "Described jump image", with nothing of a link.
  With the reader's own elements, at `bd27b89`, at the fixed pause, in pages. The first page:
  `ax:links` one child, "Verification link", with `AXPress`; by line "Verification link.
  Image:  Blue verification square image ." and by word "Verification", "link.", as before;
  Find Next Link "Verification link hyperlink" and the hint, and again "Last link
  Verification link hyperlink"; Control-Option-Space from there, and in another session from
  the word "link.", gave `AXValueChanged` with `word1187` to `word1200` and the page whose
  third line is "Link target reached". The hidden labels: by word "closing", "words.",
  "hyperlink Parked link to the target", "Shown"; by line and in Read All "hyperlink Parked
  link to the target Shown last words."; Find Next Link from the top of the page "Parked
  link to the target hyperlink" and the hint, Control-Option-F3 "hyperlink is in the
  VoiceOver cursor", and Control-Option-Space the target's page. The pictures: `ax:links`
  three children, "image", "Jump with decoration" and "Described jump, image"; by line "Bare
  jump:  hyperlink image", "hyperlink  Jump with decoration", "hyperlink Described jump,
  image" and "Titled decoration   passed over."; by word "Bare", "jump:", "hyperlink image",
  "hyperlink", "Jump", "with", "decoration", "hyperlink Described jump, image", "Titled";
  Read All the same lines; Find Next Link "image hyperlink", "Jump with decoration
  hyperlink", "Described jump, image hyperlink", the first and third followed by "actions
  available" before the hint; the actions menu on the third "Actions menu 2 items", "Inspect
  Image: Described jump", "press"; Control-Option-Space on "hyperlink image", reached by
  word, the target's page. `ax:follow` on each section's link gave the same page with
  VoiceOver's cursor elsewhere.
  In continuous scroll at the same revision, opened at a section with `-SampleHref`. The
  text's children were the links of the paragraphs on screen, three with the pictures there,
  one with the hidden labels and one on the first page, while the text's string gave a link
  element at every link of the book. By word, by line and in Read All VoiceOver said what it
  said in pages: "Verification", "link."; "hyperlink Parked link to the target"; "hyperlink
  image", "hyperlink" before "Jump", "hyperlink Described jump, image". Find Next Link gave
  the same names with "hyperlink", and Control-Option-Space from there, and from the word
  "link.", scrolled the view to the target: the insertion point's line was then "Link
  target reached" (`ENTRY`).
  Find Previous Link went forward. From the third link it said "image hyperlink", the
  first, where Find Next Link goes past the last. Main's reader, through AppKit's own
  elements, did the same at `a49d12e`: from the third link "￼ hyperlink" and then "￼ Jump
  with decoration hyperlink", the first and the second. It is VoiceOver's doing on macOS
  27.0.1, as its Find Previous Heading asked the reader for the next heading.
  What did not work, each heard once and left out: a link element given as the attachment of
  a link's words, with a name and without one, over all of them and over the first letter
  (`0b50784`: the first page read as before, by word, by line and in Read All); the same
  over words that follow an attachment (`71f9b77`: VoiceOver said "hyperlink Jump with
  decoration" and then "Jump with decoration" again); and a rotor of links (`8acc907`), with
  the links' characters as its results (Find Next Link "image", "Jump with decoration", "Described jump
  image", without "hyperlink", and Find Previous Link "Link not found") and with the link
  elements as its results (Find Next Link "Link not found", the rotor's list "Link menu",
  "On item image hyperlink").
  Not heard: listening; a workstation; link settings other than Speak, of which Play Tone
  and Change Pitch leave nothing in a transcript; a link in a table cell or a note's
  popover; a link that wraps onto a second line or crosses a page's end, which the unit
  tests read; and a link below the screen in continuous scroll.
- On 2026-10-13 the reader's named actions were looked for on a Mac. `NativeSurface` names Next
  Page and Previous Page with SwiftUI's `accessibilityAction(named:)` in both flows, and in
  continuous scroll, which has no pages, the sample's buttons for the same commands are Scroll
  Forward and Scroll Backward. VoiceOver was offered neither action anywhere, in pages or in
  continuous scroll, so nothing is heard under a wrong name and the reader was left as it is.
  [Hosted sessions](#hosted-mac-sessions) on `xcode-27` (image 20261006.0244.1, macOS 27.0.1
  `26A434`, Xcode 27.0), main's reader at `531a534`, at a fixed pause of four seconds, with
  VoiceOver brought to the column by `ax:focus=search ax:focus=0`: runs 38351606579, 38353526126
  and 38354465519, seventeen sessions. Nobody listened.
  What an assistive client is given, from `ax:actions`. In pages: the window, under it `AXGroup
  AXHostingView` with `ACTIONS none`, and under that one `AXTextArea` for each column with
  `ACTIONS AXShowMenu`. In continuous scroll an `AXScrollArea` with AppKit's
  `AXScrollLeftByPage`, `AXScrollRightByPage`, `AXScrollUpByPage` and `AXScrollDownByPage`
  stands between the group and the one text area. It was the same in one column and in two, at
  17 points and at 23, on a later page, two scroll steps into the book of paragraphs, and after
  `"ax:press=Continuous Scroll"` and `ax:press=Paging` with the reader open. `ax:actions=all`
  found a named action on no element of the window while the sample's controls were embedded,
  and with them in the toolbar only the toolbar's own "Move previous", "Move next" and "Remove
  from toolbar". `"ax:action=Next Page"` printed `MISSING action=Next Page` in both flows, where
  `"ax:action=Move next"` printed `ACTION Move next ON AXButton LABEL "Search" STATUS 0` and the
  toolbar's order changed.
  What VoiceOver said. On the column (Control-Option-F3: "text is in the VoiceOver cursor Line
  1") `actions` gave "Actions menu 1 item" and `listdown` "show menu"; three more `listdown`
  gave nothing, and `listclose` "Closing Actions menu". Inside the text, after `in` ("In text
  Page boundary verifica"), the same two phrases; on the right column of two and on its first
  line on the second spread ("word0324 word0325 word0326 word0327 word0328") the same; in
  continuous scroll on the text area, inside it, and on the line "p006w29 p006w30 p006w31
  p006w32 p006w33 p006w34 p006w35" of the book of paragraphs the same. `"listchoose=show menu"`
  opened the text's contextual menu: "show menu text Page boundary verification", "menu (11
  items)", and under two `listdown` "Look Up “wor”" and "Translate “wor”".
  On the group that holds the columns, which `out` reaches in pages ("Out of group", and
  Control-Option-F3 "Open EPUB… button Open Sample button Close button Use Toolbar bu"),
  `actions` was followed by no phrase, three times in two sessions, and no menu opened: in the
  first session the `listdown` keys after it moved the column's insertion point, and VoiceOver
  read from there ("tion", "Read the numbered words across two consecutive"). With the sample's
  controls in the toolbar the same group said "Actions menu 10 items": "cancel" and "press" four
  times, "show menu" and "cancel", which are the actions of the six elements the group then
  holds, in their order: four buttons, the column and a static text. In continuous scroll `out`
  left the cursor on the text area ("You are currently on a text area."), sent once and sent
  twice.
  Not established. Why the actions reach no element: `ReaderCanvasView`, the view the surface
  wraps, is not an accessibility element on Mac, and where SwiftUI puts a named action of such a
  view was not found. A unit-test host does not show it, so no test holds any of this: there the
  hosting view reports no accessibility children, not even the columns, in either flow, and
  neither it, the view SwiftUI hosts the canvas in nor the canvas has a custom action. What
  VoiceOver's own scroll commands do with the scroll area's four actions, and whether it has
  anything to scroll in pages, where no element has a scroll action. Why the group's menu does
  not open with the controls embedded. Whether VoiceOver ignores its Command-F5 under an open
  Actions menu as under a rotor: the runner closes one first, and in the one session left under
  a menu it wrote `STEP listclose, sent by the runner in case the Actions menu is still open`,
  VoiceOver said "Closing Actions menu" and switched off.
- On 2026-10-12 the section with a hidden heading over a table, with its second table, was
  read at 17 points before and after a table's rows became single items: at `2053be8` and at
  `1e3e5c3`, in the [simulator lane](#simulators) (Xcode 27.0, iOS 27.0, an iPhone 17 Pro and
  an iPad Air 13-inch (M4)), in pages and in continuous scroll. Before, in pages, sixteen
  moves forward from Bookmark gave the eight cells of both tables, each an item ("First
  cell" to "Eighth cell link Double tap to activate embedded link"), then "Parked table
  heading", "First cell Second cell Image", "Third cell Fourth cell Image", "Shown words
  after the table.", two lines, "Fifth cell Sixth cell Image" and "Seventh cell Eighth cell
  link Image"; moving back from "Parked table heading" gave "First cell" and then Bookmark.
  In continuous scroll the rows came where they stand, each as an image, and no cell before
  them; but a touch on a cell put the cursor on the cell, and on the iPhone, where reading on
  had scrolled the view, moving back left the text at "Line 02 after the table." by way of
  the second table's four cells. In both flows the rotor offered Select Table Text for every
  cell on screen on any line, in pages after Next Page and Previous Page. After, in both
  flows on both simulators: "Parked table heading", "First cell Second cell", "Third cell
  Fourth cell", "Shown words after the table.", "Line 01 after the table.", "Line 02 after
  the table.", "Fifth cell Sixth cell", "Seventh cell Eighth cell link", "Line 03 after the
  table." and on, with no cell by itself and no "Image", and the same items in reverse on
  the way back, to Bookmark in pages and to the last line of the section before in
  continuous scroll. A touch on the last row put the cursor on the row. There the rotor offered
  Select Table Text: Seventh cell, Select Table Text: Eighth cell link and Follow Table
  Link: Eighth cell link, after Next Page and Previous Page in pages, and on "Line 03 after
  the table." none of the three. Two things are not this change's. In continuous scroll on
  the iPhone, moving back left the text at "Line 02 after the table." for Bookmark in one
  session of two at `1e3e5c3`, as it had at `2053be8`; a session at `1e0eb8c`, seven commits
  of main earlier, and every iPad session read back to the heading. And in continuous scroll
  the rotor offered on every line, before and after, "Verification link", "￼" and "Inspect
  Image"; the first is a link in the book's first section.
- The same day a physical iPad Air 13-inch (M3) (iPadOS 27.2, 1024 × 1366) read the section
  at `1e3e5c3` in both flows as the simulators had, forward and back, and VoiceOver followed
  the link in the cell: with Follow Table Link: Eighth cell link chosen in the rotor, the
  fifth action in pages and the third in continuous scroll, a double tap on the row changed
  the screen and a touch then found "Link target reached". VoiceOver was off afterward. The
  physical iPhone 17 Pro Max (iOS 27.2, 440 × 956) gave no result at first: one run ended in
  "Timed out while enabling automation mode", and a second lost its authorization for UI
  testing after eighteen seconds, with another app's control under VoiceOver's cursor, and
  left VoiceOver on. Later, with the phone free, it read the section at `edb13b1`, which has
  the changes to images, rules and headings merged in, as the iPad had. In pages: "Parked
  table heading" as a heading, the rows where they stand, on to "Line 06 after the table."
  at the foot of the page, and back to Bookmark. In continuous scroll: on to "Line 10 after
  the table." and back past the heading to the last line of the section before. In both
  flows a double tap with Follow Table Link: Eighth cell link chosen opened "Link target
  reached". A notification from another app took the place of one phrase in two sessions, a
  move forward in pages and a step of the rotor in continuous scroll. xcodebuild took nearly
  five minutes to start a session on the phone while the Mac was busy, so a deadline of five
  minutes stopped the first continuous scroll session part way through the rotor and left
  VoiceOver on; the rotor steps were run again alone. Each time VoiceOver was left on it was
  switched off with `devicectl device settings voiceover --disable` and read back as off.
  Nobody listened to any of these sessions.
- On 2026-10-13 the section of entries was read on a Mac before and after a table cell kept
  the elements it gives for its attachments. GitHub's hosted `xcode-27` runner (image
  `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), a window 600 points wide at 17
  points, at the fixed pause, the reader opened at the section. Nobody listened and no
  workstation was used. Before and after were recorded on the same `main` (`aeb57f0`), each
  as one run of the same five sessions: the first row's two cells, the second row's, the
  formula after the table, the first row's first cell in continuous scroll, and the third
  row's two cells with the fourth row's first. The table's second column is narrow there:
  its cells wrap after "Sum" and the formula, after "Seen entry" and after "Undescribed",
  so a cell's first line is not all of it.
  Before, at `c5e984e`, which is that `main` with the section and nothing else, run
  38357791945. On entering the first row: "In Table row group 2 items text Upper part
  closes." and a phrase with nothing in it. In the rule's cell by line: "Upper part
  closes.", a phrase with nothing in it, "Lower half opens."; by word: "Upper", "part",
  "closes.", a step with no phrase, "Lower", "half", "opens."; `readall`: the three phrases
  heard by line. The formula's cell: "text Sum stated." on moving to it, "In text Sum" and
  "Sum" for its first line, by word "Sum", a step with no phrase, "stated.", and `readall`
  "Sum stated.". The picture's: "In Table row group 2 items text Drawn shown.", by word
  "Drawn", a step with no phrase, "shown.", `readall` "Drawn shown.". The hidden label's:
  "text Seen entry words.", by line "Seen entry" and "words.", no phrase for `firstword` or
  the step after it, then "Seen", "entry", "words.", and `readall` "Seen entry words.". The
  decoration's: "Ornament passed.", by word "Ornament", a step with no phrase, "passed.".
  The undescribed picture's: "text Undescribed stands.", by line "Undescribed" and
  "stands.", by word "Undescribed", a step with no phrase, "stands.". The cell that holds a
  table: "In Table row group 2 items text" and no more, "In text", and no phrase for the
  line, a word or `readall`. In continuous scroll the rule's cell read as in pages, a
  phrase with nothing in it on the rule's line and in `readall`.
  After, at `9cd0493`, run 38357859452. On entering the first row: "In Table row group 2
  items text Upper part closes." and "Separator". In the rule's cell by line: "Upper part
  closes.", "Separator", "Lower half opens."; by word: "Upper", "part", "closes.",
  "Separator", "Lower", "half", "opens."; `readall`: the three phrases heard by line. The
  formula's cell: "text Sum x squared image stated." on moving to it, "Sum x squared image"
  for its first line, by word "Sum", "x squared image", "stated.", and `readall` "Sum x
  squared image stated.". The picture's: "In text Drawn Blue entry square image shown.", by
  word "Drawn", "Blue entry square image", "shown.", and the same line for `readall`. The
  hidden label's: "text Parked entry words. Seen entry words.", by line "Parked entry
  words. Seen entry" and "words.", "Parked entry words." for `firstword`, then "Seen",
  "entry", "words.", and `readall` "Parked entry words. Seen entry words.". The
  decoration's as before: "Ornament passed.", with one step by word that has no phrase.
  The undescribed picture's: "text Undescribed image stands.", by line "Undescribed" and
  "image stands.", by word "Undescribed", "image", "stands.", and `readall` "Undescribed
  image stands.". The cell that holds a table: "In Table row group 2 items text Inner one
  Inner two", "In text Inner one Inner two", and the same words for the line; no further
  phrase was recorded for a word or `readall`, which a repeat of those words would not be.
  In continuous scroll the rule's cell: "Separator" after the row's first words on
  entering, on the rule's line and in `readall`.
  The same before and after: the formula in the page's own text, "In text Beyond them y
  cubed image ends.", by word "Beyond", "them", "y cubed image", "ends."; so a formula in a
  cell is now read as one outside a cell is. Leaving the picture's cell VoiceOver said "Out
  of text" and "actions available", for the cell's own Inspect Image action. The `LINE`
  lines of the page are the same: each row is two characters of the page's text, the row
  and the break after it. From the third row, two `out` steps and `right` reached the
  fourth; VoiceOver said "Undescribed" there, the first word of the cell it had left, and
  after the change "Table row" as well.
  Why a cell's elements were not read was found first, on `main` at `7b0cce2` with the
  section as it then was: three rows, and "Entries are over." after the table. A cell
  differed from a page's text in two things, and each was changed alone, with a rule given
  the element it has outside a table in both and nothing else touched, three sessions
  each: the rule's cell, the formula's and the picture's. With the elements kept from one
  read to the next and given no frame, at `0c979b4`, run 38356001122: "Separator" on
  entering the row, by line, by word and with `readall`; "Sum x squared stated." and "x
  squared" by word; "Drawn Blue entry square shown." and "Blue entry square" by word. The
  elements were then static text labelled with the attachment's words, so nothing said
  "image". With a new element for every read, as before, and each given the frame of its
  character, at `a46659e`, run 38356030625: a phrase with nothing in it and a step with no
  phrase in every one of those places, as on `main`.
  The section was the book's sixth and last in all of these sessions. `main` at `0128fa6`,
  merged in afterwards, has "What each line offers" as its sixth, so the section of entries
  is the seventh, with the same content and still opened by name. That merge changes
  nothing in a cell's code, and the sessions were not recorded again on it.
  Not heard: the Inspect Image action of a picture in a cell chosen through VoiceOver; a
  picture, a formula or a hidden label inside a link in a cell; a part of a cell cut at a
  page's end; a formula without `alttext`, whose reading is generated; a rule or a picture
  in a table inside a cell; and an iPhone or iPad, where nothing changes.
- On 2026-10-12 and 13 pages were turned under VoiceOver's cursor before and after the
  reader sent the cursor to the page shown
  ([#449](https://github.com/vocaro/EPUBLib/issues/449)). The device is the physical iPad Air 13-inch
  (M3) of the sessions above (iPadOS 27.2, 1024 × 1366, upright, 17 points, Xcode 27.0),
  through XCTest's VoiceOver service, on the book's first section. Nobody listened.
  Before, at `707e776`. With the cursor on "word0001 …", the first numbered line of the
  first page, `flick=down` read "Next Page" and a double tap performed it: the page showed
  `word0294`–`word0654`. The screenshot shows VoiceOver's cursor drawn where the old line
  had stood, across the eighth and ninth lines of the new page, and three moves forward
  each read "VoiceOver Page Boundary Verification", the book's title under the page. With
  the cursor then put on "word0450 …" in the middle of that page (`point=0.5:0.5`), Next
  Page showed `word0655`–`word1012` with the cursor drawn at the same place, now over
  "word0818 …", and the three moves read "word0850 …", "word0842 …" and "word0850 …":
  four lines below the cursor, the line above that, and the first again. From "word0818
  …", Previous Page showed `word0294`–`word0654` with the cursor over "word0450 …", and
  the moves read "word0474 …", "word0466 …", "word0474 …". Those two pages are full of
  lines of eight and nine words. The reader answered for an element of the page before by
  its characters counted from the top of its own page (`index(ofAccessibilityElement:)`),
  and on such pages those are the characters of a line of the page turned to. A unit test
  now holds the answer to the line's place in the book.
  Before again, at `7fa9231` with the probe's `listen` step, the `main` the change was
  last merged with. VoiceOver said nothing by itself after either turn. From "word0001 …"
  the three moves read "word0573 …", "word0565 …", "word0573 …", near the foot of the page
  that begins at `word0294`, where the first session had read the title; from "word0450
  …", "word0939 …", "word0931 …", "word0939 …". The line it came to was not the same from
  one session to the next, and was the page's first in none. With Previous Page chosen
  and performed from "word0818 …", a second double tap with no flick before it turned the
  page again, to `word0001`–`word0293`: on the line left behind the rotor stayed where it
  was.
  A page turned by the control strip's button needed no change. With the cursor taken
  from a line to the button (`activate=Next Page`), VoiceOver stayed on "Next Page Button",
  and moving forward read the strip's eight other controls and then "word0294 …",
  "word0302 …", "word0310 …", "word0319 …": the new page from its first line. After
  Previous Page it said "Previous Page dimmed", and moving forward read the controls again
  and "Page boundary verification Heading".
  After, at `7466dea`, the same steps with `listen=4` after each double tap. From "word0001
  …", Next Page: VoiceOver read "word0294 word0295 … word0301" by itself, the screenshot
  shows its cursor on that line, the first of the page, and the three moves read "word0302
  …", "word0310 …", "word0319 …". From "word0450 …", Next Page: it read "word0655 …", and
  the moves "word0663 …", "word0671 …", "word0680 …". From "word0818 …", Previous Page: it
  read "word0294 …", and the moves "word0302 …", "word0310 …", "word0319 …". After a link:
  with the cursor on "Verification link", a double tap showed the book's last page,
  `word1013`–`word1200`, and VoiceOver read "Link target reached Heading" by itself, the
  line of the link's target, below the twenty-one lines of words that begin that page; the
  next moves read "This is the end of the numbered paragraph." and the book's title. A
  turn by the control strip's button read as it had: VoiceOver stayed on "Next Page
  Button", moving forward read the eight controls and then "word0294 …", "word0302 …",
  "word0310 …", "word0319 …", and after Previous Page "Previous Page dimmed", the controls
  and "Page boundary verification Heading". On its side (1366 × 1024), where the first
  spread shows `word0001`–`word0147` beside `word0148`–`word0350`: with the cursor on
  "word0232 …" in the right-hand page, Next Page showed `word0351`–`word0553` beside
  `word0554`–`word0756`, VoiceOver read "word0351 …" by itself, the first line of the
  left-hand page, and the moves read "word0358 …", "word0365 …", "word0372 …". A last
  session at `a38fa29`, after `main`'s change to the scroll bar of continuous scroll had
  been merged into the same file, read the same, upright: "word0294 …" after Next Page
  from "word0001 …" and the three lines after it; and after Previous Page from "word0450
  …", "Page boundary verification Heading", the first line of the first page, then "Read
  the numbered words across two consecutive pages. The next page must resume at the",
  "next numbered word." and "Verification link Link".
  What the change costs was seen in these sessions. The cursor is on a new item after a
  turn, and VoiceOver's rotor is at its default there: with Previous Page chosen and
  performed from "word0818 …", a second double tap, with no flick before it, read the
  first line again and left `word0294`–`word0654` on screen, where before the change it
  had turned the page again. A listener turning several pages from the text now flicks
  down before each double tap. On the control strip's button the cursor stays on the
  button, and double taps turn page after page as they did.
  The [simulator lane](#simulators) read the same change another way, since a simulator's
  VoiceOver performs no action: the cursor is put on a line, and `doubletap=Next Page`
  lands one plain touch on the control strip's button while the cursor stays on the line.
  That is a page the host turns under the cursor, which the reader treats as it does a
  line's own turn. iPhone 17 Pro simulator, iOS 27.0, 402 × 874, 17 points. Before, at
  `0128fa6` with the probe's `listen` step: from "word0001 …" VoiceOver said nothing, and
  the moves read "VoiceOver Page Boundary Verification", "word0061 …", "word0065 …", on a
  page that begins at `word0017`; from "word0025 …", the third line of that page, the
  moves read "word0093 …", "word0089 …", "word0093 …" on the page that begins at
  `word0081`; and after Previous Page "word0029 …", "word0025 …", "word0029 …". After, at
  `7466dea`: VoiceOver read "word0017 word0018 word0019 word0020" by itself, the first line
  of the page, and the moves read "word0021 …", "word0025 …", "word0029 …"; from "word0025
  …" it read "word0081 …" and the moves "word0085 …", "word0089 …", "word0093 …"; and
  after Previous Page "word0017 …" and the same three.
  The order of the two things VoiceOver's scroll posts was tried there too, in a build
  with a switch for what is posted (not in the branch). The page's number and then the
  line: "Page 2", then "word0017 word0018 word0019 word0020", and the moves read on from
  the second line. The line and then the number: the line alone, and no "Page 2". The
  number alone, which is all the scroll posted before: "Page 2", and VoiceOver's cursor
  stayed at its place on the screen, so that from the third line of one page the next
  move read the fourth line of the next, "word0093 …", and not its first.
  Not established: VoiceOver's three-finger scroll itself, which XCTest cannot perform
  ([#70](https://github.com/vocaro/EPUBLib/issues/70)), before the change or after it; a
  physical iPhone; a page turned by a key with the cursor in the text; and Switch Control
  or any other assistive technology that keeps a cursor. VoiceOver was read back as off
  after every device session.

The harness uses Apple's [native VoiceOver service](https://developer.apple.com/documentation/xcuiautomation/xcuivoiceoverservice).
The observer checks the [value-change notification contract](https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/notification/valuechanged).
