#!/bin/bash
# 卸载联动：停进程、删 LaunchAgent。设备灯效会停在被卸载时的状态。
set -uo pipefail

LABEL="com.proma.vibekey-bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "✅ 进程已停止" || echo "（进程本来就没跑）"
[ -f "$PLIST" ] && rm -f "$PLIST" && echo "✅ 已删除 $PLIST"

# 清掉可能残留的脉冲子进程
pkill -f "vibekit-led pulse-loop" 2>/dev/null && echo "✅ 已清理残留脉冲进程" || true

echo
echo "设备灯效没有改回去。想恢复成「工作模式」："
echo "  \"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/vibekit-led\" mode 2"
