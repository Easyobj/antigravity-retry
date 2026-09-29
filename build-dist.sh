#!/bin/bash
# AntigravityRetry 分发打包脚本
# 产出: ~/Desktop/AntigravityRetry-macOS.zip（App + 一键安装脚本 + 使用说明）
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
STAGE="$(mktemp -d)"
APP_NAME="AntigravityRetry.app"
APP="$STAGE/$APP_NAME"
OUT_ZIP="$HOME/Desktop/AntigravityRetry-macOS.zip"

# 通用二进制：分别编译 arm64 / x86_64（最低支持 macOS 13）后 lipo 合并
build_universal() {
  local out="$1"; shift
  swiftc -O -target arm64-apple-macos13.0 -o "$out.arm64" "$@"
  swiftc -O -target x86_64-apple-macos13.0 -o "$out.x86_64" "$@"
  lipo -create -output "$out" "$out.arm64" "$out.x86_64"
  rm -f "$out.arm64" "$out.x86_64"
}
build_universal_lib() {
  local out="$1"; shift
  swiftc -parse-as-library -O -target arm64-apple-macos13.0 -o "$out.arm64" "$@"
  swiftc -parse-as-library -O -target x86_64-apple-macos13.0 -o "$out.x86_64" "$@"
  lipo -create -output "$out" "$out.arm64" "$out.x86_64"
  rm -f "$out.arm64" "$out.x86_64"
}

echo "==> 编译 axhelper（界面扫描器，通用二进制）"
build_universal "$STAGE/axhelper" "$SRC/axhelper.swift"

echo "==> 编译主程序（通用二进制）"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
build_universal_lib "$APP/Contents/MacOS/AntigravityRetry" \
  "$SRC/antigravity-retry-app.swift" "$SRC/page-html.swift"
mv "$STAGE/axhelper" "$APP/Contents/Resources/axhelper"
chmod +x "$APP/Contents/Resources/axhelper"

echo "==> 写入 Info.plist 并签名"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>AntigravityRetry</string>
	<key>CFBundleDisplayName</key><string>Antigravity 自动重试</string>
	<key>CFBundleIdentifier</key><string>com.local.antigravity-retry-bar</string>
	<key>CFBundleVersion</key><string>1.1</string>
	<key>CFBundleShortVersionString</key><string>1.1</string>
	<key>CFBundleExecutable</key><string>AntigravityRetry</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSUIElement</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
EOF
codesign --force -s - --identifier com.local.antigravity-retry-bar "$APP"

echo "==> 生成一键安装脚本"
cat > "$STAGE/安装.command" <<'EOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "==> 安装 Antigravity 自动重试…"
killall AntigravityRetry 2>/dev/null
xattr -dr com.apple.quarantine AntigravityRetry.app 2>/dev/null || true
DEST="/Applications"
if ! cp -R AntigravityRetry.app "$DEST/" 2>/dev/null; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  rm -rf "$DEST/AntigravityRetry.app"
  cp -R AntigravityRetry.app "$DEST/"
fi
echo "==> 已安装到 $DEST/AntigravityRetry.app，正在启动…"
open "$DEST/AntigravityRetry.app"
sleep 1
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
osascript -e 'display notification "请在辅助功能列表中打开 AntigravityRetry" with title "安装完成，还需一步授权"'
echo "==> 完成！请在系统设置 → 隐私与安全性 → 辅助功能 中打开 AntigravityRetry"
EOF
chmod +x "$STAGE/安装.command"

echo "==> 生成使用说明"
cat > "$STAGE/使用说明.txt" <<'EOF'
Antigravity 自动重试 — 使用说明
================================

这是一个 macOS 菜单栏小工具：当 Antigravity / Antigravity IDE 的 agent 面板
出现 "Agent terminated due to error" 等报错卡片时，自动点击 Retry 重试，
免去手动反复点击。

安装（macOS 13+，需装有 Antigravity）
--------------------------------------
1. 解压本压缩包
2. 双击「安装.command」（若提示无法打开：右键 → 打开）
   脚本会把 App 装到 /Applications 并启动，随后自动打开系统设置的
   「辅助功能」页面
3. 在辅助功能列表里打开 AntigravityRetry 的开关 —— 完成！
   菜单栏出现圆形箭头图标即为运行中

菜单栏图标含义
--------------
⟳  运行中        ⚠️ 检测到错误卡片（将自动重试）
⏸  已暂停        ⏳  重试冷却中

点击图标可查看实时状态，并进行：暂停/恢复、重启、诊断、
打开网页控制台（http://127.0.0.1:17377，含完整实时日志）、
开机自启开关等操作。

安全机制
--------
- 只在检测到报错卡片文案 + Retry/Try again 按钮时点击
- 10 分钟内最多自动重试 6 次，超过自动冷却 15 分钟
  （说明错误可能不是临时性的，建议检查或换新会话）
- 所有数据仅保存在本机 ~/Library/Application Support/AntigravityAutoRetry/

卸载
----
菜单栏图标 → 退出；然后把 /Applications（或 ~/Applications）里的
AntigravityRetry.app 删除，并在辅助功能列表中移除 AntigravityRetry 即可。
EOF

echo "==> 打包 zip"
rm -f "$OUT_ZIP"
(cd "$STAGE" && zip -qry "$OUT_ZIP" "$APP_NAME" "安装.command" "使用说明.txt")
echo "完成: $OUT_ZIP ($(du -h "$OUT_ZIP" | cut -f1))"
ls -la "$STAGE"