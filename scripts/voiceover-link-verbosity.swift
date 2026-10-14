import AppKit
import ApplicationServices

// Reads, and with an argument chooses, how VoiceOver announces a link or an attachment in
// text: VoiceOver Utility's Verbosity, Text, "When encountering a link/attachment". The
// setting decides whether a transcript can hold a word for a link at all. It opens VoiceOver
// Utility and changes a setting of the logged-in user, so it runs on a hosted runner only;
// see "Hosted Mac sessions" in doc/testing.md.
//
// Usage: voiceover-link-verbosity [Speak|"Change Pitch"|"Play Tone"|"Do Nothing"] [--tree]

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
/// What an element says of itself, in the order VoiceOver Utility's own controls use.
func words(_ element: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute].map { string(element, $0) }
}

let arguments = CommandLine.arguments.dropFirst()
let wanted = arguments.first { !$0.hasPrefix("--") }
guard ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted" else {
    fputs("This opens VoiceOver Utility and may change a VoiceOver setting: for a hosted runner only.\n", stderr)
    exit(1)
}
guard AXIsProcessTrusted() else { fputs("Not trusted for accessibility.\n", stderr); exit(2) }
let configuration = NSWorkspace.OpenConfiguration()
guard let location = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.VoiceOverUtility") else {
    fputs("VoiceOver Utility was not found.\n", stderr)
    exit(3)
}
var opened: NSRunningApplication?
NSWorkspace.shared.openApplication(at: location, configuration: configuration) { application, _ in opened = application }
let limit = Date().addingTimeInterval(20)
while opened == nil, Date() < limit { settle(0.2) }
guard let opened else { fputs("VoiceOver Utility did not open.\n", stderr); exit(3) }
/// Closes the utility, which writes the setting, and ends.
func finish(_ status: Int32) -> Never {
    opened.terminate()
    settle(1)
    exit(status)
}
let utility = AXUIElementCreateApplication(opened.processIdentifier)
AXUIElementSetMessagingTimeout(utility, 3)

/// Every element of the utility's windows, each read afresh.
func elements() -> [AXUIElement] {
    var result: [AXUIElement] = []
    func collect(_ element: AXUIElement, depth: Int) {
        guard depth < 25, result.count < 1500 else { return }
        result.append(element)
        for child in children(element) { collect(child, depth: depth + 1) }
    }
    for window in (attribute(utility, kAXWindowsAttribute) as? [AXUIElement] ?? []) { collect(window, depth: 0) }
    return result
}
func tree() {
    func show(_ element: AXUIElement, depth: Int) {
        guard depth < 25 else { return }
        let said = words(element).filter { !$0.isEmpty }.map { "\"\($0.prefix(70))\"" }.joined(separator: " ")
        print(String(repeating: "  ", count: depth) + string(element, kAXRoleAttribute) + " " + said)
        for child in children(element) { show(child, depth: depth + 1) }
    }
    for window in (attribute(utility, kAXWindowsAttribute) as? [AXUIElement] ?? []) { show(window, depth: 0) }
}
/// The first element of one of `roles` that names `name`, waited for.
func find(_ name: String, roles: [String]) -> AXUIElement? {
    let limit = Date().addingTimeInterval(10)
    repeat {
        if let found = elements().first(where: { roles.contains(string($0, kAXRoleAttribute)) && words($0).prefix(3).contains(name) }) { return found }
        settle(0.5)
    } while Date() < limit
    return nil
}
/// Presses an element, or selects the row that holds it.
func choose(_ element: AXUIElement) {
    if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return }
    var row: AXUIElement? = element
    while let current = row, string(current, kAXRoleAttribute) != kAXRowRole {
        row = attribute(current, kAXParentAttribute).map { $0 as! AXUIElement }
    }
    if let row { AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue) }
}

settle(2)
// The utility opens on General: go to Verbosity, then to its Text tab.
if let category = find("Verbosity", roles: [kAXStaticTextRole, kAXRowRole, kAXCellRole, kAXButtonRole, kAXRadioButtonRole]) {
    choose(category)
    settle(1.5)
}
if let tab = find("Text", roles: [kAXRadioButtonRole, kAXButtonRole]) {
    choose(tab)
    settle(1.5)
}
let help = "Choose how to announce links and attachments."
guard let popUp = elements().first(where: { string($0, kAXRoleAttribute) == kAXPopUpButtonRole && string($0, kAXHelpAttribute) == help }) else {
    print("LINK VERBOSITY unknown: the setting was not found in VoiceOver Utility")
    tree()
    finish(4)
}
print("LINK VERBOSITY \(string(popUp, kAXValueAttribute))")
if arguments.contains("--tree") { tree() }
if let wanted, wanted != string(popUp, kAXValueAttribute) {
    AXUIElementPerformAction(popUp, kAXPressAction as CFString)
    settle(1)
    guard let item = elements().first(where: { string($0, kAXRoleAttribute) == kAXMenuItemRole && string($0, kAXTitleAttribute) == wanted }) else {
        print("LINK VERBOSITY has no choice \(wanted)")
        tree()
        finish(5)
    }
    AXUIElementPerformAction(item, kAXPressAction as CFString)
    settle(1.5)
    let now = string(popUp, kAXValueAttribute)
    print("LINK VERBOSITY \(now), chosen for this run")
    guard now == wanted else { finish(5) }
}
finish(0)
