# Sample app

`Examples/ReaderSample` is a standalone SwiftUI application for iOS/iPadOS 27 and macOS 27.
It depends on this checkout through a local Swift package reference. It includes an original,
deterministically generated EPUB licensed under the repository's MIT license.

## Run

Install Xcode 27 with an iOS 27 simulator runtime, and install XcodeGen (`brew install xcodegen`).
From the repository root:

```sh
xcodegen generate --spec Examples/ReaderSample/project.yml
open Examples/ReaderSample/ReaderSample.xcodeproj
```

Choose **ReaderSample** for an iPhone/iPad simulator or **ReaderSampleMac** for My Mac, then Run.
For a physical device, select your signing team in the generated project's settings. The
generated project is ignored by git; persistent build settings belong in `project.yml`.

Choose **Open Sample** to read without importing a file. **Open EPUB…** uses the system file
picker and keeps security-scoped access active for the background import. The reader offers
section navigation, pagination, text size, scrolling, a native selection action and saved positions.
Controls follow the engine's capabilities. The
toolbar scrolls horizontally on narrow screens. Disclosures, notices and errors appear below
the reading surface.

Positions are JSON-encoded `EPUBLocation` values in the sample's UserDefaults, keyed by the
publication's content fingerprint. The sample deliberately leaves storage policy to the host.
Opening another book cancels the previous import and invalidates its callbacks; closing a book
closes its session. The example serializes command submissions and waits for `.ready` before
enabling controls. Applications requiring paint completion must observe relocation events.

For automated and visual checks, the launch arguments `-SampleBook <path>` open a book directly,
and `-SampleFlow scrolled`, `-SampleDark YES` and `-SampleFontSize <points>` set its style.

## Source and verification

- `Shared/BookReader.swift` owns import, cancellation, events, commands and persistence.
- `Shared/ReaderScreen.swift` owns the SwiftUI interface and one session per reader.
- `Shared/NavigationExample.swift` demonstrates safe encoded-href navigation.
- `ReaderSampleApp.swift` supplies the app entry point.

`swift build --target ReaderSampleSupport` compiles the same shared sources independently of
the app. `python3 scripts/check-docs.py` checks marked README/integration examples against them.
Run `python3 scripts/check-docs.py --write` after editing an example, and
`python3 scripts/make-sample.py` to regenerate the bundled book.

The Mac target enables the sandbox and user-selected read access only; the reader needs no
network access and refuses remote book resources and external links.
