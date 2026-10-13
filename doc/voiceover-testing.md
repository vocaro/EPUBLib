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
hidden labels alone on a line of no height, and goes on for more than a screen. A fourth,
**Pictures and their words** (`OPS/pictures.xhtml`), holds what a book can say of a picture:
nothing, that it is decoration (an empty `alt`), or words. Each stands in a line of text; a
decorative one is also all that a link holds, and stands beside words in a link; and two come
from a file that has a title of its own, one with an empty `alt` and one with none. None of
the section's words is one VoiceOver uses for a picture or a link, so those in a transcript
are VoiceOver's own. A fifth, **Scenes set apart** (`OPS/scenes.xhtml`), the book's last,
holds rules: an `<hr>` between two paragraphs, one the book gives `role="presentation"`, and
one alone on a page of its own, with a last paragraph on the page after it. None of its words
is one a screen reader uses for a rule either. A second
bundled book, opened with
`-VerificationBook paragraphs`, is for continuous scroll: chapters of forty, forty and six
ordinary paragraphs of forty numbered words each (`p017w23` is the seventeenth paragraph's
twenty-third), so a line in the middle of a paragraph can be told from its first, and the end
of the book is a few screens from the start of its last chapter. The first book's headings
are "Page boundary verification" (level 1), which opens it, "Link target reached" (level 2)
after the numbered paragraph, the two parked ones (level 1), each opening its section, and
"Pictures and their words" and "Scenes set apart" (level 1), each opening one of the last
two; the second book's are "Chapter one", "Chapter two" and "Chapter three", screens apart.
Do not import private books for this check.

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
  again (macOS 27.0.1). Go back with the rotor's list.
- `rotor`: Control-Option-U, which opens VoiceOver's rotor: lists of what the item under its
  cursor holds, the reader's Headings among them. `listright` and `listleft` go from list to
  list, `listdown` and `listup` along one, `listchoose` (Return) moves VoiceOver to the item
  named and `listclose` (Escape) closes the rotor. These six are plain keys. Send them only
  while the rotor is open: otherwise the reader takes an arrow as a page turn. A list with
  nothing in it stays open after `listchoose`: on a page that has no heading the rotor says
  "No items in Heading menu" and Return chooses nothing. VoiceOver ignores its own Command-F5
  while the rotor is open, so the runner closes one before it restores VoiceOver. After the
  steps of a session that sent `rotor` and no `listclose` after it, the runner sends Escape
  itself, writes `STEP listclose, sent by the runner in case the rotor is still open` and
  waits one pause; a session stopped before the end of its steps gets the same key as the
  runner cleans up. Where `listchoose` had closed the rotor, the reader takes that Escape and
  does nothing with it: VoiceOver said nothing and stayed on its line.
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
`right` steps return from it to the left column. **Previous Page** is one step further.

`"ax:press=Use Toolbar"` moves the sample's controls to the window's toolbar, outside the group
that holds the columns. From the left column, `out out`, five `left`, `in` and six `right`
reached Next Page there in three sessions on a reader with the fix of #337; on one without
it the same keys went elsewhere twice. `activate=Next Page` stops such a session.

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
  moves the sample's controls from the reader's group to the window's toolbar.
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

## Hosted Mac sessions

The same reader, probe, observer and runner script record real VoiceOver speech on GitHub's
hosted `xcode-27` runner. A session there takes over no workstation, several can run at once,
and the standard runner costs nothing in this public repository. It is acceptance evidence
for the Mac, under the same rules as a workstation session; see
[Acceptance and evidence](#acceptance-and-evidence). The
[Mac VoiceOver workflow](../.github/workflows/voiceover-mac.yml) builds the reader at a ref,
runs one or more sessions and uploads their transcripts. It starts only by hand:

```sh
gh workflow run voiceover-mac.yml --ref YOUR_BRANCH -f width=600 -f text_size=17 \
  -f steps='ax:next ax:lines ax:focus in line nextline ; ax:next ax:focus in lastword line nextline'
gh run list --workflow voiceover-mac.yml --limit 3
gh run watch RUN_ID --exit-status
gh run download RUN_ID --name voiceover-mac-transcripts --dir .build/voiceover/hosted/RUN_ID
```

`--ref` chooses the branch whose workflow file is used, and that branch is built unless the
`ref` input names another one. The inputs, all optional:

- `ref`: a branch, a tag or a full commit SHA whose reader and probe are built. The runner,
  observer and session scripts still come from the `--ref` branch, so a commit older than this
  workflow can be heard, and two commits compared, with one harness.
- `steps`: the steps `scripts/run-voiceover-mac.py` takes, quoted as on a command line, as in
  `"activate=Next Page"`. A `;` or a line break starts another session. Each session gets a
  fresh reader, and `ax:width` with the `width` input before its own steps. Left empty, one
  session checks a page boundary: the left column's entry line and two lines down, a Next Page
  activated through VoiceOver, and the new page's entry line and second line. The entry line
  after the turn must be the page's first: with the fault of
  [#337](https://github.com/vocaro/EPUBLib/issues/337) it is the third. The session brings
  VoiceOver to the column by `ax:focus=search ax:focus=0`, without which it can pass on a
  reader that has the fault.
- `width` and `text_size`: the window width and the launch text size in points, 1100 and 23
  unless given.
- `flow`: `paginated`, or `scrolled` for [continuous scroll](#continuous-scroll), which needs
  its own steps.
- `pause`: the runner's `--pause`, 5 seconds unless given.
- `advance_after`: the runner's `--advance-after`. Empty keeps the fixed pause.

A job has twenty minutes and a session at most 300 seconds, the runner script's limit.
Preparing the runner and building take about two minutes and the boundary session about three
at the fixed pause, so a run of that one session has uploaded its transcript about five minutes
after it starts. A session that could not end three minutes before the job's limit is reported
as not run, and the job fails. A new run for the same ref, width, text size and flow cancels
one still in progress, so put step lists that share those into one run; runs that differ in
any of them go on side by side.

With `advance_after` set to `0.5`, stepping took about a quarter of the time in four pairs of
sessions, and 95 of 97 keys recorded the same first phrase as at the fixed pause. The hint that
follows a move is cut short, and a phrase VoiceOver repeats is not recorded again. It suits
exploring and walks across controls. A transcript offered as acceptance evidence is recorded
at a fixed pause; see [Acceptance and evidence](#acceptance-and-evidence).

The job fails unless every session exits 0. `sessions.txt` in the download gives each
session's outcome, transcript and command: 124 means the deadline was reached, 125 that the
runner script stopped the session, 2 that it refused the steps, and 126 that VoiceOver would
not switch back off after it ("VoiceOver not restored"). Such a session still has its
transcript, with the reason in a `NOT_RESTORED` line, and the sessions after it in the job
begin with VoiceOver already on and leave it on. The download also holds a
`mac-STAMP.transcript.txt` for each session in order, `runner.txt` with the commit, the runner
image and its version, macOS, Xcode, System Integrity Protection and the screen, the observer,
`xcodebuild` and build logs, and a screenshot of the runner's screen at the end. The job's log
prints each transcript, and the script writes each session's steps and speech to the run's
summary page. The artifacts expire after five days; copy what must be kept. A failed job also uploads
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

These commands change settings of the logged-in user and belong on a disposable runner. Do
not run them on a workstation, where the third does nothing in any case; the workflow's first
step refuses a machine that is not GitHub's. Keep `runs-on: xcode-27`: a larger runner, such
as `xcode-27-xlarge`, is billed even in a public repository. To see what a run cost, expect
`"billable": {}` from:

```sh
gh api repos/vocaro/EPUBLib/actions/runs/RUN_ID/timing
```

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
  them, to compare with the speech. Lines listed above or below the window, as in continuous
  scroll while the cursor is in the text, are counted apart.
- `touch=LABEL`: touch the first item whose label begins with LABEL. Under VoiceOver a touch
  moves its cursor there; `touch=word` is the first numbered line.
- `activate=LABEL`: touch the item, then double-tap, which is VoiceOver's activation. The
  probe goes on once the screen has changed and held still for half a second, after two
  seconds at most, and a `settled` line says which.
- `point=X:Y`: touch a place in the window, as fractions of its width and height, whatever is
  listed there.
- `flick=down`, `flick=up`: one finger steps through the rotor. With the cursor on a line it
  offers the line's actions, Next Page first; `doubletap=LABEL` on that same line then
  performs the chosen one without moving the cursor. On an iPhone in landscape only the
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
   from there shows "Last words of the scenes.". On Mac it says nothing at a rule: moving
   by line it stops between the two scenes without a phrase, and no transcript has
   "Separator" or "image" in it.
9. Headings. On an iPhone or iPad VoiceOver says "Heading" after a heading's words, shown or
   hidden, and reads a heading that takes several lines as one item. With the rotor on
   Headings (`rotor=Headings`, turned after the touch that places the cursor), `flick=down`
   moves to the next heading on the page or screen and then to the next one in the book,
   turning the page or scrolling to it, and `flick=up` goes back the same way; `visible`
   after a move shows the page or screen the reader went to. Past the book's last or first
   heading VoiceOver says "Heading not found". Wait a few seconds after the book opens
   (`wait=8`): a chapter not built yet ends the search. On a Mac `nextheading` moves
   VoiceOver to the next heading in the text area and reads its words, to "Heading not
   found" past the last, and the view shows the heading; `rotor` opens on the Heading menu,
   which lists the page's headings, or the whole book's in continuous scroll, each by its
   words and level, and `listchoose` moves to the one named.
10. Restore all original VoiceOver/scripting settings and independently verify restoration.

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
  table's cells are read before the lines of their page there, whatever those are.
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

The harness uses Apple's [native VoiceOver service](https://developer.apple.com/documentation/xcuiautomation/xcuivoiceoverservice).
The observer checks the [value-change notification contract](https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/notification/valuechanged).
