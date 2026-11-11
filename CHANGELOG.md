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

## 2026-11-11（续）— 退出被守护拉回、多实例重复守望

装好 `KeepAlive` 守护后又发现两个交互问题，一并修复。

### 修复

- **「退出」能真正退出了**：菜单栏按钮原先只调 `NSApp.terminate(nil)`，
  进程退出后 launchd 立刻拉起，表现为「关不掉」、日志里 `runs` 持续增长。
  新增 `AppStatus.quitApp()`：先同步执行
  `launchctl bootout gui/<uid>/com.local.antigravity-retry` 卸载服务再退出；
  只卸载、保留 plist，下次登录仍按开机自启设置启动。卸载失败会写日志提示。
- **不再出现第二个守望引擎**：`startPosixHttp()` 原先在子线程里 bind，
  失败仅 `return`，进程仍继续跑守望循环、写 pid 文件、占菜单栏——
  即「没有控制台、却仍在自动点击」的僵尸实例。改为启动期同步 bind/listen
  并返回 `Bool`，`RetryApp.init()` 在绑定失败时写日志后 `exit(0)`，
  只有成功持有 17377 的实例才启动 `Engine.shared`。

### 新增

- `scripts/stop-daemon.sh`：手动停止守护（bootout + 状态回显），
  旧版本二进制没有内置退出修复时用它。
- README 增补「退出与单实例」章节，列出停止 / 禁用 / 恢复命令。
