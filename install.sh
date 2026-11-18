#!/bin/bash
# 安装 VibeKey 灯光联动：注册 LaunchAgent，登录自启 + 崩溃自动拉起。
# 可重复执行（会先卸载旧的再装）。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.proma.vibekey-bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/PromaVibeKey"

# 挑 Python：优先用装了项目依赖的 framework 版，其次系统 python3
PY=""
for c in /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 "$(command -v python3 || true)"; do
  if [ -n "$c" ] && [ -x "$c" ]; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "❌ 找不到 python3"; exit 1; }

if [ ! -x "$HERE/bin/vibekit-led" ]; then
  echo "❌ 缺少 bin/vibekit-led，先跑 ./build.sh 或从备份拷回来"; exit 1
fi

mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"

# 卸载旧的（忽略不存在的情况）
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PY</string>
        <string>$HERE/bridge.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>Nice</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/launchd.err.log</string>
</dict>
</plist>
PLISTEOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"

sleep 2
if launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -q "state = running"; then
  echo "✅ 已安装并运行"
  echo "   项目目录：$HERE"
  echo "   解释器：  $PY"
  echo "   日志：    $LOG_DIR/bridge.log"
  echo
  echo "   验证：   python3 \"$HERE/bridge.py\" --status"
else
  echo "⚠️ 已写入 plist 但进程没起来，看 $LOG_DIR/launchd.err.log"
  exit 1
fi
