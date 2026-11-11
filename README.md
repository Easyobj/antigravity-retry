# Antigravity 自动重试 (AntigravityRetry)

一个 macOS 菜单栏应用：当 Antigravity / Antigravity IDE 的 agent 面板出现
"Agent terminated due to error" 等报错卡片时，自动点击 Retry/Try again，
免去手动反复点击。

单体应用，一个进程包含三部分：

| 组件 | 说明 |
|---|---|
| 守望引擎 | 每 3 秒调用 `axhelper` 扫描界面树，检测报错卡片并自动重试 |
| 菜单栏界面 | SwiftUI `MenuBarExtra`，实时状态 + 暂停/重启/诊断等控制 |
| 本地控制台 | 内置 HTTP 服务 http://127.0.0.1:17377（完整实时日志） |

## 仓库结构

```
antigravity-retry/
├── antigravity-retry-app.swift   主程序：守望引擎 + 菜单栏 UI + 内置控制台
├── axhelper.swift                界面扫描器（独立进程，需辅助功能权限）
├── page-html.swift               网页控制台页面（内嵌字符串，logo 用 \#(faviconDataURI)）
├── build-dist.sh                 打包脚本（双架构 + 图标 + 安装器 + 说明，产出 zip 到桌面）
├── antigravity-auto-retry        管理命令（status/pause/restart/ui/logs…）
├── assets/
│   ├── AppIcon.svg               图标源文件（改这里）
│   ├── AppIcon-1024.png          1024 导出图
│   ├── AppIcon.icns              macOS 图标（构建时放入 Contents/Resources）
│   ├── AppIcon.iconset/          全套尺寸
│   ├── favicon.png / favicon.ico 网页用图标
│   └── AppIconData.swift         自动生成：favicon 的 data URI 常量
├── web/
│   ├── console.html              自动生成：完整控制台页，用于运行时覆盖
│   └── console-launcher.html     可选的独立入口页（带 logo，iframe 嵌控制台）
├── LaunchAgents/
│   └── com.local.antigravity-retry.plist   已验证可用的守护模板
├── scripts/
│   ├── regenerate-icons.sh       从 AppIcon.svg 重建全部图标并同步网页
│   └── apply-assets.sh           把网页/图标/守护部署到已安装的 App（不重编译、不破坏签名）
└── CHANGELOG.md
```

## 构建

```bash
./build-dist.sh          # 产出 ~/Desktop/AntigravityRetry-macOS.zip（arm64 + x86_64，最低 macOS 13）
```

要求：Xcode Command Line Tools（swiftc）。构建时会编译
`antigravity-retry-app.swift` + `page-html.swift` + `assets/AppIconData.swift`，
并把 `AppIcon.icns` 放进 `Contents/Resources`、在 Info.plist 写入 `CFBundleIconFile`，
所以产出的 App 自带图标。

## 图标与控制台外观

- **改图标**：编辑 `assets/AppIcon.svg`，然后跑 `./scripts/regenerate-icons.sh`。
  它会重建 PNG / iconset / icns / favicon，并同步 `AppIconData.swift` 与 `web/console.html`。
- 控制台网页的 favicon 和顶部 logo 用 data URI 内嵌（无需额外 HTTP 路由），
  数据源是 `assets/AppIconData.swift` 里的 `faviconDataURI` 常量。
- **不重新编译也能换网页外观**：主程序处理 `/` 时会优先读取
  `~/Library/Application Support/AntigravityAutoRetry/console.html`，
  存在就用它覆盖内嵌页面。把 `web/console.html` 放过去即可；删掉即恢复内嵌页面。
- `scripts/apply-assets.sh` 一次性完成：部署 console.html、写入 Finder 自定义图标、
  注册 LaunchAgent。它只往 App **根目录**写 `Icon\r` 并置 FinderFlags，
  **不改动 `Contents/` 内任何签名文件**，因此 CDHash 不变、辅助功能授权不会失效。
- 菜单栏状态图标由代码绘制（⟳ / ⚠️ / ⏸ / ⏳），不随 AppIcon 变化。

## 本机安装 / 更新

```bash
./build-dist.sh                                   # 打包
./scripts/apply-assets.sh                         # 仅部署资源，不重新编译（推荐）
# 或完整替换安装（需要重新授权一次，见下）
killall AntigravityRetry 2>/dev/null
rm -rf ~/Applications/AntigravityRetry.app        # 或 /Applications
cp -R /path/to/AntigravityRetry.app ~/Applications/
launchctl kickstart -k gui/$(id -u)/com.local.antigravity-retry
```

## 开机自启与 2 小时自检

主程序每运行 2 小时会做一次「定时自检重启」：打印日志后 `exit(0)`，
由 LaunchAgent 的 `KeepAlive` 立即拉起，用来定期清理 AX 扫描状态。

⚠️ **这个设计强依赖守护已注册**。2026-11-11 排查过一次「经常自动退出」：
日志显示共 14 次自检重启，每次之后都出现 4.5～233 小时的空档，原因是
`~/Library/LaunchAgents/com.local.antigravity-retry.plist` 根本不存在——
菜单栏「开机自启」优先走 `SMAppService.mainApp.register()`，未签名应用可能
注册后并未真正生效且不抛错，于是不会回退到 `installLaunchAgent()`，plist 始终没写。

本仓库已做两处修复：

1. `Engine.loop()` 在自检点调用 `launchAgentActive()`（`launchctl print`）确认守护
   真的注册了；未注册时**跳过退出**、重置计时并记日志，不再自己消失。
2. `installLaunchAgent()` 生成的 plist 补齐 `ThrottleInterval=10`、
   `StandardOutPath` / `StandardErrorPath`（与 `LaunchAgents/` 模板一致）；
   `bootstrap` 失败时写日志说明「下次登录自动生效」，不再静默失败。

守护模板字段：`Label=com.local.antigravity-retry`、`RunAtLoad=true`、
`KeepAlive=true`、`ThrottleInterval=10`。检查方式：

```bash
launchctl print gui/$(id -u)/com.local.antigravity-retry
```

## 退出与单实例

`KeepAlive=true` 意味着**直接结束进程会被 launchd 在约 10 秒内拉回**，
所以菜单栏「退出」按钮会先 `launchctl bootout` 卸载服务再 `NSApp.terminate`；
只卸载、不删 plist，下次登录仍按开机自启设置启动。旧版本没有这个处理，
需要手动停止时：

```bash
./scripts/stop-daemon.sh                                       # 停止守护（推荐）
launchctl bootout gui/$(id -u)/com.local.antigravity-retry    # 同上，仅本次会话停用
launchctl disable gui/$(id -u)/com.local.antigravity-retry    # 连下次登录也禁用
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.antigravity-retry.plist  # 恢复
```

单实例保护：启动时同步抢占 17377 端口，绑定失败即写日志并 `exit(0)`，
**不会启动第二个守望引擎**（旧版本绑定失败后仍会跑守望循环并覆盖 pid 文件，
造成两个进程同时自动点击）。因此不要同时打开多个副本；要换用新构建的版本，
先 `stop-daemon.sh` 停掉守护，再安装/启动新 App。

## 权限

App 需要辅助功能权限才能读取/点击 Antigravity 界面：
系统设置 → 隐私与安全性 → 辅助功能 → 打开 AntigravityRetry。

注意：应用未公证（ad-hoc 签名），**重新编译后 macOS 会视为新程序**，
需要重新授权一次；授权后若仍显示未授权，`antigravity-auto-retry restart`
重启进程即可生效。改 `axhelper.swift` / `page-html.swift` / 控制台页面不影响授权
（控制台页面也可以放一份 `console.html` 到状态目录做运行时覆盖，便于调试）。
`scripts/apply-assets.sh` 走的正是这条不破坏签名的路径；
`Downloads` 里多个不同副本混用也会导致权限反复失效，建议固定只用一份 App。

## 安全机制

- 只在检测到报错卡片文案 + Retry/Try again 按钮时点击
- 10 分钟内最多自动重试 6 次，超过冷却 15 分钟（防止对必然失败的任务无限消耗配额）
- 数据仅保存在本机 `~/Library/Application Support/AntigravityAutoRetry/`

## 管理命令

```bash
antigravity-auto-retry status   # 状态 + 最近日志
antigravity-auto-retry pause    # 暂停自动点击
antigravity-auto-retry resume   # 恢复
antigravity-auto-retry restart  # 重启（清零冷却/计数）
antigravity-auto-retry scan     # 立即诊断一次
antigravity-auto-retry ui       # 打开网页控制台
antigravity-auto-retry logs     # 实时日志
antigravity-auto-retry unload   # 彻底停用
```

## 分发

`build-dist.sh` 产出的 zip 可直接发给别人（微信/AirDrop/网盘）。
对方：解压 → 双击「安装.command」→ 在辅助功能列表打开 AntigravityRetry。
要求 macOS 13+ 且装有 Antigravity（通用二进制，Apple Silicon / Intel 均可）。

如需去除 Gatekeeper 提示做到"下载即用"，需要 Apple Developer Program（$99/年）
进行 Developer ID 签名与公证。

## 技术要点

- Electron/Chromium 应用默认不构建辅助功能树，需先对其 App 元素写入
  `AXManualAccessibility=true` 唤醒（在 `axhelper` 中用 C API 直接设置）
- 界面遍历在 `axhelper` 进程内完成（百毫秒级），避免 System Events
  逐节点 Apple Events 的秒级开销
- 目标应用：`com.google.antigravity`、`com.google.antigravity-ide`
