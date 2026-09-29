// axhelper — Antigravity 自动重试的界面扫描器
// 用法: axhelper <pid> [--click]
//   对指定 pid 的应用: 设置 AXManualAccessibility 唤醒辅助功能树，
//   遍历窗口收集错误卡片文案与 Retry/Try again 按钮；--click 时执行点击。
//   结果以单行 JSON 输出到 stdout。
// 由 antigravity-auto-retry.js 守望器调用（辅助功能权限继承自调用方 osascript）。

import ApplicationServices
import Foundation

let errRe = try! NSRegularExpression(
    pattern: "error persists|terminated due to error|likely temporary",
    options: [.caseInsensitive])
let buttonLabels: Set<String> = ["retry", "try again"]
let maxNodes = 20000
let maxDepth = 60

var nodes = 0
var errText = false
var target: AXUIElement?
var targetLabel = ""
var seenButtons: [String] = []

func matchesErr(_ s: String) -> Bool {
    let r = NSRange(s.startIndex..<s.endIndex, in: s)
    return errRe.firstMatch(in: s, options: [], range: r) != nil
}

func attr(_ el: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
    var value: CFTypeRef?
    let e = AXUIElementCopyAttributeValue(el, name as CFString, &value)
    return (e, value)
}

func attrString(_ el: AXUIElement, _ name: String) -> String {
    let (e, v) = attr(el, name)
    guard e == .success else { return "" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}

func childArray(_ v: CFTypeRef?) -> [AXUIElement] {
    guard let v = v else { return [] }
    if let arr = v as? [AXUIElement] { return arr }
    if let ns = v as? NSArray {
        var out: [AXUIElement] = []
        for case let item as AnyObject in ns {
            if CFGetTypeID(item) == AXUIElementGetTypeID() {
                out.append(item as! AXUIElement)
            }
        }
        return out
    }
    return []
}

func walk(_ el: AXUIElement, _ depth: Int) {
    if nodes >= maxNodes || depth > maxDepth { return }
    nodes += 1
    let role = attrString(el, kAXRoleAttribute)
    if role == "AXButton" {
        var label = attrString(el, kAXTitleAttribute)
        if label.isEmpty { label = attrString(el, kAXDescriptionAttribute) }
        if label.isEmpty { label = attrString(el, kAXValueAttribute) }
        let key = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !key.isEmpty && seenButtons.count < 30 && !seenButtons.contains(key) {
            seenButtons.append(key)
        }
        if target == nil && buttonLabels.contains(key) {
            target = el
            targetLabel = key
        }
        return
    }
    if !errText,
       role == "AXStaticText" || role == "AXHeading" || role == "AXTextArea" || role.isEmpty {
        let v = attrString(el, kAXValueAttribute)
        if !v.isEmpty && matchesErr(v) { errText = true }
    }
    let (e, c) = attr(el, kAXChildrenAttribute)
    guard e == .success else { return }
    for kid in childArray(c) {
        if nodes >= maxNodes { return }
        walk(kid, depth + 1)
    }
}

let args = CommandLine.arguments
guard args.count >= 2, let pid = Int32(args[1]) else {
    fputs("usage: axhelper <pid> [--click]\n", stderr)
    exit(2)
}
let doClick = args.contains("--click")

let t0 = Date()
let app = AXUIElementCreateApplication(pid)
var out: [String: Any] = [:]

// 唤醒 Chromium 辅助功能树
let wakeErr = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
out["wake"] = Int(wakeErr.rawValue)
if wakeErr == .apiDisabled || wakeErr == .cannotComplete {
    out["denied"] = true
} else {
    var windowsRef: CFTypeRef?
    let werr = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
    out["windowsErr"] = Int(werr.rawValue)
    if werr == .success {
        let wins = childArray(windowsRef)
        out["windows"] = wins.count
        for w in wins {
            if nodes >= maxNodes { break }
            walk(w, 0)
        }
    }
}

out["nodes"] = nodes
out["errText"] = errText
out["ms"] = Int(Date().timeIntervalSince(t0) * 1000)
if target != nil { out["target"] = targetLabel }
out["buttons"] = seenButtons
if doClick, let t = target, errText {
    let e = AXUIElementPerformAction(t, kAXPressAction as CFString)
    out["clicked"] = e == .success
    out["pressErr"] = Int(e.rawValue)
}

if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
   let s = String(data: data, encoding: .utf8) {
    print(s)
} else {
    print("{\"error\":\"json\"}")
}
