# VoiceOver testing

Use real VoiceOver speech to verify the paginated reader on a Mac, physical iPhone and
physical iPad. Native accessibility API tests and simulator runs support this work but do
not establish what VoiceOver reads. The remaining Mac checks are tracked by
[#55](https://github.com/vocaro/EPUBLib/issues/55); the complete acceptance matrix is in
[#28](https://github.com/vocaro/EPUBLib/issues/28).

## Isolated reader and fixture

`Examples/VoiceOverVerification` reuses the normal reader sample's shared interface with
separate application identifiers and a bundled synthetic EPUB. It opens the fixture at launch
without a file-picker interaction. The book contains `word0001` through `word1200` in one
justified paragraph, a heading, an internal **Verification link**, and an image labeled
**Blue verification square**. Its long paragraph retains the continuation context that
originally exposed off-page text. Do not import private books for this check.

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

Reserve a short interval with exclusive control of the reader. Use one automation controller;
do not run competing agents or manual VoiceOver commands during a probe. Normally launch a
fresh reader before attaching XCTest; close previous verification instances first.
The initial Mac XCTest relaunch returned an empty
accessibility tree; attaching to a normally launched reader worked.

```sh
open -na "$PWD/.build/voiceover/mac/Build/Products/Debug/VoiceOverVerificationMac.app" \
  --args -SampleFlow paginated -SampleFontSize 17
python3 scripts/run-voiceover-mac.py --timeout 150
```

The outer Python runner reads the original VoiceOver state, temporarily toggles it through
the approved System Events shortcut if needed, and restores that state in `finally`. It
stops only its own XCTest process group when the deadline expires. It never edits system
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

The probe records `XCUIVoiceOverService.Output.utterance` in a JSON test attachment and prints
`VOICEOVER_EVENT` lines. On Mac it focuses a column away from page-turn edges, enters it once,
reads the **current** line before advancing, then records the final line and attempted movement
beyond the column. The committed current-line step improves the earlier diagnostic sequence;
its live results still need the #55 retest. A successful diagnostic test is not an acceptance
result. Read and compare the transcript with the visible text.

Use a narrow window, approximately 600 points, and `-SampleFontSize 23` for the larger-text
single-column case; use approximately 1100 points and 17-point text for two columns. Confirm the
actual number of columns in `MAC_COLUMN_COUNT`, because wrapping and viewport height change
the numbered boundaries. Restart the isolated reader between cases. For a continuation page,
turn Next before attaching the probe and record the resulting visible range independently.

## Page actions and value notifications

Observe the real application's accessibility transport with the read-only Mac observer:

```sh
VOICEOVER_READER_PID=$(osascript -e \
  'tell application "System Events" to tell process "VoiceOverVerificationMac" to return unix id')
xcrun swift scripts/voiceover-ax-observer.swift "$VOICEOVER_READER_PID" 30 \
  > .build/voiceover/ax-events.log
```

The observer accepts only the verification reader's bundle identifier and runs for a bounded
duration. After `READY`, exercise Next, Previous, Next. Check successful registration status
and `AXValueChanged` events with the new bounded text, in addition to selection/layout events.
Subscribe before the first turn. Repeat after resizing and a text-size change. A final changed
value alone does not prove that the notification was delivered.

For an independent action check, inspect the reader's current button hierarchy and invoke its
native `AXPress` action through System Events. Identify Next/Previous by their `AXHelp` values;
button indexes can change and must not be reused blindly. Then read the text areas' current
values. This verifies the native action, not that VoiceOver's own action selection works: verify
VoiceOver Next/Previous actions separately for acceptance.

XCTest returned stale first-page values after actual page turns in the initial session, while
fresh System Events reads and the observer showed the correct page. Compare these independent
reads before diagnosing a reader failure. Three observed value transitions emitted selection
and layout events but no value-change event. The fix now posts `NSAccessibility.valueChanged`
after paginated storage installation; whether it resolves XCTest caching remains unverified.

## Physical iPhone and iPad

Choose each connected device explicitly and run the native probe on it:

```sh
xcodebuild -project Examples/VoiceOverVerification/VoiceOverVerification.xcodeproj \
  -scheme VoiceOverProbeIOS -destination 'platform=iOS,id=YOUR_DEVICE_ID' \
  -derivedDataPath .build/voiceover/ios -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$VOICEOVER_TEAM_ID" \
  -only-testing:VoiceOverProbeIOS/VoiceOverProbe/testCaptureNavigation \
  -resultBundlePath .build/voiceover/iphone-session.xcresult test
```

Use a new result-bundle path for each run, including the iPad. The native service enables
VoiceOver if necessary and restores its original state on normal test completion. Put a
deadline around device runs and independently check the device state afterward, especially
after cancellation. A user must enter any required XCTest UI Automation passcode directly
on the device. Never collect it in logs or chat.

The mobile probe records forward navigation until speech repeats or reaches its step limit.
It does not automatically cover page actions, every layout or every text size. Ensure the
search field is not editing and the software keyboard is dismissed before evaluating reading
order. The first iPad capture began with search focused and a keyboard visible, so it could
not establish clean column order. Use physical-device sessions for acceptance.

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

## Harness pitfalls and current results

- Control–Option–Shift–Down enters text; repeating it does not read successive lines.
  Control–Option–L reads the current line and Control–Option–Down moves to the next line.
  Reading the current line first matters when that line contains only one numbered word.
  See [Apple's text commands](https://support.apple.com/en-ca/guide/voiceover/cpvokys06/mac).
- Mac synthesized keystrokes took about 10–15 seconds. Delayed help hints sometimes replaced
  the initial phrase in `currentSpeech()`, and long phrases were incomplete in the capture.
  Treat missing speech as inconclusive until timing/navigation is resolved.
- Focus clicks near the left edge turned back a page. Stay outside the default 56-point edge
  zones; do not reuse stale geometry after a resize.
- System Events navigation/clipboard copying and VoiceOver's `last phrase` AppleScript property
  produced no usable speech in the initial probes, even with the scripting setting temporarily
  changed. They are not a verified replacement for native speech capture. If exploring that
  route, record and restore the setting and clipboard, and reject an unchanged clipboard sentinel.
- On 2026-10-10, the Mac captured headings, link/image labels, right-column entry at `word0086`,
  the last visible `word0223`, and `end of text` at column boundaries. At 23-point text in one
  column, native AX actions moved `0001–0010` to `0011–0075` and back, but speech after advancing
  began at `word0012`; the first word remains inconclusive. The new value notification needs a
  live retest. Physical iPhone speech reached `0001–0036`; iPad focus/keyboard interfered with
  the ordering check. These observations do not complete #28's acceptance matrix.

The harness uses Apple's [native VoiceOver service](https://developer.apple.com/documentation/xcuiautomation/xcuivoiceoverservice).
The observer checks the [value-change notification contract](https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/notification/valuechanged).
