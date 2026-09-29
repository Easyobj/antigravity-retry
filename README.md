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
├── page-html.swift               网页控制台页面（内嵌字符串）
├── build-dist.sh                 打包脚本（双架构 + 安装器 + 说明，产出 zip 到桌面）
└── antigravity-auto-retry        管理命令（status/pause/restart/ui/logs…）
```

## 构建

```bash
./build-dist.sh          # 产出 ~/Desktop/AntigravityRetry-macOS.zip（arm64 + x86_64，最低 macOS 13）
```

要求：Xcode Command Line Tools（swiftc）。

## 本机安装/更新

```bash
./build-dist.sh                                   # 打包
# 替换本机安装（需要重新授权一次，见下）
killall AntigravityRetry 2>/dev/null
rm -rf ~/Applications/AntigravityRetry.app        # 或 /Applications
cp -R /path/to/AntigravityRetry.app ~/Applications/
launchctl kickstart -k gui/$(id -u)/com.local.antigravity-retry
```

开机自启：首次由 `~/Library/LaunchAgents/com.local.antigravity-retry.plist`
（LaunchAgent）管理；菜单栏面板里也有「开机自启」开关（登录项方式）。

## 权限

App 需要辅助功能权限才能读取/点击 Antigravity 界面：
系统设置 → 隐私与安全性 → 辅助功能 → 打开 AntigravityRetry。

注意：应用未公证（ad-hoc 签名），**重新编译后 macOS 会视为新程序**，
需要重新授权一次；授权后若仍显示未授权，`antigravity-auto-retry restart`
重启进程即可生效。改 `axhelper.swift` / `page-html.swift` / 控制台页面不影响授权
（控制台页面也可以放一份 `console.html` 到状态目录做运行时覆盖，便于调试）。

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
