# 变更记录

## 2026-11-11 — 图标、网页 logo、守护与自检重启修复

本机排查「Antigravity 自动重试控制台经常自动退出」后，把结果同步进仓库。

### 修复

- **自检重启不再导致服务消失**：`Engine.loop()` 的 2 小时自检原先无条件
  `exit(0)`，依赖 launchd 拉起。新增 `launchAgentActive()`（`launchctl print` 探测），
  未注册时跳过退出、重置计时并写日志。有守护时行为不变。
- **`installLaunchAgent()` 生成的 plist 补齐字段**：`ThrottleInterval=10`、
  `StandardOutPath` / `StandardErrorPath`；`bootstrap` 失败时写日志提示
  「下次登录自动生效」，不再静默失败。新增 `LaunchAgents/` 下的已验证模板。
- **修正控制台页面里的服务名**：`com.local.antigravity-auto-retry` →
  实际使用的 `com.local.antigravity-retry`。
- 提取 `agentPlistPath` 常量，去掉散落的路径字面量。

### 新增

- `assets/`：App 图标（SVG 源文件 + PNG / iconset / icns / favicon），
  `AppIconData.swift` 内嵌 favicon 的 data URI。
- `web/console.html`：由 `page-html.swift` 生成，带 logo，可用于运行时覆盖；
  `web/console-launcher.html`：可选的独立入口页。
- `scripts/regenerate-icons.sh`：改 SVG 后一键重建全部图标并同步网页。
- `scripts/apply-assets.sh`：部署网页 / Finder 图标 / 守护到已安装 App，
  不重新编译、不改 `Contents/` 内签名内容（CDHash 不变，辅助功能授权不失效）。
- `build-dist.sh`：`AppIcon.icns` 进 bundle、Info.plist 加 `CFBundleIconFile`、
  编译 `AppIconData.swift`，产出的 App 自带图标与网页 logo。
- `page-html.swift`：favicon + 顶部 logo（引用 `faviconDataURI`）。

### 排查结论（备查）

- 日志 `~/Library/Application Support/AntigravityAutoRetry/antigravity-auto-retry.log`
  时间戳为 UTC；共记录 14 次「定时自检重启」、19 次启动，运行长度精确 2.00 小时，
  重启后空档 4.5～233 小时；无崩溃报告，排除崩溃退出。
- App 为 ad-hoc 签名，替换二进制会让 TCC 辅助功能授权失效，因此图标采用
  Finder 自定义图标方案（`Icon\r` + `SetFile -a C`）而非改动 bundle 内容。
- 图像工具默认会写入时间戳元数据，导致每次重跑生成的 base64 不同；
  `regenerate-icons.sh` 统一加 `-strip` 保证输出确定、可重复。
