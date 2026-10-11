import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func shortValue(_ element: AXUIElement) -> String {
    String(((attribute(element, kAXValueAttribute) as? String) ?? "").prefix(60))
}
guard CommandLine.arguments.count >= 2,
      let pid = pid_t(CommandLine.arguments[1]), pid > 0 else {
    fputs("Usage: voiceover-ax-observer PID [seconds]\n", stderr)
    exit(1)
}
let duration = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 0 : 20
guard duration > 0, duration <= 300,
      NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "org.epubreaderlib.voiceoververify.mac" else {
    fputs("Use the isolated verification reader PID and a duration of 1–300 seconds.\n", stderr)
    exit(1)
}
print("TRUSTED \(AXIsProcessTrusted()) PID \(pid)")
guard AXIsProcessTrusted() else { exit(2) }
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 2)
var texts: [AXUIElement] = []
var visited = 0
func collect(_ element: AXUIElement, depth: Int) {
    guard depth < 20, visited < 200 else { return }
    visited += 1
    let role = attribute(element, kAXRoleAttribute) as? String ?? ""
    if role == kAXTextAreaRole {
        texts.append(element)
        print("TEXT \(texts.count - 1) VALUE \(shortValue(element))")
    }
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []) { collect(child, depth: depth + 1) }
}
for window in (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []) { collect(window, depth: 0) }
var observer: AXObserver?
let result = AXObserverCreate(pid, { _, element, notification, _ in
    print("EVENT \(notification) VALUE \(shortValue(element))")
    fflush(stdout)
}, &observer)
print("OBSERVER \(result.rawValue) TEXTCOUNT \(texts.count)")
guard let observer else { exit(3) }
for (index, element) in texts.enumerated() {
    for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification, kAXLayoutChangedNotification] {
        let status = AXObserverAddNotification(observer, element, name as CFString, nil)
        print("REGISTER \(index) \(name) STATUS \(status.rawValue)")
    }
}
for name in [kAXLayoutChangedNotification, kAXValueChangedNotification] {
    print("REGISTER APP \(name) STATUS \(AXObserverAddNotification(observer, app, name as CFString, nil).rawValue)")
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
print("READY"); fflush(stdout)
RunLoop.current.run(until: Date().addingTimeInterval(duration))
for (index, element) in texts.enumerated() { print("FINAL \(index) VALUE \(shortValue(element))") }
print("DONE")
