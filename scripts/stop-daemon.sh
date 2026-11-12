#!/bin/bash
# 真正停止 Antigravity 自动重试。
# LaunchAgent 带 KeepAlive，直接 kill / 点旧版「退出」会被 launchd 在约 10 秒内拉回，
# 因此必须先 bootout 卸载服务。只卸载、不删 plist：下次登录仍按开机自启设置启动。
# 注意：变量一律写成 ${VAR}。$LABEL 紧跟中文标点时，部分 shell 会把多字节字符
# 并入变量名，set -u 下会报 "unbound variable"（2026-11-12 修复）。
set -u

LABEL="com.local.antigravity-retry"
DOMAIN="gui/$(id -u)"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
SERVICE="${DOMAIN}/${LABEL}"

if launchctl print "${SERVICE}" >/dev/null 2>&1; then
  if launchctl bootout "${SERVICE}" 2>/dev/null; then
    echo "已卸载 ${LABEL}: 进程已停止，不会再被自动拉起。"
  else
    echo "卸载失败。请在你自己的终端.app 里执行："
    echo "  launchctl bootout ${SERVICE}"
    exit 1
  fi
else
  echo "${LABEL} 当前未注册（服务此前已卸载，或本来就没在运行）。"
fi

if [ -f "${PLIST}" ]; then
  echo "plist 已保留: ${PLIST} —— 下次登录仍会自启。"
  echo "彻底禁用: launchctl disable ${SERVICE}"
  echo "恢复运行: launchctl bootstrap ${DOMAIN} \"${PLIST}\""
else
  echo "未找到 plist，无需恢复操作。"
fi
