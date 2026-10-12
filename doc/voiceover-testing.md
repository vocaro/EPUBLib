# VoiceOver testing

Use real VoiceOver speech to verify the paginated reader on a Mac, physical iPhone and
physical iPad. Native accessibility API tests and simulator runs support this work but do
not establish what VoiceOver reads. The sessions are recorded in the
[Mac verification](issue-55-voiceover-mac.md) and the
[iPad and iPhone verification](issue-28-voiceover-devices.md); the acceptance matrix is in
[#28](https://github.com/vocaro/EPUBLib/issues/28).

## Isolated reader and fixture

`Examples/VoiceOverVerification` reuses the normal reader sample's shared interface with
separate application identifiers and a bundled synthetic EPUB. It opens the fixture at launch
without a file-picker interaction. The book contains `word0001` through `word1200` in one
justified paragraph, a heading, an internal **Verification link**, and an image labeled
**Blue verification square**. Its long paragraph retains the continuation context that
originally exposed off-page text. A second bundled book, opened with
`-VerificationBook paragraphs`, is for continuous scroll: chapters of forty, forty and six
ordinary paragraphs of forty numbered words each (`p017w23` is the seventeenth paragraph's
twenty-third), so a line in the middle of a paragraph can be told from its first, and the end
of the book is a few screens from the start of its last chapter. Do not import private books
for this check.

Use Xcode 27, OS 27, XcodeGen, Python 3, and a graphical Mac login. Select a signing team for
the UI-test runners and physical-device app. Signed Mac UI tests worked in the initial
session; unsigned runs did not complete. Build and generate from the repository root:

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
on the Mac in the initial session, so the outer runner owns the Mac toggle. Ordinary process
cleanup cannot recover from forcibly killing the runner itself; verify restoration independently:

```sh
defaults read com.apple.universalaccess voiceOverOnOffKey
```

This is a read-only check: `0` means off and `1` means on. Restore the original state, rather
than always disabling VoiceOver. Close only the isolated test reader when finished. If a new
Accessibility, Automation or device-authentication permission is needed, use the normal OS
approval flow; do not edit TCC databases or enable broad developer permissions as a workaround.

The probe only records. It polls `XCUIVoiceOverService.currentSpeech()` and prints each new
phrase as a timestamped `VOICEOVER_EVENT`, while the runner sends its steps in order and
waits `--pause` seconds after each VoiceOver command:

- `in`, `out`: start or stop interacting with the item in the VoiceOver cursor.
- `right`, `left`: the next or previous item; inside text, the next or previous word.
- `line`, `nextline`, `previousline`: read the current line, or move a line and read it.
- `word`, `firstword`, `lastword`: read the word, or move to the first or last visible word.
- `textstart`, `textend`: move to the beginning or end of the text (Control-Option-Shift-Home
  or End).
- `linecount`: Control-Option-F3 twice, the total and visible line counts.
- `readall`: read from the cursor onward.
- `activate=LABEL`: Control-Option-Space, sent only if one of VoiceOver's last two phrases
  contains LABEL, as in `"activate=Next Page"`.
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
`right` steps return from it to the left column.

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
- `larger`, `smaller`: choose the Appearance menu's text-size items.
- `width=POINTS`: resize the window.
- `focus`, `focus=COLUMN`, `focus=search`: give the last column, a numbered column or the
  search field keyboard focus, without a click.
- `lines`: print every accessibility line of each column.
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
runner types. Snapshots re-queried for each read matched the observer after every native page
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
reader lists the lines on screen, with two more each side while VoiceOver's cursor is in the
text. Run the probe (see "Physical iPhone and iPad") in that flow, on the book of ordinary
paragraphs, by adding to its command:

```sh
TEST_RUNNER_VOICEOVER_FLOW=scrolled TEST_RUNNER_VOICEOVER_BOOK=paragraphs \
TEST_RUNNER_VOICEOVER_FONT_SIZE=17 \
TEST_RUNNER_VOICEOVER_STEPS='activate=Scroll Forward,activate=Scroll Forward,wait=2,visible,screenshot,forward=9,visible,screenshot,forward=30,visible,backward=44,visible,screenshot'
```

1. Two scroll steps end in the middle of a paragraph. The first `visible` gives the first and
   last lines on screen; nothing above or below them is listed.
2. Eight moves forward from Scroll Forward cross the sample's other controls and the ninth
   enters the text. Its phrase is the first line on screen, not `w01` of that line's
   paragraph, and the screenshot after it shows the same lines as the one before: coming in
   scrolled nothing.
3. The second `visible` counts four more lines, two each side of the screen, and says how
   many are outside the window.
4. The moves forward give every line once, in order, while the view follows; the moves back
   pass the line VoiceOver came in at and go on above it. A phrase repeated, a line missing,
   or a control's name among them is a failure.
5. `backward=1` straight after coming in returns to the control before the text. A touch on
   a control (`touch=Bookmark`) takes the cursor out, and `visible` then lists the lines on
   screen alone; the next move forward comes in at the first of them.
6. `activate=Contents,activate=Chapter two` moves the reader with the cursor on a control, and
   `point=0.5:0.8` touches a line directly: VoiceOver reads the line under the finger.

Drive at least one session with `flick=right*20` and `flick=left*30` in place of `forward`
and `backward`: those are VoiceOver's own gestures for the next and previous item, where the
others are the test service's moves. They take about six seconds each under XCTest.

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

The probe launches the reader and performs the comma-separated steps, recording VoiceOver's
phrase after each. Without `TEST_RUNNER_VOICEOVER_STEPS` it reads forward from the first item.

- `read`: move forward until VoiceOver repeats itself at the end of the screen.
- `forward=COUNT`, `backward=COUNT`: that many moves to the next or previous item, where
  `read` would go on through a whole book in continuous scroll.
- `visible`: the window size and each column's first and last numbered lines as XCTest sees
  them, to compare with the speech. Lines listed above or below the window, as in continuous
  scroll while the cursor is in the text, are counted apart.
- `touch=LABEL`: touch the first item whose label begins with LABEL. Under VoiceOver a touch
  moves its cursor there; `touch=word` is the first numbered line.
- `activate=LABEL`: touch the item, then double-tap, which is VoiceOver's activation.
- `point=X:Y`: touch a place in the window, as fractions of its width and height, whatever is
  listed there.
- `flick=down`, `flick=up`: one finger steps through the rotor. With the cursor on a line it
  offers the line's actions, Next Page first; `doubletap=LABEL` on that same line then
  performs the chosen one without moving the cursor. On an iPhone in landscape only the
  upward flick registered, which reaches the same actions.
- `flick=right`, `flick=left`: VoiceOver's next and previous item; `flick=right*12` repeats it.
- `rotate=landscape`, `rotate=portrait`: an iPad shows two columns in landscape and one in
  portrait. End a session in the orientation it started in.
- `wait=SECONDS`, and `screenshot`, attached to the result bundle: what is on the glass,
  independent of every accessibility snapshot.

`TEST_RUNNER_VOICEOVER_FONT_SIZE` sets the launch text size, `TEST_RUNNER_VOICEOVER_FLOW=scrolled`
opens the book in continuous scroll and `TEST_RUNNER_VOICEOVER_BOOK=paragraphs` opens the
book of ordinary paragraphs. `TEST_RUNNER_VOICEOVER_OFF=1`
leaves VoiceOver off, so the same steps are plain touches: use it to tell a VoiceOver failure
from one of the reader's own. The probe stops when the reader is no longer in the foreground.
Another session's tests on the same device bring their own app forward or switch VoiceOver
off; discard such a run.

XCTest cannot perform VoiceOver's three-finger scroll, and its synthesized hardware keys
(Control-Option-Space, Option with an arrow) did not reach VoiceOver on an iPad. The probe
turns pages by activating the page buttons or a line's Next Page action. A transcript that
begins in an editing field, with the keyboard's keys after the page, is not a reading-order
result. Use physical-device sessions for acceptance.

## Acceptance and evidence

For each device, exercise supported one- and two-column layouts, normal and larger text,
and a text-size change while the reader is open. Record the build revision, OS/Xcode versions,
device, window size/orientation, font size and visible first/last numbered words.

1. Capture the first spoken line upon entering each column, before advancing. The first
   numbered word must match that column's first visible word.
2. Read successive lines in logical column order. Reach the last visible word, then attempt
   another line; hidden continuation must not become reachable.
3. Activate Next through VoiceOver and verify that the next visible/spoken word is exactly
   the successor of the prior page's last word, without duplication. Check Previous as well.
4. Confirm heading order, the link's label/action and the image's spoken label.
5. Resize or change typography, wait for the new layout, and repeat the boundary and ordering
   checks. On Mac verify corresponding value-change notifications and fresh text values.
6. Restore all original VoiceOver/scripting settings and independently verify restoration.

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
  resting cursor to the window's first control. Neither is a page-boundary failure.
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
- The same day, on the iPad on its side (1366 × 1024), straight after
  `activate=Contents,activate=Chapter two`: the fifth move gave "Chapter two" and seventeen
  more the lines down to `p043w36 … p043w40`, the last that had been on screen when the
  menu closed. The next gave "Vertical scroll bar" and the one after the sample's footer;
  the lines after `p043w40`, listed by then, were passed over. Moving back from there gave
  the lines in order to "Chapter two", then three of them a second time, then went on above
  the heading without a gap. An iPhone 17 Pro simulator (iOS 27.0) does the same after any
  menu closes, even when the chapter chosen is the one on screen, and reads on, as the
  devices did, when VoiceOver comes into the text after a step of the reader's own or
  without a menu having closed. VoiceOver appears to keep the elements it found when the
  menu closed and to walk those while its cursor stays on them. Posting a layout change,
  with no element or with the line under the cursor, did not change that in the simulator;
  a page-scrolled notification made VoiceOver skip lines; giving it new elements for the
  same lines once its cursor had moved on made it lose its place. It is not resolved
  ([#339](https://github.com/vocaro/EPUBLib/issues/339)).
- In the simulator, UIKit scrolled the line VoiceOver's cursor came to until the area inside
  the scroll view's insets held its frame, and then until the line was 40 points below the
  top of that area or about 120 above its bottom. A line that was the first listed when
  VoiceOver took it led back to the control before the text on the next move back, though
  lines had been listed before it since; and when the list shrank to the screen between the
  two halves of a move, VoiceOver stopped at a line it had reached above the screen.
- Not done on a device: a larger text size, VoiceOver's three-finger scroll and its read-all
  gesture, which XCTest cannot make, a book whose lines hold floats or tables, and listening.

The harness uses Apple's [native VoiceOver service](https://developer.apple.com/documentation/xcuiautomation/xcuivoiceoverservice).
The observer checks the [value-change notification contract](https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/notification/valuechanged).
