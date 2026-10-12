# Notes for coding agents

Working rules for agents in this repository. Build and test commands are in
[doc/testing.md](doc/testing.md).

## Simulators

Drive iOS simulators headlessly, with `xcrun simctl` and `xcodebuild`.

- Create your own device and delete it when you finish, as `scripts/test-ios.sh` does:
  `simctl create`, `boot` and `bootstatus -b`, with `shutdown` and `delete` in an exit trap.
  Other sessions use this machine at the same time, so never select, shut down or erase a
  device you did not create.
- Give every command your device's identifier. `booted` is whichever simulator booted first,
  which may be another session's.
- Install, launch and capture with `simctl install`, `simctl launch` and
  `simctl io <device> screenshot`. Tests run with
  `xcodebuild -destination "platform=iOS Simulator,id=<device>"`.
- Do not open a live simulator view or any tool that takes control of a simulator's screen
  (in the Claude desktop app, the iOS Simulator tool) unless the owner has asked to watch.
  Such a tool asks him to approve each device, and a test device is new on every run, so he
  is asked every time.
