# Language-tailored search collation

The native matcher now compares primary collation weights in the document's language,
matching Foliate's `Intl.Collator(locale, { sensitivity: 'base' })` contract. Turkish
`ö` and `o`, Swedish `å` and `a`, Spanish `ñ` and `n`, and Cyrillic `й` and `и` remain
distinct. Ordinary accents in untailored languages, case and width still compare equal.
Swedish `ü` also matches `y`, including decomposed spelling; this match was previously
lost in the prefilter. `.locate`, `.search` and `.searchHighlight` already share
`TextSearch.matches`, so no session behavior or public API needed changing.

## Public Foundation comparison

Foundation's diacritic-insensitive option removes marks before language tailoring can
assign them primary significance. Its public comparison API exposes no strength setting.
Instead, the matcher compares the original strings with swapped adjacent private-use
suffixes. The Unicode collation algorithm compares all primary weights before secondary
and tertiary weights. When the original primary sequences are equal, the two unequal
suffixes determine the ordering; swapping them reverses that ordering. Unequal primary
sequences retain their ordering in both comparisons.

Private-use characters have independent consecutive implicit primary weights and no
decompositions or locale contractions. Both suffixes are chosen absent from the original
strings; if a corpus window contains the initially selected pair, that window uses a fresh
pair. This also prevents a proper primary prefix from straddling the suffix weights.
Comparison uses the unmodified strings: explicit case or width folding would change
collation inputs and break expansion cases such as `ßs` versus `sß`, or Swedish fullwidth
`Ａ` followed by a combining ring. Case and width distinctions disappear at the primary
level itself. The production implementation uses public Foundation APIs and has no ICU
private-symbol or JavaScript dependency.

The [ICU collation concepts](https://unicode-org.github.io/icu/userguide/collation/concepts.html)
describe the primary/secondary/tertiary hierarchy. Tests validate the suffix comparison
against the historical WebKit results; those finite vectors are regression evidence,
not a claim that every Unicode sequence or locale has been enumerated.

## Prefilter and unchanged search contract

The coarse key prefilter retains root equivalences and adds the cross-class merges in
the recorded Swedish and Danish collation classes. Composed and decomposed spellings
produce the same keys. Canonical combining-class blocking matters: `u + diaeresis + macron`
belongs with Swedish `y`, while `u + macron + diaeresis` stays with `u`.

The prefilter runs for standard English, Swedish, Turkish, Spanish, Danish, German and
Japanese collations. Other languages or explicit collation variants compare every
grapheme window, preserving correctness when a key table has not been qualified for
that collation. Consequently, they can be substantially slower. A one-megabyte French
section's unique 24-grapheme query took about 10–12.5 seconds in debug builds during parallel
build activity on the development Mac; this is an observed cost, not a timing guarantee.
The existing English one-megabyte search tests retained their two-second debug bound.

Text-node traversal, script/style exclusion, whitespace collapse, format-character
removal, fixed grapheme window length, UTF-16 DOM endpoints, inline boundaries, reading
order, match limits and overlapping matches are unchanged.

## Reference provenance and validation

`SearchCollationVectorGenerator` runs the unchanged historical `search.js` and
`text-walker.js` through their real `searchMatcher`, on XHTML in WebKit. The source files
come from EPUBLib commit `4b7942d4d1682e60f505cb161c87b7757fb927ee` (`6e6930c^`).
The recorder writes the WebKit user agent and both source SHA-256 values into
`SearchCollationGoldenVectors.swift`:

- `search.js`: `31e846bdc095a645de0e94f7baa2c9e136561a363a2f774d4032e72cfa1fb0ef`
- `text-walker.js`: `4ad740ab6142b5be428700ef4d270253cef6649cf6e047ae7d2698a7aec65e92`

The 57 fixtures record 37 matching and 20 nonmatching searches. They cover Turkish dotted
and dotless I, Swedish and Spanish distinctions and merges, Cyrillic short I, untailored
accents, case/width, canonical spellings, Japanese kana, unqualified collations, explicit
German phonebook collation, primary prefixes, expansions, private-use suffix collisions,
emoji, inline boundaries, whitespace and overlapping matches. Each recorded range is
compared with both the filtered and complete native scans.

The existing golden tests now require every recorded locale equivalence to share a
prefilter key, including previously skipped cross-root-class merges. Root collation
matches also require exact equality with the WebKit classes, removing the Cyrillic
short-I exception. Mounted-session tests verify that `.locate` and `.searchHighlight`
produce the same ranges and misses in Swedish, Turkish, Spanish and Russian, including
body language overriding root language.

The final macOS focused run passed all 22 tests (11 existing golden-vector tests,
10 text-search tests and the mounted-session test). The opt-in reference recorder also
passed. In that run the English one-megabyte unique, common and accented queries took
approximately 115, 175 and 149 milliseconds in the debug build. Platform-wide build and
regression qualification is tracked with the overall change.

Reproduce with the extracted historical source files and a dedicated scratch directory:

```sh
git show '6e6930c^:Sources/EPUBViewing/Resources/epub-reader/lib/search.js' > /tmp/foliate-search.js
git show '6e6930c^:Sources/EPUBViewing/Resources/epub-reader/lib/text-walker.js' > /tmp/foliate-text-walker.js
EPUBLIB_GENERATE_SEARCH_COLLATION_VECTORS=1 \
EPUBLIB_FOLIATE_SEARCH_SOURCE=/tmp/foliate-search.js \
EPUBLIB_FOLIATE_TEXT_WALKER_SOURCE=/tmp/foliate-text-walker.js \
swift test --scratch-path .build/issue-26 --filter SearchCollationVectorGenerator
swift test --scratch-path .build/issue-26 \
  --filter 'TextSearchTests|CFIGoldenVectorTests|NativeSessionCollationTests'
```
