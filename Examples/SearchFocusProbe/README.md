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
seconds. It sends no global pointer/key events, changes no global settings, and does not
use StoreKit. This is an attended focus regression, not a VoiceOver qualification.

Before the Mac Close Search fix, the first command exits 1 with the owner window as first
responder instead of the reader. Native Escape already restores focus; retain both paths
as regression checks. The Notes field protects the intentional-destination behavior.
