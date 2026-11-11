#!/bin/bash
# 把仓库里的网页 / 图标 / 守护配置部署到已安装的 App。
# 特点：不需要重新编译，也不改动 Contents/ 内任何签名文件，因此不会破坏辅助功能授权。
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$HOME/Library/Application Support/AntigravityAutoRetry"
LABEL="com.local.antigravity-retry"
APP="/Applications/AntigravityRetry.app"
[ -d "$APP" ] || APP="$HOME/Applications/AntigravityRetry.app"
[ -d "$APP" ] || { echo "未找到 AntigravityRetry.app，请先安装"; exit 1; }

mkdir -p "$STATE"

echo "==> 部署控制台页面（程序会优先读取 console.html 覆盖内嵌页面）"
cp "$SRC/web/console.html" "$STATE/console.html"

echo "==> 写入 Finder 自定义图标（仅 app 根目录，不进 Contents/）"
cp "$SRC/assets/AppIcon.icns" "$APP/Icon"$'\r'
if ! SetFile -a C "$APP" 2>/dev/null; then
  echo "SetFile 失败：图标可能不会立刻显示，但文件已就位"; fi

echo "==> 检查 LaunchAgent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  echo "  已注册，跳过（不改动现有配置）"
else
  mkdir -p "$HOME/Library/LaunchAgents"
  python3 - "$SRC/LaunchAgents/$LABEL.plist" "$PLIST" "$APP/Contents/MacOS/AntigravityRetry" "$STATE" <<'PY'
import plistlib, sys
src, dst, exe, state = sys.argv[1:]
with open(src, "rb") as f:
    p = plistlib.load(f)
p["ProgramArguments"] = [exe]
p["StandardOutPath"] = state + "/launchd.out.log"
p["StandardErrorPath"] = state + "/launchd.err.log"
with open(dst, "wb") as f:
    plistlib.dump(p, f)
print("  已写入", dst)
PY
  if ! launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
    echo "  当前会话注册失败；plist 已就位，下次登录会自动加载"
  fi
fi

echo "==> 验证签名"
if codesign -v "$APP" 2>/dev/null; then
  echo "  签名有效（CDHash 未变，辅助功能授权不受影响）"
else
  echo "  警告：签名校验失败，请检查"; fi

echo "完成。控制台：http://127.0.0.1:17377"
echo "回滚网页外观：删除 $STATE/console.html 即可恢复内嵌页面。"
