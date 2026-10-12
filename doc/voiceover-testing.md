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
originally exposed off-page text. A second section, **Hidden labels** (`OPS/labels.xhtml`),
holds what a book hides from the page and keeps for assistive technology: a heading and a
byline parked at `left: -999em` above an image without alternative text, words clipped to
nothing inside a line, and a parked link. It also holds what a book hides from everyone: a
`visibility: hidden` paragraph and an `aria-hidden` one. Do not import private books for
this check.

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
269 at this size. On a simulator or device, `TEST_RUNNER_VOICEOVER_FLOW=scrolled` opens the
fixture in continuous scroll.

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
  session checks a page boundary: the left column's entry line, a Next Page activated through
  VoiceOver, and the new page's entry line and second line. It moves no line before the turn,
  because VoiceOver can come back to a column at the character offset it had there.
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
exploring and walks across controls. The fixed pause stays the default; which pacing a
transcript kept as evidence should use has not been decided.

The job fails unless every session exits 0. `sessions.txt` in the download gives each
session's outcome, transcript and command: 124 means the deadline was reached, 125 that the
runner script stopped the session, and 2 that it refused the steps. The download also holds a
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
phrase after each. Without `TEST_RUNNER_VOICEOVER_STEPS` it reads forward from the first item.

- `read`: move forward until VoiceOver repeats itself at the end of the screen.
- `visible`: the window size and each column's first and last numbered lines as XCTest sees
  them, to compare with the speech.
- `touch=LABEL`: touch the first item whose label begins with LABEL. Under VoiceOver a touch
  moves its cursor there; `touch=word` is the first numbered line.
- `activate=LABEL`: touch the item, then double-tap, which is VoiceOver's activation.
- `flick=down`, `flick=up`: one finger steps through the rotor. With the cursor on a line it
  offers the line's actions, Next Page first; `doubletap=LABEL` on that same line then
  performs the chosen one without moving the cursor. On an iPhone in landscape only the
  upward flick registered, which reaches the same actions.
- `rotate=landscape`, `rotate=portrait`: an iPad shows two columns in landscape and one in
  portrait. End a session in the orientation it started in.
- `wait=SECONDS`, and `screenshot`, attached to the result bundle: what is on the glass,
  independent of every accessibility snapshot.

`TEST_RUNNER_VOICEOVER_FONT_SIZE` sets the launch text size, `TEST_RUNNER_VOICEOVER_HREF`
opens a section other than the first (`OPS/labels.xhtml`) and
`TEST_RUNNER_VOICEOVER_FLOW=scrolled` opens in continuous scroll. `TEST_RUNNER_VOICEOVER_OFF=1`
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

For the Mac, a speech session run on the hosted `xcode-27` runner is acceptance evidence, as
one on a workstation is. Record its runner image and image version, such as `xcode-27-arm64`
20261006.0244.1, beside the OS and Xcode versions; `runner.txt` in the run's download has all
three, and the job's "Set up job" log prints the image. Everything else here applies to it
unchanged. A hosted session that completes is no more an acceptance result than any other:
read its transcript against the visible text. The iPhone and iPad still need physical devices.

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
   title heading" and "By the parked author." before the image, "Clipped words in the line."
   between the two shown sentences, and "Parked link to the target" as a link before "Shown
   last words."; it never reads "Words nobody is given." or "Words kept from assistive
   technology."; and a screenshot shows none of the hidden words.
7. Restore all original VoiceOver/scripting settings and independently verify restoration.

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
- On an iPhone simulator, through XCTest's VoiceOver service and not by ear, moving forward
  from the controls into the text of continuous scroll went to the book's first paragraph and
  scrolled the reader back to it, three screens up
  ([#301](https://github.com/vocaro/EPUBLib/issues/301)).
- On 2026-10-12 the hidden-labels section was read on a physical iPhone 17 Pro Max and a
  physical iPad Air 13-inch (M3), both on OS 27.2, through XCTest's VoiceOver service and not
  by ear: at 17 and at 28 points, in pages and in continuous scroll, and on the iPad in
  landscape with two columns as well as in portrait. In pages, moving forward from the
  Bookmark control: "Parked title heading", "By the parked author.", "Book Image", "Shown
  opening words.", "Clipped words in the line.", "Shown closing words.", "Parked link to the
  target Link", "Shown last words.". At 28 points on the iPhone the line wraps, and the
  clipped words came between "Shown opening words." and "Shown". In continuous scroll
  VoiceOver reads a paragraph at a time, and each label came in the paragraph it stands in:
  "￼ Parked title heading ￼ By the parked author. ￼", "Shown opening words. ￼ Clipped words
  in the line. Shown closing words.", "￼ Parked link to the target Shown last words. Double
  tap to activate embedded link". Neither label hidden from everyone was read in any run,
  the screenshots show the image and the shown words only, and VoiceOver was off on both
  devices afterward. On the iPad the probe needs `touch=Bookmark` before `read`: from the
  first item its cursor stayed on the window's resize control in a simulator. The iPad
  refused UI automation twice that day ("Timed out while enabling automation mode") and ran
  half an hour later with nothing changed from the Mac. Not heard: what VoiceOver voices for
  the attachment character before a label in continuous scroll on iOS.
- The same day the section was heard on a Mac: GitHub's hosted `xcode-27` runner (image
  `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), in three
  [hosted sessions](#hosted-mac-sessions) at `d010812`, in a window 600 points wide at 17
  points. The section is the book's last: fourteen `ax:next` steps reach its page,
  and in continuous scroll `textend` puts VoiceOver on "Link target reached", three lines
  above it. In pages, on entering: "In text Parked title heading By the parked author. Book
  image im", the 64 characters the probe records. By line: "Parked title heading By the
  parked author. Book image image", "Shown opening words. Clipped words in the line. Shown
  closing w", "Parked link to the target Shown last words.", "end of text". By word each
  label is one stop: "Parked title heading", "By the parked author.", "Book image image",
  "Shown", "opening", "words.", "Clipped words in the line.", "Shown", "closing", "words.",
  "Parked link to the target", "Shown", "last", "words.". In continuous scroll the lines
  after "This is the end of the numbered paragraph." were the same three, and Read All gave
  them in order, a sentence at a time. Neither label hidden from everyone is in any
  transcript. Nobody listened, and no workstation was used.

The harness uses Apple's [native VoiceOver service](https://developer.apple.com/documentation/xcuiautomation/xcuivoiceoverservice).
The observer checks the [value-change notification contract](https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/notification/valuechanged).
