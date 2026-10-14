# ZIP input work (#199)

The constructed release-build inputs confirm that small output does not bound work. Each extra
directory record has its own `extra/N.bin` path and a zero CRC and uncompressed size. The base is
the repository's original seven-file, two-chapter fixture; no external books are used.

`Fixture.sharedInputArchive` writes one local header, or distinct headers whose extra fields
overlap and end at the same data start. Its Deflate stream is a run of empty stored blocks with
only the last block final (4,194,300 bytes for the 4 MiB request). The early-end control begins
with the final empty fixed-code block `03 00`, followed by 4 MiB of unused zeros. Directory records
declare the whole stream, including those unused bytes. The long-header case has a 65,535-byte
name and a 65,535-byte extra field, held once in the archive and repeatedly named by records.

## Release measurement

Measured on this Mac on 2026-10-13, from main commit
`24400a9e0203f9e325ca98f5917e1d2e17955189`, using ZIPFoundation 0.9.20 and `swift build -c release -j 2`.
A caller-file fix was being compiled in a separate two-job lane. Host load averages at the start
were 4.84 / 9.50 / 9.48. CPU time and callback counts establish work; these wall times are not a
quiet-machine throughput claim. Each input runs in its own child with a 120-second timeout; fixture
construction and a warm-up opening precede the clock. Callbacks include the base fixture's seven.

| Input | Extra records | Archive bytes | Consumer calls | CPU seconds | Wall seconds |
| --- | ---: | ---: | ---: | ---: | ---: |
| Long local header | 1 | 139,701 | 8 | 0.000327 | 0.000328 |
| Long local header | 19,993 | 1,348,107 | 20,000 | 1.511608 | 1.516812 |
| Empty stored Deflate blocks | 1 | 4,202,929 | 135 | 0.005712 | 0.005716 |
| Empty stored Deflate blocks | 2,000 | 4,321,762 | 256,007 | 6.740319 | 6.846126 |
| Early-ended stream | 1 | 4,202,935 | 8 | 0.001483 | 0.001486 |
| Early-ended stream | 2,000 | 4,321,768 | 2,007 | 0.018792 | 0.018848 |
| Distinct overlapping headers | 1 | 4,202,929 | 135 | 0.005579 | 0.005607 |
| Distinct overlapping headers | 500 | 4,247,232 | 64,007 | 1.952573 | 2.316241 |

The 2,000-entry empty-block input grows the archive by under 3% while multiplying Deflate
processing steps by 2,000. The early-ended stream is much cheaper despite the same declared
compressed-range overlap. Refusing declared overlap would contradict the read-past decision
for misstated Deflate sizes (#219 and #171).

With the bound applied to the same source revision, in a lane beside page-geometry verification
(host load 4.66 / 7.98 / 9.37), the cases produced:

| Input | Extra records | Consumer calls | CPU seconds | Wall seconds | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| Long local header | 1 | 8 | 0.000407 | 0.000411 | Opens |
| Long local header | 19,993 | 0 | 0.000177 | 0.000180 | Work limit |
| Empty stored Deflate blocks | 1 | 135 | 0.006148 | 0.006151 | Opens |
| Empty stored Deflate blocks | 2,000 | 141 | 0.003375 | 0.003378 | Work limit |
| Early-ended stream | 1 | 8 | 0.001404 | 0.001407 | Opens |
| Early-ended stream | 2,000 | 2,007 | 0.018173 | 0.018220 | Opens |
| Distinct overlapping headers | 1 | 135 | 0.005573 | 0.005577 | Opens |
| Distinct overlapping headers | 500 | 138 | 0.003981 | 0.003983 | Work limit |

The work-limit failures are typed `limitExceeded("archive input work")`. No timeout was reached.

## Bound

The directory pre-scan charges the exact size of each local header (30 fixed bytes plus its
name and extra field) against the archive's byte count. Real, separate headers fit that budget;
repeated large headers cannot multiply copying and ZIP64 field scans indefinitely.

ZIPFoundation 0.9.20's Apple decoder calls the consumer after every
`compression_stream_process`, including steps that produce no output. Each call uses at most
32 KiB of input and returns at most 32 KiB of output. Extraction therefore charges 32 KiB per
consumer call, credits actual expanded bytes, and grants one 32 KiB allowance per entry for a
partial final chunk. After admitting E entries and producing O bytes from an archive of A bytes,
successful calls are bounded by `floor((A + O) / 32768) + E`. The existing entry-count and output
limits still apply. The same consumer is used for stored data, whose full chunks cost no extra
input work and whose final partial chunk uses the entry allowance.

The SDK's `compression.h` contract says a successful processing call continues until its source
is exhausted, destination is full, or stream ends. Full output chunks pay for their call entirely;
input-exhausting partial output calls are covered by archive bytes, with the entry allowance
covering the final partial input/output chunk. Regression controls include 20,000 small stored
entries and ordinary Deflate with 1,000 small entries beside a 256 KiB incompressible payload.

This is a bound on processing steps, not a claim to observe the decoder's exact input offset.
It stops repeated empty streams and streams shared through distinct headers while continuing to
read early-ended streams and declared sizes beyond the archive. A reused header or overlapping
range is not itself refused. Exceeding either work budget throws
`EPUBPublicationError.limitExceeded("archive input work")`.

## Repeat

From the repository root:

```sh
python3 scripts/measure-archive-input-cost.py --repeats 1
```

`--zipfoundation /path/to/ZIPFoundation` reuses a public 0.9.20 source checkout without modifying
it; otherwise SwiftPM resolves the exact 0.9.20 dependency. The script creates a separate package
under `.build/measure-archive-input-cost`, linking this checkout's source and original fixture
code, and builds only the release probe's dependencies. It also defines the real reading test
target, so focused regression and size-policy checks can reuse that build:

```sh
swift test --package-path .build/measure-archive-input-cost -c release -j 2 \
  --filter 'ArchiveInputWorkTests|ContainerArchiveCoverageTests|PublicationSafetyTests|ArchiveEndRecordTests|ZIP64ZeroValueTests|ArchiveInputReleaseTests'
```

The fixed source on the main revision above passed this focused run on 2026-10-13: 100 tests,
zero failures, including all seven `ArchiveInputWorkTests`. All reading tests then passed with
`swift test --package-path .build/measure-archive-input-cost -c release -j 2 --skip-build`:
563 tests, five skips, zero failures, 5.779 seconds. Three public corpus checks and two historical
book fixture checks were skipped because their opt-in variables were unset. This verification covers the reading target on
macOS; no simulator, UI, device, hosted runner, or other project's books were used.
