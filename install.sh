#!/bin/bash
# 安装 VibeKey 联动：两个 LaunchAgent
#   1) com.proma.vibekey-bridge   — 灯光桥接（Python）
#   2) com.proma.vibekey-menubar  — 菜单栏状态显示（Swift App）
# 都是登录自启 + 崩溃自动拉起。可重复执行（会先卸载旧的再装）。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.proma.vibekey-bridge"
LABEL_MENU="com.proma.vibekey-menubar"
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/$LABEL.plist"
PLIST_MENU="$AGENTS/$LABEL_MENU.plist"
LOG_DIR="$HOME/Library/Logs/PromaVibeKey"
APP="$HERE/bin/VibeKeyStatusBar.app"
APP_BIN="$APP/Contents/MacOS/VibeKeyStatusBar"

# 挑 Python：优先用装了项目依赖的 framework 版，其次系统 python3
PY=""
for c in /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 "$(command -v python3 || true)"; do
  if [ -n "$c" ] && [ -x "$c" ]; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "❌ 找不到 python3"; exit 1; }

if [ ! -x "$HERE/bin/vibekit-led" ]; then
  echo "❌ 缺少 bin/vibekit-led，先跑 ./build.sh 或从备份拷回来"; exit 1
fi

# 菜单栏 App 缺失时尝试自动编译（需要 Xcode CLI 工具）
if [ ! -x "$APP_BIN" ]; then
  echo "==> 还没编译菜单栏 App，尝试自动编译"
  if [ -x "$HERE/build-menubar.sh" ] && command -v swiftc >/dev/null; then
    "$HERE/build-menubar.sh"
  else
    echo "❌ 缺少 bin/VibeKeyStatusBar.app，先装 Xcode CLI 工具再跑 ./build-menubar.sh"; exit 1
  fi
fi

mkdir -p "$LOG_DIR" "$AGENTS"

# 卸载旧的（忽略不存在的情况）
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LABEL_MENU" 2>/dev/null || true

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

cat > "$PLIST_MENU" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL_MENU</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/menubar.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/menubar.err.log</string>
</dict>
</plist>
PLISTEOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST_MENU"

sleep 3
OK_BRIDGE=0
OK_MENU=0
launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -q "state = running" && OK_BRIDGE=1
launchctl print "gui/$(id -u)/$LABEL_MENU" 2>/dev/null | grep -q "state = running" && OK_MENU=1

if [ "$OK_BRIDGE" = "1" ] && [ "$OK_MENU" = "1" ]; then
  echo "✅ 已安装并运行（灯光桥接 + 菜单栏状态）"
  echo "   项目目录：$HERE"
  echo "   解释器：  $PY"
  echo "   日志：    $LOG_DIR/bridge.log"
  echo
  echo "   验证：   python3 \"$HERE/bridge.py\" --status"
  echo "   菜单栏没出现时看：$LOG_DIR/menubar.err.log"
else
  [ "$OK_BRIDGE" = "1" ] || echo "⚠️ 灯光桥接没起来，看 $LOG_DIR/launchd.err.log"
  [ "$OK_MENU" = "1" ] || echo "⚠️ 菜单栏没起来，看 $LOG_DIR/menubar.err.log"
  exit 1
fi
