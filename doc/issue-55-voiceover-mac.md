# Mac VoiceOver verification for larger text and page notifications

Issue #55 asked for live Mac evidence on two points left open by #28: whether VoiceOver
speaks the first word of a continuation page at a larger text size, and whether page changes
deliver value-change notifications. Both were verified on 2026-10-11 with real VoiceOver
speech, following the [VoiceOver testing process](voiceover-testing.md). Three reader defects
were found on the way and fixed. iPhone and iPad sessions remain with #28.

Environment: macOS 27.0 `26A428` arm64, Xcode 27.0 `27A266a`, default VoiceOver settings, one
2560×1440 display, the isolated `Examples/VoiceOverVerification` reader and its synthetic
fixture. A 600×882 window gives one 558-point column; 1100×882 gives two 472-point columns.
Reader revisions: `719225b` before the fixes, `ae8246e` with the layout change, `1ea923c` final.

## The first word

VoiceOver speaks `word0011`. At 23 points in one column, page 1 ends with `word0010` and page
2 shows `word0011–word0075` in thirteen five-word lines. On every revision, entering page 2
spoke "In text word0011 word0012 word0013 word0014 word0015", Control-Option-L repeated that
line, Control-Option-Right spoke "word0011" then "word0012", and Control-Option-Left returned
to "word0011" and "beginning of text".

The earlier `word0012…` capture came from the probe, in two ways:

- XCTest returns from a synthesized VoiceOver key about ten seconds later (9.45 s to 19.60 s
  for Control-Option-L), since VoiceOver consumes the key. By then VoiceOver has spoken a hint,
  "You are currently in a text area. To enter text in this area, ty…", about two seconds after
  the move, and `currentSpeech()` returns that instead of the entry phrase.
- The probe's focus click moved the insertion point into the first line. Reproduced at the
  same normalized offset, the click put it at character 22, inside `word0013`. Entering still
  read the whole line, but the first Control-Option-Down read the rest of that line from the
  insertion point, "word0013 word0014 word0015", rather than the second line.

The probe now only records speech while the runner sends commands, and the observer gives a
column keyboard focus without a click.

## Reader defects found and fixed

**The previous page read again after a turn.** On `719225b`, read to the end of a column, stop
interacting, move the VoiceOver cursor to another item, turn the page and return. VoiceOver
spoke "text word0011 word0012…" and entered at "In text word0071 word0072 word0073 word0074
word0075" while the page showed `word0076–word0140`; its line and word commands kept reading
the previous page. It happened with VoiceOver's own activation of Next Page and with a native
press, though `AXValueChanged` had arrived with the new text and external reads were fresh. It
did not happen when VoiceOver's text cursor had stayed at the start, or when it was
interacting with the column during the turn. Posting the value change before the caret reset
or again later did not help reliably. The canvas now posts a layout change naming the visible
columns after installing a spread (`ae8246e`). In repeated cycles and in every case below
VoiceOver then read the new page from its first line. It also says "2 updated items" for two
columns, or repeats the item under its cursor.

**A nonsensical line count.** VoiceOver described a column as "text 9,223,372,036,854,775,808
visible lines". That is one more than `NSNotFound`, which was the line reported for the
insertion point after the page's last character. It is now on the last line (`1ea923c`);
Control-Option-F3 twice reports "8 lines 8 visible lines", "13 lines 13 visible lines", "14…",
"19…" and "21…", matching the observer's line counts.

**Silence after the page became shorter.** VoiceOver restores its own text cursor when it
enters a column. With that cursor at the end of a 21-point column, a text-size increase left
its offset beyond the new page: the caret was refused, the offset had no line, and entering
said "In text" and nothing else. Such a caret is now kept on the page and reads its last line.

## Verified layouts

All on `1ea923c`. Each column was entered through the observer's `focus` step; "Next" was
activated by VoiceOver on the Next Page button unless noted. Every last line was followed by
"end of text"; in the one-column layouts Control-Option-Shift-End also stayed on it.

| Layout | Entry line | Last line | After Next |
| --- | --- | --- | --- |
| 23 pt, one column, page 1 | Page boundary verifica | word0006 … word0010 | Page Down: word0011 … word0015, last word0071 … word0075 |
| 17 pt, one column, page 1 | Page boundary verification | word0055 … word0060 | word0061 … word0066, last word0179 … word0185 |
| 17 pt, two columns, left | Page boundary verification | word0081 … word0085 | word0224 … word0228, last word0349 … word0353 |
| 17 pt, two columns, right | word0086 … word0090 | word0219 … word0223 | word0354 … word0358, last word0479 … word0483 |
| 23 pt, two columns, left | Page boundary veri | word0025 … word0028 | word0101 … word0104, last word0169 … word0172 |
| 23 pt, two columns, right | word0029 … word0032 | word0097 … word0100 | word0173 … word0176 |

Each first word after a boundary is the successor of the last word before it, with
"beginning of text" before it; no numbered word was repeated or skipped, and no continuation
line was reachable. On `ae8246e` the same held for 23-point pages 3 to 4
(`word0136 … word0140`, then `word0141 … word0145`), and page 1 read line by line: the heading,
the paragraph, "Verification link. Image:  Blue verification square image ." and the numbered
lines. Page Up and Page Down with reader focus turned pages while VoiceOver stayed in the
column and read the new first line.

Changes while the reader was open: in two columns the text size went 19, 21 and 23 through
the Appearance menu on `ae8246e`, and 21 to 23 and back on `1ea923c`; the window went between
1100 and 600 points at 23 points on `1ea923c`. After each, the columns read their new first
and last lines: for example `word0037 … word0040` to `word0114 … word0118` on the right at 21
points, and the one-column pages above after the resize.

## Page value notifications

Native Next, Previous and Next presses, VoiceOver's own activation, the page keys, each
text-size change and each resize delivered `AXValueChanged` for every changed column with its
new bounded text, on both the column and application registrations, 0.1 to 0.5 seconds after
the step was sent. A column hidden by a narrower window reports an empty value. For example,
after VoiceOver activated Next Page in two columns at 17 points (values abbreviated):

```
07:39:35.910Z STEP activate=Next Page
07:39:36.274Z EVENT AXValueChanged VIA TEXT 0 SELECTION 0,0 … WORDS word0224–word0353 COUNT 130
07:39:36.275Z EVENT AXValueChanged VIA TEXT 1 SELECTION 0,0 … WORDS word0354–word0483 COUNT 130
07:39:36.321Z heard: 2 updated items
```

XCTest's own column values, re-queried for each read, followed every native page turn,
text-size change and resize within about 0.3 seconds and matched the fresh external reads;
one read in between paired a new right column with the previous left one. They did the same
on a scratch build with the value and layout notifications removed. The stale first-page
values of the initial session were therefore not caused by the missing notification and were
not reproduced; a value held from an earlier query is the likely source. They are not
page-turn failures.

## Coming back to a column after a page turn

Found on 2026-10-12 and fixed in [#337](https://github.com/vocaro/EPUBLib/issues/337).
Everything in this section was heard in [hosted sessions](voiceover-testing.md#hosted-mac-sessions)
on GitHub's `xcode-27` runner (image 20261006.0244.1, macOS 27.0.1 `26A434`, Xcode 27.0
`27A266a`, windows 850 points high) at the fixed pause, and none of it on a workstation.

VoiceOver keeps a text cursor of its own in a column it has left. The case: interact with a
column, move down two lines, stop interacting, move to a page button, activate it, come back
and interact again. On `740c073` VoiceOver then set the column's insertion point to the offset
it had on the page before (`SELECTION`) and read from that line, where the new page's first
line was expected. With the fix (`6c8068d`, then `97635e7` and `a745cde` as `main` was merged
into it) it sets none and reads the first line:

| Layout and turn | New page | `740c073` | With the fix |
| --- | --- | --- | --- |
| 23 pt, two columns, left, Next Page | `word0229–word0296` | `72,0`, "In text word0237 word0238 word0239 word0240" | "In text word0229 word0230 word0231 word0232" |
| 23 pt, two columns, right, Next Page | `word0297–word0364` | `72,0`, "In text word0305 word0306 word0307 word0308" | "In text word0297 word0298 word0299 word0300" |
| 23 pt, two columns, left, Previous Page | `word0093–word0160` | `72,0`, "In text word0101 word0102 word0103 word0104" | "In text word0093 word0094 word0095 word0096" |
| 17 pt, one column, Next Page | `word0172–word0285` | `108,0`, "In text word0179 word0180 word0181 word0182 word0183 word0184 wo" | "In text word0172 word0173 word0174 word0175 word0176 word0177 wo" |
| 17 pt, one column, Previous Page | `word0055–word0171` | `126,0`, "In text word0067 word0068 word0069 word0070 word0071 word0072" | "In text word0055 word0056 word0057 word0058 word0059 word0060" |
| 23 pt, two columns, left, Next Page pressed natively from one item away | `word0229–word0296` | `72,0`, "In text word0237 word0238 word0239 word0240" | "In text word0229 word0230 word0231 word0232" |
| 23 pt, two columns, left, Larger Text from one item away | `word0071–word0127` | `72,0`, "In text word0079 word0080 word0081" | "In text word0071 word0072 word0073 word0074" |

So it took neither VoiceOver's own activation of the button nor a walk across the controls.

A cursor resting on the column during the turn is another matter, and unchanged: after `out`
and then Page Down, or a native press of Next Page, both commits set `72,0` and said "In text
word0237 word0238 word0239 word0240" ([below](#what-remains-voiceovers-own)).

The sessions of 2026-10-11 above read the first line in this case for a reason that has since
gone. Until [#67](https://github.com/vocaro/EPUBLib/pull/67) the control strip's search field
showed "Search queued…" during every command, so each page turn changed the SwiftUI group that
holds the strip and the columns, and that group posted two layout changes of its own. VoiceOver
gives up the cursors it keeps in a group's text areas when that group posts a layout change,
and keeps them when the window posts one, which is all the canvas did: `8896d61` (#61) reads
the first line and `eab6c48` (#67) the third, with one commit and a merge between them not
heard. Posted by the window, a change naming the columns, the group or the window itself, a
second one, a later one, and one with the columns announced as created all left the cursor
where it was; so did one posted by each column.

The canvas now posts its layout change, still naming the visible columns, from the element
that holds them. On a turn VoiceOver says what it said before: "2 updated items" in two
columns, the item under its cursor in one. Page Down and Page Up while interacting still move
it to the new page's first line ("word0229 word0230 word0231 word0232", then back to "word0093
word0094 word0095 word0096"), and continuous scroll still enters at the first line on screen
("In text word0072 word0073 word0074 word0075 word0076"). One thing is new: a VoiceOver cursor
on the group itself, where it often is when VoiceOver has just started, moves to the left
column on a page turn and reads its text.

A session that opened with VoiceOver's cursor already on the text read the first line in this
case without the fix too: in one column on `b79fcf9`, `9b581c4` and `740c073`. The sessions in
the table therefore bring VoiceOver to the column by a focus change from somewhere else:
`ax:focus=search ax:focus=0`, or `ax:focus` alone in a session that began on a control.

A review of the fix asked about what had not been heard
([#373](https://github.com/vocaro/EPUBLib/issues/373)). Heard since, on the same runner and
image at the fixed pause:

- **Page controls in the window's toolbar.** The sample's Use Toolbar takes the page buttons
  out of the group that holds the columns. With Next Page pressed natively from one item
  away, `740c073` set `72,0` and said "In text word0237 word0238 word0239 word0240"; with the
  fix VoiceOver said "In text word0229 word0230 word0231 word0232". It said the same with its
  cursor on the toolbar during the press, and with Next Page activated through VoiceOver
  inside the toolbar. So it gives the cursor up wherever its own cursor is when the group
  posts.
- **Continuous scroll does not have the fault.** On `1b7bf07`, the merge of the fix, with
  VoiceOver brought to the text by `ax:focus=search ax:focus`, two lines moved, and Scroll
  Forward activated through VoiceOver from eight items away, it entered at the new first
  line, "In text word0131 word0132 word0133 word0134 word0135". It did the same with Scroll
  Forward pressed natively from one item away. There the window posts the layout change, and
  still does.
- **A cursor on the group.** It moved into a column when a spread was installed: the left one
  on page turns, the right one when the reading area changed size as the controls moved to
  the toolbar. On `740c073` it stayed on the group and said "2 updated items".

Not heard: whether VoiceOver also gives up a cursor it keeps in another text area of the same
group, a host's notes field for one. It would then enter that text at its insertion point,
which VoiceOver moves with its own cursor as it reads; the reader moves only its own columns'.
Nor a position shown on the page already on screen, which installs the page again: back in a
column it had left, VoiceOver would enter at the page's first line and not at its own offset.

## What remains VoiceOver's own

- If the page changes while the VoiceOver cursor rests on a column without interacting,
  entering resumes at the character offset VoiceOver had on the previous page: "In text
  word0172 word0173 word0174 word0175 word0176" on a column starting at `word0119`, or the
  last line when the new page is shorter. Control-Option-Home returns to the first visible
  word. Leaving the column, or interacting during the turn, starts at the first line; from
  #67 until #337 leaving it did not ([above](#coming-back-to-a-column-after-a-page-turn)).
- A window resize moved a cursor resting on a column to the window's first control, with and
  without the reader's layout change.
- VoiceOver completes a word broken across lines without a hyphen: "…at the next num", then
  "numbered word."

## Evidence

The session transcripts, observer logs and result bundles are under
`.build/voiceover/results/` of the verifying checkout, with named copies in
`.build/voiceover/evidence/`; they are not committed. Other work was running on the same Mac:
some sessions picked up another session's test windows, a simulator window or a system
password dialog, and three stopped when the reader lost keyboard focus. Nothing recorded after
such an interruption is used here. VoiceOver was restored to off after every session.
