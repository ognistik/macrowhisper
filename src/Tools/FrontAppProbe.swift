#!/usr/bin/env swift

import Cocoa
import ApplicationServices
import CoreGraphics
import Foundation

private struct ProbeAppSummary {
    let pid: pid_t
    let name: String
    let bundleId: String
    let activationPolicy: String
}

private struct AXFocusSnapshot {
    let source: String
    let pid: pid_t?
    let role: String?
    let subrole: String?
    let windowTitle: String?
}

private struct WindowServerWindow {
    let pid: pid_t
    let ownerName: String
    let windowName: String
    let layer: Int
    let alpha: Double
    let width: Double
    let height: Double
    let boundsSummary: String
}

private let systemWindowOwnerBlacklist: Set<String> = [
    "Window Server",
    "Dock",
    "Control Center",
    "NotificationCenter",
    "SystemUIServer",
    "Spotlight",
    "loginwindow"
]

private func activationPolicyLabel(_ policy: NSApplication.ActivationPolicy) -> String {
    switch policy {
    case .regular:
        return "regular"
    case .accessory:
        return "accessory"
    case .prohibited:
        return "prohibited"
    @unknown default:
        return "unknown"
    }
}

private func summarizeApp(pid: pid_t?) -> ProbeAppSummary? {
    guard let pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
        return nil
    }

    return ProbeAppSummary(
        pid: pid,
        name: app.localizedName ?? "Unknown",
        bundleId: app.bundleIdentifier ?? "unknown.bundle",
        activationPolicy: activationPolicyLabel(app.activationPolicy)
    )
}

private func formatAppSummary(_ summary: ProbeAppSummary?) -> String {
    guard let summary else {
        return "none"
    }

    return "\(summary.name) | pid=\(summary.pid) | bundle=\(summary.bundleId) | policy=\(summary.activationPolicy)"
}

private func copyAXValue(_ element: AXUIElement, attribute: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard error == .success else {
        return nil
    }
    return value
}

private func copyAXString(_ element: AXUIElement, attribute: CFString) -> String? {
    copyAXValue(element, attribute: attribute) as? String
}

private func copyAXElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
    guard let value = copyAXValue(element, attribute: attribute),
          CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return unsafeBitCast(value, to: AXUIElement.self)
}

private func pidForAXElement(_ element: AXUIElement) -> pid_t? {
    var pid: pid_t = 0
    let error = AXUIElementGetPid(element, &pid)
    guard error == .success, pid > 0 else {
        return nil
    }
    return pid
}

private func focusedWindowTitle(forAppPid pid: pid_t) -> String? {
    let appElement = AXUIElementCreateApplication(pid)
    if let focusedWindow = copyAXElement(appElement, attribute: kAXFocusedWindowAttribute as CFString),
       let title = copyAXString(focusedWindow, attribute: kAXTitleAttribute as CFString),
       !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return title
    }
    return nil
}

private func focusedWindowTitle(forElement element: AXUIElement) -> String? {
    if let windowElement = copyAXElement(element, attribute: kAXWindowAttribute as CFString),
       let title = copyAXString(windowElement, attribute: kAXTitleAttribute as CFString),
       !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return title
    }
    if let pid = pidForAXElement(element) {
        return focusedWindowTitle(forAppPid: pid)
    }
    return nil
}

private func captureAXFocusedApplicationSnapshot() -> AXFocusSnapshot {
    let systemWide = AXUIElementCreateSystemWide()
    guard let focusedAppElement = copyAXElement(systemWide, attribute: kAXFocusedApplicationAttribute as CFString) else {
        return AXFocusSnapshot(source: "AX focused application", pid: nil, role: nil, subrole: nil, windowTitle: nil)
    }

    let pid = pidForAXElement(focusedAppElement)
    return AXFocusSnapshot(
        source: "AX focused application",
        pid: pid,
        role: nil,
        subrole: nil,
        windowTitle: pid.flatMap(focusedWindowTitle(forAppPid:))
    )
}

private func captureAXFocusedElementSnapshot() -> AXFocusSnapshot {
    let systemWide = AXUIElementCreateSystemWide()
    guard let focusedElement = copyAXElement(systemWide, attribute: kAXFocusedUIElementAttribute as CFString) else {
        return AXFocusSnapshot(source: "AX focused UI element", pid: nil, role: nil, subrole: nil, windowTitle: nil)
    }

    return AXFocusSnapshot(
        source: "AX focused UI element",
        pid: pidForAXElement(focusedElement),
        role: copyAXString(focusedElement, attribute: kAXRoleAttribute as CFString),
        subrole: copyAXString(focusedElement, attribute: kAXSubroleAttribute as CFString),
        windowTitle: focusedWindowTitle(forElement: focusedElement)
    )
}

private func captureWorkspaceFrontmostApp() -> ProbeAppSummary? {
    summarizeApp(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
}

private func extractWindowServerWindows(limit: Int) -> [WindowServerWindow] {
    guard let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return []
    }

    var results: [WindowServerWindow] = []

    for entry in rawList {
        guard let ownerName = entry[kCGWindowOwnerName as String] as? String,
              !systemWindowOwnerBlacklist.contains(ownerName),
              let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32,
              ownerPID != getpid() else {
            continue
        }

        let layer = entry[kCGWindowLayer as String] as? Int ?? 0
        let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1.0
        let windowName = (entry[kCGWindowName as String] as? String) ?? ""
        let bounds = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let width = bounds["Width"] as? Double ?? 0
        let height = bounds["Height"] as? Double ?? 0
        let x = bounds["X"] as? Double ?? 0
        let y = bounds["Y"] as? Double ?? 0

        guard alpha > 0.01, width >= 80, height >= 50 else {
            continue
        }

        results.append(
            WindowServerWindow(
                pid: ownerPID,
                ownerName: ownerName,
                windowName: windowName,
                layer: layer,
                alpha: alpha,
                width: width,
                height: height,
                boundsSummary: "x=\(Int(x)) y=\(Int(y)) w=\(Int(width)) h=\(Int(height))"
            )
        )

        if results.count >= limit {
            break
        }
    }

    return results
}

private func recommendedPid(
    workspace: ProbeAppSummary?,
    axFocusedApp: AXFocusSnapshot,
    axFocusedElement: AXFocusSnapshot,
    topWindow: WindowServerWindow?
) -> (pid: pid_t?, reason: String) {
    if let pid = axFocusedElement.pid {
        return (pid, "AX focused UI element owner")
    }
    if let pid = axFocusedApp.pid {
        return (pid, "AX focused application")
    }
    if let topWindow, topWindow.layer <= 3 {
        return (topWindow.pid, "top visible WindowServer window")
    }
    return (workspace?.pid, "NSWorkspace.frontmostApplication fallback")
}

private func printAXSnapshot(_ snapshot: AXFocusSnapshot) {
    let appSummary = formatAppSummary(summarizeApp(pid: snapshot.pid))
    print("\(snapshot.source): \(appSummary)")
    if let role = snapshot.role {
        print("  role=\(role)")
    }
    if let subrole = snapshot.subrole {
        print("  subrole=\(subrole)")
    }
    if let windowTitle = snapshot.windowTitle {
        print("  windowTitle=\(windowTitle)")
    }
}

private func printWindowServerWindows(_ windows: [WindowServerWindow]) {
    if windows.isEmpty {
        print("WindowServer top windows: none")
        return
    }

    print("WindowServer top windows:")
    for (index, window) in windows.enumerated() {
        let title = window.windowName.isEmpty ? "(untitled)" : window.windowName
        print(
            "  [\(index)] \(window.ownerName) | pid=\(window.pid) | layer=\(window.layer) | " +
            "alpha=\(String(format: "%.2f", window.alpha)) | title=\(title) | \(window.boundsSummary)"
        )
    }
}

private func runProbe(sampleNumber: Int? = nil) {
    if let sampleNumber {
        let formatter = ISO8601DateFormatter()
        print("\n=== Sample \(sampleNumber) @ \(formatter.string(from: Date())) ===")
    }

    print("AX trusted: \(AXIsProcessTrusted())")

    let workspace = captureWorkspaceFrontmostApp()
    print("NSWorkspace.frontmostApplication: \(formatAppSummary(workspace))")

    let axFocusedApp = captureAXFocusedApplicationSnapshot()
    printAXSnapshot(axFocusedApp)

    let axFocusedElement = captureAXFocusedElementSnapshot()
    printAXSnapshot(axFocusedElement)

    let topWindows = extractWindowServerWindows(limit: 8)
    printWindowServerWindows(topWindows)

    let recommendation = recommendedPid(
        workspace: workspace,
        axFocusedApp: axFocusedApp,
        axFocusedElement: axFocusedElement,
        topWindow: topWindows.first
    )
    let recommendedApp = formatAppSummary(summarizeApp(pid: recommendation.pid))
    print("Recommended target app: \(recommendedApp)")
    print("Reason: \(recommendation.reason)")
}

private func intArgument(named name: String, default defaultValue: Int) -> Int {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          index + 1 < CommandLine.arguments.count,
          let value = Int(CommandLine.arguments[index + 1]) else {
        return defaultValue
    }
    return value
}

private func doubleArgument(named name: String, default defaultValue: Double) -> Double {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          index + 1 < CommandLine.arguments.count,
          let value = Double(CommandLine.arguments[index + 1]) else {
        return defaultValue
    }
    return value
}

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print(
        """
        Usage:
          swift Tools/FrontAppProbe.swift
          swift Tools/FrontAppProbe.swift --watch --samples 30 --interval 0.5

        What it prints:
          - NSWorkspace frontmost application
          - AX system-wide focused application
          - AX focused UI element owner/role/window
          - top visible WindowServer windows

        This is useful for floating windows that do not become the official frontmost app.
        """
    )
    exit(0)
}

let watchMode = CommandLine.arguments.contains("--watch")
let sampleCount = max(1, intArgument(named: "--samples", default: 20))
let interval = max(0.1, doubleArgument(named: "--interval", default: 0.5))

if watchMode {
    for sample in 1...sampleCount {
        runProbe(sampleNumber: sample)
        if sample < sampleCount {
            Thread.sleep(forTimeInterval: interval)
        }
    }
} else {
    runProbe()
}
