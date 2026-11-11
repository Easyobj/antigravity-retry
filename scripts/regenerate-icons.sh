#!/bin/bash
# 从 assets/AppIcon.svg 重新生成全部图标资源，并同步内嵌 favicon 与 web/console.html
# 依赖：rsvg-convert (brew install librsvg)、magick、iconutil (Xcode CLT)、python3
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
A="$SRC/assets"

for t in rsvg-convert magick iconutil python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "缺少依赖: $t"; exit 1; }
done

echo "==> 渲染 1024 PNG"
rsvg-convert -w 1024 -h 1024 "$A/AppIcon.svg" -o "$A/AppIcon-1024.png"

echo "==> 生成 iconset / icns / favicon"
mkdir -p "$A/AppIcon.iconset"
for s in 16 32 128 256 512; do
  d=$((s * 2))
  magick "$A/AppIcon-1024.png" -resize "${s}x${s}" -strip "$A/AppIcon.iconset/icon_${s}x${s}.png"
  magick "$A/AppIcon-1024.png" -resize "${d}x${d}" -strip "$A/AppIcon.iconset/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$A/AppIcon.iconset" -o "$A/AppIcon.icns"
cp "$A/AppIcon.iconset/icon_32x32@2x.png" "$A/favicon.png"
magick "$A/favicon.png" -strip -define icon:auto-resize=64,48,32,16 "$A/favicon.ico"

echo "==> 同步 Swift 常量与 web/console.html"
python3 - "$SRC" <<'PY'
import base64, pathlib, re, sys
d = pathlib.Path(sys.argv[1])
uri = "data:image/png;base64," + base64.b64encode((d / "assets/favicon.png").read_bytes()).decode()
(d / "assets/AppIconData.swift").write_text(
    "// AppIconData.swift — 由 scripts/regenerate-icons.sh 自动生成，请勿手改\n"
    "// 64x64 PNG 的 data URI，供控制台网页 favicon 与顶部 logo 使用。\n"
    f'let faviconDataURI = "{uri}"\n'
)
src = (d / "page-html.swift").read_text()
m = re.search(r'let pageHTML = #"""\n(.*?)\n"""#', src, re.S)
assert m, "page-html.swift 结构异常，无法提取 HTML"
html = m.group(1).replace(r"\#(faviconDataURI)", uri)
assert r"\#(" not in html, "仍有未替换的 Swift 插值"
(d / "web/console.html").write_text(html)
print("  AppIconData.swift 与 web/console.html 已同步")
PY

echo "完成。修改 AppIcon.svg 后重跑本脚本即可全量更新；如需改变页面结构请改 page-html.swift。"
