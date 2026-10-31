// Drives Xcode's DeviceHub app through accessibility, for the Duo tour workflow.
//   devicehub dump          print the window's buttons (description and frame)
//   devicehub press <desc>  press the first element whose description or help matches, e.g. "Partially Open"
import AppKit
import ApplicationServices
import Foundation

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    AXUIElementCopyAttributeValue(e, a as CFString, &v)
    return v
}

func str(_ e: AXUIElement, _ a: String) -> String {
    (attr(e, a) as? String) ?? ""
}

func children(_ e: AXUIElement) -> [AXUIElement] {
    (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func frame(_ e: AXUIElement) -> String {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return "\(Int(p.x)),\(Int(p.y)) \(Int(s.width))x\(Int(s.height))"
}

// DeviceHub's NSRunningApplication reports pid -1, so find the process by its executable path.
func deviceHubPID() -> pid_t? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", "DeviceHub.app/Contents/MacOS"]
    let out = Pipe()
    p.standardOutput = out
    try? p.run()
    p.waitUntilExit()
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return text.split(separator: "\n").compactMap { pid_t($0) }.first
}

guard AXIsProcessTrusted() else { print("not trusted for accessibility"); exit(3) }
guard let pid = deviceHubPID() else { print("no DeviceHub process"); exit(1) }
let root = AXUIElementCreateApplication(pid)
// SwiftUI and Catalyst apps build their accessibility tree only once an assistive client asks.
AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
usleep(1_500_000)
var all: [AXUIElement] = []
func walk(_ e: AXUIElement, _ depth: Int) {
    all.append(e)
    if depth < 40 { children(e).forEach { walk($0, depth + 1) } }
}
walk(root, 0)

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "dump" {
case "press":
    let query = args[2]
    guard let e = all.first(where: { [str($0, kAXDescriptionAttribute), str($0, kAXHelpAttribute)].contains(query) }) else {
        print("not found: \(query)")
        exit(2)
    }
    let result = AXUIElementPerformAction(e, kAXPressAction as CFString)
    print("pressed \(query): \(result.rawValue)")
    exit(result == .success ? 0 : 4)
default:
    for e in all where str(e, kAXRoleAttribute) == "AXButton" {
        print(str(e, kAXDescriptionAttribute), "|", str(e, kAXHelpAttribute), "|", frame(e))
    }
}
