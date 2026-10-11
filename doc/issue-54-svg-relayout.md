# Networking SVG figures across a relayout

Issue #54 is reproduced with the unchanged
[English EPUB](https://do1.dr-chuck.net/net-intro/EN_us/net-intro.epub) of Charles R.
Severance's *Introduction to Networking* (CC BY 4.0): 2,752,493 bytes, SHA-256
`54d3886b30e92daca03f2f66065c01cb0d48c592824365605308b7b542c45c6d`. It is the book of
[#53](issue-53-svg-diagrams.md) and is still not copied into this repository.

## Reproduction

At `719225b`, one session in continuous scroll was taken through 800×700 points at
17 points in light appearance, 400×700, then 25 points in dark appearance. A second session
was then opened at 400×700, 25 points, dark. The book's linear spine has 37 `<img>`
elements: the cover, one photograph and 33 SVG resources, two of them shown twice. The
image attachments in the mounted text view were counted after each step:

| Step | Mounted of 37, in four runs |
| --- | --- |
| 800×700, 17 pt, light | 32, 35, 34, 34 |
| 400×700, 17 pt, light | unchanged |
| 400×700, 25 pt, dark, same session | 26, 22, 22, 22 |
| 400×700, 25 pt, dark, opened next | 22, 22, 22, 23 |

Every missing figure is one of the 13 SVG resources that contain `<text>`: `file5`, `file8`,
`file11`, `file13`, `file14`, `file16`, `file19`, `file20`, `file22`, `file24`, `file28`,
`file29` and `file33`, among them all seven figures the issue names. The 20 SVG resources
without text, the photograph and the cover always mounted. Which text figures were lost
changed from run to run. With 22 mounted, all 15 places a text figure is shown had fallen
back to alt text. It is not the filter omission of #53: `file13`, `file14`, `file16`, `file20`,
`file22`, `file28` and `file29` have no filter.

## Cause

Text in an SVG is drawn from a font database resvg holds: twelve fallback faces (Times New
Roman, Arial and Courier New; 8,044,428 bytes exported on macOS 27) and the faces of every
family the SVG names. The book's labels name Helvetica, Courier and Helvetica Neue in five
combinations, so it needs five databases:

| Families | Database bytes |
| --- | --- |
| Helvetica | 10,559,076 |
| Courier | 9,626,696 |
| Helvetica, Helvetica Neue | 13,287,700 |
| Courier, Helvetica Neue | 12,355,320 |
| Courier, Helvetica | 12,141,344 |

That is 57,970,136 of the 67,108,864 bytes all live databases may reserve. A reservation
lasts as long as its database, which every parsed SVG tree using it keeps alive.

`SVGRenderOptions` found a database only through its cache of four. This book has six keys
(the five above and the one for SVG without text), so a database left the cache while the
sections built with it still held its trees. The next SVG naming the same fonts could not
find it, loaded the same fonts into a second database and reserved their bytes again. In the
logged first build the Helvetica database existed three times and the reservation reached
66,946,944 bytes. The next database was refused, `SVGRenderer` returned nil and the figure
became its alt text. A refusal also empties the cache, so later figures missed it too.

A relayout made this certain rather than occasional. `NativeBook` keeps every built section
on screen until its rebuild arrives, so all five databases were still reserved while the
same figures were built again. Whatever the cache had forgotten needed 9.6 to 13.3 MB more
than the 9.1 MB left.

Two more things kept reservations past their use:

- **The resize.** After the scroll view's width changes, TextKit 2 keeps the layout
  fragments of text it has not laid out again. Replacing the text left those fragments
  behind, each still holding the attachments it had measured. After the reported resize
  and restyle 29 of the 32 replaced SVG attachments were still alive in one run, and 18
  and 19 in two others, reached through the text view's layout manager. Without the
  resize none were.
- **Closing.** A closed session kept its built sections, and its text views kept their text
  until the platform freed them. In the test process that held a closed book's 58 MB while
  the next book opened, which is why the second session above mounted no more than the first.

## Fix

- A database that is still alive is found by its key and shared, in or out of the cache.
  Each distinct font set has one database and one reservation, however many trees,
  sections or rebuilds use it. The book reserves the same 57,970,136 bytes before, during
  and after a relayout.
- A text view drops the outgoing text's layout before taking new text, so replaced text's
  images are released with it, also after a resize.
- `close()` drops the session's sections and paginations and empties its text views at
  once. So does a dismantled view, and a text view the canvas discards when the flow changes.

No limit moved. The 64 MiB database budget, the 8 MiB font limit, the removal of color
glyph tables and the four-entry cache are as they were, and a reservation still lasts as
long as its database. Sharing removes only the duplicate of a database already counted;
`testLiveFontDatabaseIsSharedAfterOptionsCacheEviction` also checks that a further distinct
database is still refused at the budget. The SVG byte, node, depth, expansion, image and
raster limits and the archive, reference and font registry limits are untouched.

## Verification

On macOS 27 (26A428) with Apple Swift 6.4, at `719225b` plus this change:

```sh
EPUBLIB_SVG_CORPUS=/tmp/issue-53-net-intro.epub \
swift test --filter 'SVGRelayoutTests|SVGRenderingTests'
```

`SVGRelayoutTests` reads the image attachments in the mounted scroll view's text storage
and requires each to decode at its laid out size. It takes one session through the reported
sequence, opens a second at the final size and style, and requires both to mount every
figure, identically. `testRelayoutMountsTheSameSVGFiguresAsAColdOpen` does so with a
generated book whose figures use five font sets, a drawing without text and a repeated
figure. `testOriginalNetworkingFiguresSurviveRelayoutWhenProvided` does so with the
publisher EPUB and mounts 37 of 37 at every step. Two further tests hold weak references to
replaced and closed text's images and require them gone. Against unchanged `719225b` sources
all four fail, as does the renderer test.

The bitmaps of four mounted attachments were exported after the relayout and inspected:
Traceroute from Michigan to Stanford, Routing Vortex, Headers and Data, and Programming with
Sockets in Python. Each draws its lines and labels.

The full Mac suite passed with the publisher EPUB provided. The full iPhone 17 Pro and
iPad Air 13-inch (M4) suites passed on dedicated iOS 27.0 simulators with
`TEST_RUNNER_EPUBLIB_SVG_CORPUS` forwarding the same file: all of `SVGRelayoutTests` ran
without a skip on both, the publisher book mounting 37 of 37 at every step. Both simulators
were deleted. No physical iPhone or iPad was used.

## Remaining limits

- The budget is shared by everything open in the process, and each database holds its own
  copy of the twelve fallback faces: the renderer copies the font bytes it is given. This
  book alone uses 86% of the budget on macOS 27. A book naming more
  families in more combinations, or a second open book with other fonts, can still be
  refused databases, and its figures then show their alt text with the existing `svg`
  disclosure. Which figures lose depends on build order.
- Database sizes come from the system's fonts and were measured on macOS 27. The book's
  five databases also fit the budget on the iOS 27.0 simulators; their sizes there were
  not recorded.
- A pagination cached for a section's earlier text is replaced when that section is next
  paginated. In continuous scroll it is not, so up to eight replaced sections stay
  alive until the reader closes. Their figures share the current databases.
