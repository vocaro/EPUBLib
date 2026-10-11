# iPad VoiceOver verification

The iPad sessions of #28 were run on 2026-10-11 on a physical iPad Air 13-inch (M3) with
iPadOS 27.2, from macOS 27.0 `26A428` and Xcode 27.0 `27A266a`, following the
[VoiceOver testing process](voiceover-testing.md). The reader was `8896d61` with the two
fixes described here. They cover reading order, the page boundary, page turns activated by
VoiceOver, both orientations, two text sizes and changes while the reader is open. The
iPhone sessions, and VoiceOver's three-finger scroll, remain with #28.

## Defects found and fixed

**The first Next Page press did nothing.** After opening the book, one press of Next Page
left `word0001–word0293` on screen; the second showed `word0294–word0654`. It happened with
VoiceOver's activation and with a plain touch while VoiceOver was off, at `c50864f` and
`8896d61`, and in the iPad Air 13-inch (M4) simulator on iOS 27.0. The inline search field
showed its "Search queued…" line for any pending command. For the length of a page turn the
control strip grew by that line and the reader shrank by one, so the turn went to the second
page of a shorter pagination, which starts at `word0294` in the simulator. When the line
went away the reader showed the full-height page holding that word, which was the first
page again. The line now counts searches only, and the first press shows the second page.

**The right column was read first.** In landscape the first spread shows `word0001–word0147`
on the left and `word0148–word0350` on the right. Reading forward from the first control,
VoiceOver spoke the controls, then `word0148` through `word0350`, then the heading, the
paragraph and `word0001` through `word0147`. The left column of a chapter opening sits lower
by its top spacing, and VoiceOver orders sibling containers by their frames, top first. The
next spread, with no top spacing, was read in order. The canvas now lists its columns in
source order, which also keeps a right-to-left spread in reading order.

## Verified layouts

VoiceOver was moved to the heading or the first numbered line by touch, then forward until
it left the reader. In every case it spoke each visible numbered line once, in order, and the
next item was the book title below the reader. XCTest's own view of the columns agreed.
Next Page and Previous Page were activated by VoiceOver's double tap on the page buttons.

| Layout | First page or spread | After Next |
| --- | --- | --- |
| 17 pt, portrait | word0001–word0293, 35 lines | word0294–word0654, 44 lines |
| 23 pt, portrait | word0001–word0146, 24 lines | word0147–word0339, 32 lines |
| 17 pt, landscape | word0001–word0147, word0148–word0350 | word0351–word0553, word0554–word0756 |
| 23 pt, landscape | word0001–word0055, word0056–word0165 | word0166–word0275, word0276–word0385 |

Every page after a turn began with the successor of the previous page's last word, and
Previous Page returned to the first, where VoiceOver says "Previous Page dimmed". Before the
numbered words VoiceOver read "Page boundary verification", the two lines of the paragraph,
"Verification link Link", ". Image:", "Blue verification square Image" and ".".

VoiceOver's own page actions work too. With its cursor on a numbered line, a one-finger
flick down offers "Next Page", then "Previous Page", from the rotor; a double tap on the line
performs the one chosen. In portrait and in landscape Next Page showed the following page or
spread, read in order from its first word, and Previous Page returned.

Activating the link through VoiceOver showed the last page, `word1013–word1200`, where it
read "Link target reached" and "This is the end of the numbered paragraph."; Previous Page
then showed `word0655–word1012`.

Changes while the reader was open: rotating to landscape and back kept the position, each
orientation reading its own columns as above. Larger Text, chosen in the Appearance menu
through VoiceOver, showed `word0001–word0227` in 30 lines at 19 points in portrait, and
`word0001–word0108` beside `word0109–word0264` in landscape, each read in order; Smaller Text
restored the 17-point pages.

## Not covered

- VoiceOver's three-finger scroll. XCTest cannot perform it, and its synthesized
  Control-Option-Space and Option-arrow keys did not reach VoiceOver. The scroll keeps its API
  regression coverage.
- A word hyphenated across lines is spoken as two fragments, "must re" and "sume at the next
  numbered word." at 19 points, since each line is its own item.
- The iPhone was not connected.

## Evidence

The session logs and result bundles are under `.build/voiceover/results/` of the verifying
checkout, with named summaries in `.build/voiceover/evidence/`; they are not committed.
Another session was using the same iPad at first: its app came to the foreground during one
run and VoiceOver was switched off during another. Both runs were discarded, and the probe
now stops when the reader leaves the foreground. Every layout above was then run again with
the iPad otherwise idle, with the same results. VoiceOver was left off and the iPad in
portrait.
