#!/bin/bash
# 卸载联动：停进程、删 LaunchAgent。设备灯效会停在被卸载时的状态。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for LABEL in com.proma.vibekey-bridge com.proma.vibekey-menubar; do
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  if launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null; then
    echo "✅ 已停止 $LABEL"
  else
    echo "（$LABEL 本来就没跑）"
  fi
  [ -f "$PLIST" ] && rm -f "$PLIST" && echo "✅ 已删除 $PLIST"
done

# 清掉可能残留的脉冲子进程
pkill -f "vibekit-led pulse-loop" 2>/dev/null && echo "✅ 已清理残留脉冲进程" || true

echo
echo "设备灯效没有改回去。想恢复成「工作模式」："
echo "  \"$HERE/bin/vibekit-led\" mode 2"
