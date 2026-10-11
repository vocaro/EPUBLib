# Native Mac Search-focus regression

This minimal SwiftUI app mounts EPUBLib's supplied reader and toolbar, without Pagepour.
It checks native popover dismissal through accessibility or Escape, verifies that the
opening reader responder returns, then sends Right Arrow inside the app and checks that
its public reading location changes. A second Search checks that dismissal preserves an
intentional focus move to a separate host Notes field.

Run only when the owner has approved brief keyboard focus for this qualification app:

```sh
python3 Examples/SearchFocusProbe/run.py --allow-window-focus
python3 Examples/SearchFocusProbe/run.py --allow-window-focus --escape
```

The selected Xcode toolchain builds the app. The supervisor creates and removes only its
own temporary app bundle. The app restores the prior foreground application when it still
owns focus, closes its windows and session, and returns 0 only if every assertion passes.
Each condition has a 15-second limit; the supervisor terminates its own process after 90
seconds. It sends no global pointer/key events, restores any explicitly enabled Keyboard Navigation setting, and does not
use StoreKit. This is an attended focus regression, not a VoiceOver qualification.

Before the Mac Close Search fix, the first command exits 1 with the owner window as first
responder instead of the reader. Native Escape already restores focus; retain both paths
as regression checks. The Notes field protects the intentional-destination behavior.

The result-list regression requires an attended session with temporary Keyboard Navigation:

```sh
python3 Examples/SearchFocusProbe/run.py --allow-window-focus --results-keyboard --temporarily-enable-keyboard-navigation
```

It submits a synthetic matching search, Tabs into the native result list, selects with
Down/Up, activates an accessibility row and checks that native selection follows that
update. It then runs the dismissal, page-key and intentional-destination assertions
above. The unchanged list without a selection binding ignores Down/Return/Space and
fails before these later assertions. The supervisor restores the prior system setting
even if its own qualification process times out. This does not establish VoiceOver
or physical external-keyboard coverage.
