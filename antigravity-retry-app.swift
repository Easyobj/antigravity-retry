// AntigravityRetry — Antigravity 自动重试 一体化应用
//
// 一个进程包含三部分：
//   1. 守望引擎：每 3 秒调用 axhelper 扫描 Antigravity/Antigravity IDE 界面树，
//      检测到错误卡片（"Agent terminated due to error" 等）自动点击 Retry/Try again；
//      10 分钟内最多 6 次，超过冷却 15 分钟。
//   2. 菜单栏界面：点击菜单栏图标显示实时状态与控制按钮。
//   3. 本地控制台：http://127.0.0.1:17377（网页版状态/日志/控制）。
//
// 通信全部通过文件（state.json / pause / diag.now / log），单实例由 pid 文件 + 端口保证。
// 由 LaunchAgent com.local.antigravity-retry 开机自启。
// 不需要辅助功能权限（AX 调用全部在 axhelper 里，权限继承自本应用；本应用已在辅助功能列表）。

import SwiftUI
import Darwin
import ApplicationServices
import ServiceManagement

// ---------- 常量 ----------

let stateDir = NSString(string: "~/Library/Application Support/AntigravityAutoRetry").expandingTildeInPath
let statePath = stateDir + "/state.json"
let pausePath = stateDir + "/antigravity-auto-retry.pause"
let diagPath = stateDir + "/diag.now"
let pidPath = stateDir + "/antigravity-auto-retry.pid"
let logPath = stateDir + "/antigravity-auto-retry.log"
let agentLabel = "com.local.antigravity-retry"
let consoleURL = URL(string: "http://127.0.0.1:17377")!

let targets: [(name: String, bundleId: String)] = [
    ("Antigravity", "com.google.antigravity"),
    ("Antigravity IDE", "com.google.antigravity-ide"),
]
let buttonLabels: Set<String> = ["retry", "try again"]
let pollSec: TimeInterval = 3
let afterClickSec: TimeInterval = 8
let capWindowMs: Double = 10 * 60 * 1000
let capMaxClicks = 6
let capCooldownSec: TimeInterval = 15 * 60
let restartAfterMs: Double = 2 * 60 * 60 * 1000 // 每 2 小时自杀一次，由 launchd 拉起

let fm = FileManager.default

let helperPath: String = {
    if let res = Bundle.main.resourceURL {
        let p = res.appendingPathComponent("axhelper").path
        if fm.fileExists(atPath: p) { return p }
    }
    if let exe = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("axhelper").path,
       fm.fileExists(atPath: exe) { return exe }
    return NSString(string: "~/.local/bin/axhelper").expandingTildeInPath
}()

func readJSON(_ path: String) -> [String: Any]? {
    guard let data = fm.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

// ---------- 日志 ----------

func appendLog(_ msg: String) {
    let line = Data(Date().ISO8601Format().appending(" ").appending(msg).appending("\n").utf8)
    if !fm.fileExists(atPath: logPath) {
        fm.createFile(atPath: logPath, contents: nil)
    }
    if let attrs = try? fm.attributesOfItem(atPath: logPath),
       let size = attrs[.size] as? Int, size > 2 * 1024 * 1024 {
        try? fm.removeItem(atPath: logPath)
        fm.createFile(atPath: logPath, contents: nil)
    }
    if let fh = FileHandle(forWritingAtPath: logPath) {
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        fh.write(line)
    }
}

func notify(_ msg: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(msg.replacingOccurrences(of: "\"", with: "'"))\" with title \"Antigravity 自动重试\""]
    try? p.run()
}

// ---------- 守望引擎 ----------

final class Engine {
    static let shared = Engine()
    private var clicks: [[String: Any]] = []
    private var cooldownUntil: Double = 0
    private var lastStateJson = ""
    private var lastAuthLog: Double = 0
    private var lastBeat: Double = 0
    private var treeNotified = false
    private let startedAt = Date().timeIntervalSince1970 * 1000
    private var lastResults: [String: Any] = [:]

    func start() {
        try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        Thread { [weak self] in self?.loop() }.start()
    }

    private func loop() {
        writePid()
        appendLog("守望器启动 (pid \(ProcessInfo.processInfo.processIdentifier), 一体化版)")
        while true {
            if Date().timeIntervalSince1970 * 1000 - startedAt > restartAfterMs {
                appendLog("定时自检重启")
                exit(0)
            }
            if fm.fileExists(atPath: diagPath) { processDiag() }

            guard !fm.fileExists(atPath: pausePath) else {
                writeState(nil)
                Thread.sleep(forTimeInterval: 5)
                continue
            }

            let results = scanAll(click: true)

            var denied = false, clicked = false, clickedApp = "", clickedLabel = "", treeSeen = false
            for t in targets {
                guard let r = results[t.name] as? [String: Any] else { continue }
                if r["access"] as? String == "denied" { denied = true }
                if r["clicked"] as? Bool == true {
                    clicked = true
                    clickedApp = t.name
                    clickedLabel = r["target"] as? String ?? ""
                }
                if r["access"] as? String == "ok", (r["nodes"] as? Int ?? 0) > 0 { treeSeen = true }
            }
            writeState(results)

            if denied {
                if Date().timeIntervalSince1970 * 1000 - lastAuthLog > 10 * 60 * 1000 {
                    let detail = (results[targets[0].name] as? [String: Any])?["detail"] as? String ?? "?"
                    appendLog("辅助功能未授权，等待授权中… (code: \(detail))")
                    lastAuthLog = Date().timeIntervalSince1970 * 1000
                }
                slicedSleep(30)
                continue
            }

            if treeSeen && !treeNotified {
                treeNotified = true
                appendLog("已成功读取应用界面，自动重试开始生效")
                notify("辅助功能授权成功，Antigravity 自动重试已生效")
            }

            let now = Date().timeIntervalSince1970 * 1000
            if now - lastBeat > 5 * 60 * 1000 {
                appendLog("心跳。\n" + report(results))
                lastBeat = now
            }

            if clicked {
                clicks.append(["at": now, "app": clickedApp, "label": clickedLabel])
                while let first = clicks.first, let at = first["at"] as? Double, now - at > capWindowMs {
                    clicks.removeFirst()
                }
                appendLog("已点击 \"\(clickedLabel)\" (\(clickedApp))，\(Int(capWindowMs / 60000)) 分钟内第 \(clicks.count) 次")
                if clicks.count >= capMaxClicks {
                    appendLog("10 分钟内自动重试已达 \(capMaxClicks) 次，暂停 \(Int(capCooldownSec / 60)) 分钟（可能不是临时性错误）")
                    notify("10 分钟内自动重试已达 \(capMaxClicks) 次，暂停 15 分钟。建议检查错误原因或开新会话。")
                    clicks.removeAll()
                    cooldownUntil = now + capCooldownSec * 1000
                    writeState(nil)
                    slicedSleep(capCooldownSec)
                    cooldownUntil = 0
                    writeState(nil)
                } else {
                    Thread.sleep(forTimeInterval: afterClickSec)
                }
                continue
            }

            Thread.sleep(forTimeInterval: pollSec)
        }
    }

    private func slicedSleep(_ sec: TimeInterval) {
        var remain = sec
        while remain > 0 {
            if fm.fileExists(atPath: diagPath) { processDiag() }
            Thread.sleep(forTimeInterval: min(5, remain))
            remain -= 5
        }
    }

    private func processDiag() {
        try? fm.removeItem(atPath: diagPath)
        var lines: [String] = []
        for t in targets {
            lines.append("==== \(t.name) (\(t.bundleId)) ====")
            guard let pid = pidsForBundle(t.bundleId).first else { lines.append("未运行"); continue }
            lines.append("pid: \(pid)")
            if let j = runHelper(pid, click: false) {
                if let data = try? JSONSerialization.data(withJSONObject: j, options: [.sortedKeys]),
                   let s = String(data: data, encoding: .utf8) {
                    lines.append("helper: \(s)")
                }
            } else {
                lines.append("helper 失败")
            }
        }
        appendLog("诊断结果：\n" + lines.joined(separator: "\n"))
        notify("诊断完成，详情见日志")
    }

    // ---------- 扫描 ----------

    func pidsForBundle(_ bid: String) -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bid).map { $0.processIdentifier }
    }

    func runHelper(_ pid: pid_t, click: Bool) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helperPath)
        p.arguments = [String(pid)] + (click ? ["--click"] : [])
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func scanAll(click: Bool) -> [String: Any] {
        var results: [String: Any] = [:]
        for t in targets {
            results[t.name] = scanTarget(t, click: click)
        }
        return results
    }

    private func scanTarget(_ t: (name: String, bundleId: String), click: Bool) -> [String: Any] {
        let pids = pidsForBundle(t.bundleId)
        guard let pid = pids.first else {
            return ["access": "absent"]
        }
        // 快速路径：axhelper
        if let j = runHelper(pid, click: click) {
            if j["denied"] as? Bool == true {
                return ["access": "denied", "pid": Int(pid), "detail": "helper wake \(j["wake"] ?? "?")"]
            }
            var r = j
            r["access"] = "ok"
            r["pid"] = Int(pid)
            return r
        }
        return ["access": "error", "pid": Int(pid), "detail": "helper 无法运行"]
    }

    func report(_ results: [String: Any]) -> String {
        var lines: [String] = []
        for t in targets {
            guard let r = results[t.name] as? [String: Any] else { continue }
            let access = r["access"] as? String ?? ""
            switch access {
            case "absent":
                lines.append("\(t.name): 未运行")
            case "denied":
                lines.append("\(t.name): 辅助功能未授权 (\(r["detail"] ?? ""))")
            case "error":
                lines.append("\(t.name): 扫描出错 pid=\(r["pid"] ?? "-") \(r["detail"] ?? "")")
            default:
                let err = (r["errText"] as? Bool ?? false) ? "有" : "无"
                var line = "\(t.name): pid=\(r["pid"] ?? 0) 窗口=\(r["windows"] ?? 0) 节点=\(r["nodes"] ?? 0) 耗时=\(r["ms"] ?? 0)ms 错误卡片=\(err)"
                if let target = r["target"] as? String { line += " 目标按钮=\"\(target)\"" }
                if r["clicked"] as? Bool == true { line += " [已点击]" }
                lines.append(line)
                if (r["windows"] as? Int ?? 0) > 0 && (r["nodes"] as? Int ?? 0) == 0 {
                    lines.append("  ↑ 窗口存在但读不到子元素：界面树可能尚未构建完成")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // ---------- 状态文件 ----------

    private func writeState(_ results: [String: Any]?) {
        if let r = results { lastResults = r }
        var apps: [String: Any] = [:]
        for t in targets {
            apps[t.name] = lastResults[t.name] ?? NSNull()
        }
        let st: [String: Any] = [
            "ts": Date().timeIntervalSince1970 * 1000,
            "startedAt": startedAt,
            "cooldownUntil": cooldownUntil,
            "clicks": clicks.suffix(20).map { $0 },
            "apps": apps,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: st, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8), s != lastStateJson else { return }
        lastStateJson = s
        fm.createFile(atPath: statePath, contents: data)
    }

    private func writePid() {
        fm.createFile(atPath: pidPath, contents: "\(ProcessInfo.processInfo.processIdentifier)\n".data(using: .utf8))
    }
}

// ---------- HTTP 控制台 (127.0.0.1:17377) ----------

// ---------- HTTP 控制台服务器 (POSIX socket, 127.0.0.1:17377) ----------

func startPosixHttp(port: UInt16, handler: @escaping (String, String, Data) -> (Int, String, Data)) {
    signal(SIGPIPE, SIG_IGN)
    Thread {
        let serverFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else { appendLog("控制台 socket 创建失败 errno=\(errno)"); return }
        var yes: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else { appendLog("控制台端口 \(port) 绑定失败 errno=\(errno)"); close(serverFD); return }
        guard listen(serverFD, 16) == 0 else { appendLog("控制台 listen 失败 errno=\(errno)"); close(serverFD); return }
        appendLog("控制台已启动 http://127.0.0.1:\(port)")
        while true {
            var clientAddr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(serverFD, &clientAddr, &len)
            guard client >= 0 else { continue }
            Thread { handleClient(client, handler: handler) }.start()
        }
    }.start()
}

private func handleClient(_ fd: Int32, handler: @escaping (String, String, Data) -> (Int, String, Data)) {
    defer { close(fd) }
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var buf = Data()
    let sep = Data("\r\n\r\n".utf8)
    while buf.range(of: sep) == nil {
        var tmp = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &tmp, tmp.count, 0)
        guard n > 0 else { return }
        buf.append(contentsOf: tmp[0..<n])
        if buf.count > (1 << 20) { return }
    }
    guard let headerEnd = buf.range(of: sep),
          let head = String(data: buf.subdata(in: buf.startIndex..<headerEnd.lowerBound), encoding: .utf8) else { return }
    let lines = head.components(separatedBy: "\r\n")
    let parts = (lines.first ?? "").components(separatedBy: " ")
    guard parts.count >= 2 else { return }
    let method = parts[0]
    let path = parts[1]
    var body = Data(buf[headerEnd.upperBound...])
    var contentLength = 0
    for l in lines.dropFirst() where l.lowercased().hasPrefix("content-length:") {
        contentLength = Int(l.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
    }
    while body.count < contentLength {
        var tmp = [UInt8](repeating: 0, count: contentLength - body.count)
        let n = recv(fd, &tmp, tmp.count, 0)
        guard n > 0 else { return }
        body.append(contentsOf: tmp[0..<n])
    }
    let (status, ctype, payload) = handler(method, path, body)
    let statusText = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Error")
    var resp = Data("HTTP/1.1 \(status) \(statusText)\r\nContent-Type: \(ctype)\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
    resp.append(payload)
    var sent = 0
    while sent < resp.count {
        let n = resp[sent...].withUnsafeBytes { raw in send(fd, raw.baseAddress, raw.count, 0) }
        guard n > 0 else { return }
        sent += n
    }
}

func tailLog(_ n: Int) -> [String] {
    guard let fh = FileHandle(forReadingAtPath: logPath) else { return [] }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    try? fh.seek(toOffset: UInt64(max(0, Int64(size) - 400000)))
    let data = fh.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.components(separatedBy: "\n").suffix(n).map { $0 } ?? []
}

func makeHandler() -> (String, String, Data) -> (Int, String, Data) {
    func daemonAlive() -> [String: Any] {
        guard let s = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              kill(pid_t(pid), 0) == 0 else {
            return ["alive": false, "pid": NSNull()]
        }
        return ["alive": true, "pid": pid]
    }
    func json(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
    return { method, path, body in
        if path == "/" {
            if let html = try? String(contentsOfFile: stateDir + "/console.html", encoding: .utf8) {
                return (200, "text/html; charset=utf-8", Data(html.utf8))
            }
            return (200, "text/html; charset=utf-8", Data(pageHTML.utf8))
        }
        if path.hasPrefix("/api/state") {
            let obj: [String: Any] = [
                "daemon": daemonAlive(),
                "paused": fm.fileExists(atPath: pausePath),
                "state": readJSON(statePath) ?? NSNull(),
                "log": tailLog(80),
                "now": Date().timeIntervalSince1970,
            ]
            return (200, "application/json; charset=utf-8", json(obj))
        }
        if path.hasPrefix("/api/log") {
            return (200, "text/plain; charset=utf-8", Data(tailLog(300).joined(separator: "\n").utf8))
        }
        if path.hasPrefix("/api/control"), method == "POST" {
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let action = obj?["action"] as? String ?? ""
            switch action {
            case "pause":
                fm.createFile(atPath: pausePath, contents: nil)
                return (200, "application/json; charset=utf-8", Data(#"{"ok":true,"msg":"已暂停自动点击"}"#.utf8))
            case "resume":
                try? fm.removeItem(atPath: pausePath)
                return (200, "application/json; charset=utf-8", Data(#"{"ok":true,"msg":"已恢复自动点击"}"#.utf8))
            case "diag":
                fm.createFile(atPath: diagPath, contents: nil)
                return (200, "application/json; charset=utf-8", Data(#"{"ok":true,"msg":"诊断已触发，几秒后看日志"}"#.utf8))
            case "restart":
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                p.arguments = ["kickstart", "-k", "gui/\(getuid())/\(agentLabel)"]
                try? p.run()
                return (200, "application/json; charset=utf-8", Data(#"{"ok":true,"msg":"守望器已重启（冷却与计数清零）"}"#.utf8))
            default:
                return (200, "application/json; charset=utf-8", Data(#"{"ok":false,"msg":"未知操作"}"#.utf8))
            }
        }
        return (404, "text/plain; charset=utf-8", Data("not found".utf8))
    }
}

func requestAXPrompt() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let opts = [key: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
}

// ---------- 菜单栏 UI ----------

struct AppRow: Identifiable {
    let id: String
    var access: String = ""
    var nodes: Int = 0
    var windows: Int = 0
    var ms: Int = 0
    var err: Bool = false
    var target: String = ""
    var detail: String = ""
}

struct ClickRow: Identifiable {
    let id: String
    let at: Date
    let app: String
    let label: String
}

final class AppStatus: ObservableObject {
    @Published var alive = false
    @Published var pid = 0
    @Published var paused = false
    @Published var cooldownRemaining: TimeInterval = 0
    @Published var stateAge: TimeInterval = -1
    @Published var apps: [AppRow] = []
    @Published var clicks: [ClickRow] = []
    @Published var loaded = false
    @Published var loginItemOn = false

    init() {
        refresh()
        refreshLoginItem()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in self.refresh() }
    }

    var statusText: String {
        if paused { return "已暂停自动点击" }
        if cooldownRemaining > 0 { return String(format: "冷却中，剩 %.0f 分钟", ceil(cooldownRemaining / 60)) }
        if alive { return "守望器运行中" }
        return "守望器未运行"
    }

    var statusKind: Int {
        if !alive { return 2 }
        if paused || cooldownRemaining > 0 { return 1 }
        return 0
    }

    var symbol: String {
        if paused { return "pause.circle.fill" }
        if cooldownRemaining > 0 { return "hourglass" }
        if apps.contains(where: { $0.err }) { return "exclamationmark.triangle.fill" }
        if alive { return "arrow.triangle.2.circlepath.circle" }
        return "xmark.circle.fill"
    }

    func refresh() {
        var alive = false
        var pid = 0
        if let s = try? String(contentsOfFile: pidPath, encoding: .utf8) {
            pid = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if pid > 0, kill(pid_t(pid), 0) == 0 { alive = true }
        }
        let paused = fm.fileExists(atPath: pausePath)

        var cooldown: TimeInterval = 0
        var age: TimeInterval = -1
        var apps: [AppRow] = []
        var clicks: [ClickRow] = []
        if let j = readJSON(statePath) {
            let nowMs = Date().timeIntervalSince1970 * 1000
            let ts = j["ts"] as? Double ?? 0
            age = ts > 0 ? (nowMs - ts) / 1000 : -1
            let cdMs = j["cooldownUntil"] as? Double ?? 0
            cooldown = max(0, (cdMs - nowMs) / 1000)
            if let a = j["apps"] as? [String: Any] {
                for (name, v) in a.sorted(by: { $0.key < $1.key }) {
                    let d = v as? [String: Any] ?? [:]
                    apps.append(AppRow(
                        id: name,
                        access: d["access"] as? String ?? "",
                        nodes: d["nodes"] as? Int ?? 0,
                        windows: d["windows"] as? Int ?? 0,
                        ms: d["ms"] as? Int ?? 0,
                        err: d["errText"] as? Bool ?? false,
                        target: d["target"] as? String ?? "",
                        detail: d["detail"] as? String ?? ""))
                }
            }
            if let cl = j["clicks"] as? [[String: Any]] {
                clicks = cl.compactMap { c in
                    guard let at = c["at"] as? Double else { return nil }
                    return ClickRow(id: String(at),
                                    at: Date(timeIntervalSince1970: at / 1000),
                                    app: c["app"] as? String ?? "",
                                    label: c["label"] as? String ?? "")
                }
            }
        }

        self.alive = alive
        self.pid = pid
        self.paused = paused
        self.cooldownRemaining = cooldown
        self.stateAge = age
        self.apps = apps
        self.clicks = clicks
        self.loaded = true
    }

    func refreshLoginItem() {
        loginItemOn = (SMAppService.mainApp.status == .enabled) || launchAgentInstalled()
    }

    func launchAgentInstalled() -> Bool {
        fm.fileExists(atPath: NSString(string: "~/Library/LaunchAgents/com.local.antigravity-retry.plist").expandingTildeInPath)
    }

    func toggleLoginItem() {
        if launchAgentInstalled() { // LaunchAgent 方式：注销并移除
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootout", "gui/\(getuid())/\(agentLabel)"]
            try? p.run()
            try? fm.removeItem(atPath: NSString(string: "~/Library/LaunchAgents/com.local.antigravity-retry.plist").expandingTildeInPath)
        } else if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
            try? SMAppService.mainApp.unregister()
        } else {
            do { try SMAppService.mainApp.register() }
            catch { installLaunchAgent() } // 无签名应用注册登录项失败时，回退 LaunchAgent
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.refreshLoginItem() }
    }

    func installLaunchAgent() {
        let dir = NSString(string: "~/Library/LaunchAgents").expandingTildeInPath
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let exe = Bundle.main.executablePath ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict><key>Label</key><string>\(agentLabel)</string><key>ProgramArguments</key><array><string>\(exe)</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict>
        </plist>
        """
        let path = dir + "/com.local.antigravity-retry.plist"
        fm.createFile(atPath: path, contents: plist.data(using: .utf8))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootstrap", "gui/\(getuid())", path]
        try? p.run()
    }

    func pauseToggle() {
        if paused { try? fm.removeItem(atPath: pausePath) } else { fm.createFile(atPath: pausePath, contents: nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refresh() }
    }

    func restartDaemon() {
        var viaLaunchd = false
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "gui/\(getuid())/\(agentLabel)"]
        if (try? p.run()) != nil {
            p.waitUntilExit()
            viaLaunchd = p.terminationStatus == 0
        }
        if !viaLaunchd { // 登录项方式：重新拉起自己
            if let bundlePath = Bundle.main.bundlePath as String? {
                let q = Process()
                q.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                q.arguments = ["-n", bundlePath]
                try? q.run()
            }
            NSApp.terminate(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.refresh() }
    }

    func triggerDiag() {
        fm.createFile(atPath: diagPath, contents: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.refresh() }
    }

    func openConsole() { NSWorkspace.shared.open(consoleURL) }
    func revealLog() { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: logPath)]) }
}

struct ContentView: View {
    @ObservedObject var s: AppStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Antigravity 自动重试").font(.system(size: 13, weight: .semibold))
                Spacer()
                if s.alive {
                    Text("pid \(s.pid)").font(.caption2).foregroundColor(.secondary)
                }
            }

            HStack(spacing: 6) {
                badge(text: s.statusText, kind: s.statusKind)
                if s.stateAge >= 0 {
                    Text(agoText(s.stateAge)).font(.caption2).foregroundColor(.secondary)
                }
            }

            if s.apps.contains(where: { $0.access == "denied" }) {
                HStack {
                    Text("需要辅助功能授权才能读写界面").font(.caption2).foregroundColor(.red)
                    Spacer()
                    Button("去授权") { requestAXPrompt() }.controlSize(.small)
                }
            }

            ForEach(s.apps) { row in
                HStack {
                    Circle().fill(dotColor(row)).frame(width: 7, height: 7)
                    Text(row.id).font(.system(size: 12, weight: .medium))
                    Spacer()
                    if row.access == "ok" {
                        Text("\(row.nodes) 节点 · \(row.ms) ms")
                            .font(.caption2).foregroundColor(.secondary)
                        if row.err {
                            Text("错误卡片·将重试").font(.caption2).foregroundColor(.red)
                        } else {
                            Text("正常").font(.caption2).foregroundColor(.secondary)
                        }
                    } else if row.access == "denied" {
                        Text("未授权").font(.caption2).foregroundColor(.red)
                    } else if row.access == "absent" {
                        Text("未运行").font(.caption2).foregroundColor(.secondary)
                    } else if !row.detail.isEmpty {
                        Text(row.detail).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            if s.clicks.isEmpty {
                Text("暂无自动点击记录").font(.caption2).foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("最近自动点击").font(.caption2).foregroundColor(.secondary)
                    ForEach(Array(s.clicks.suffix(4).reversed())) { c in
                        HStack {
                            Text(Self.fmt(c.at)).font(.caption2).foregroundColor(.secondary).frame(width: 60, alignment: .leading)
                            Text("点击 \"\(c.label)\" (\(c.app))").font(.caption)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button(s.paused ? "▶ 恢复" : "⏸ 暂停") { s.pauseToggle() }
                Button("重启") { s.restartDaemon() }
                Button("诊断") { s.triggerDiag() }
                Spacer()
                Button("控制台") { s.openConsole() }
            }
            HStack {
                Button("日志文件") { s.revealLog() }
                Button(s.loginItemOn ? "开机自启: 开" : "开机自启: 关") { s.toggleLoginItem() }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    static func fmt(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    func agoText(_ sec: TimeInterval) -> String {
        if sec < 5 { return "刚刚更新" }
        if sec < 60 { return String(format: "%.0f 秒前更新", sec) }
        return String(format: "%.0f 分钟前更新", sec / 60)
    }

    func dotColor(_ row: AppRow) -> Color {
        switch row.access {
        case "ok": return .green
        case "denied", "error": return .red
        default: return .gray
        }
    }

    func badge(text: String, kind: Int) -> some View {
        let color: Color = kind == 0 ? .green : (kind == 1 ? .yellow : .red)
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(6)
    }
}

@main
struct RetryApp: App {
    @StateObject private var status = AppStatus()

    init() {
        Engine.shared.start()
        startPosixHttp(port: 17377, handler: makeHandler())
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(s: status)
        } label: {
            Image(systemName: status.symbol)
        }
        .menuBarExtraStyle(.window)
    }
}
