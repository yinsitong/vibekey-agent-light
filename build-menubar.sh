#!/bin/bash
# 编译菜单栏 App（bin/VibeKeyStatusBar.app）
#
# 单文件 Swift + swiftc，零第三方依赖：不需要 pip、不需要 Xcode 工程。
# 产物是一个 LSUIElement 的 .app（不占 Dock、只在顶部状态栏出现），
# 由 LaunchAgent 常驻拉起，与灯光桥接进程同源读 status.json。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/menubar/VibeKeyStatusBar.swift"
APP="$HERE/bin/VibeKeyStatusBar.app"

command -v swiftc >/dev/null || { echo "❌ 没有 swiftc，先装 Xcode Command Line Tools：xcode-select --install"; exit 1; }
[ -f "$SRC" ] || { echo "❌ 找不到源码：$SRC"; exit 1; }

TMPDIR_BUILD="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BUILD"' EXIT

STAGE="$TMPDIR_BUILD/VibeKeyStatusBar.app"
mkdir -p "$STAGE/Contents/MacOS"

echo "==> 编译菜单栏 App"
swiftc -O -swift-version 5 -o "$STAGE/Contents/MacOS/VibeKeyStatusBar" "$SRC"

cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>VibeKeyStatusBar</string>
    <key>CFBundleDisplayName</key>
    <string>VibeKey 状态栏</string>
    <key>CFBundleIdentifier</key>
    <string>com.proma.vibekey-menubar</string>
    <key>CFBundleExecutable</key>
    <string>VibeKeyStatusBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$STAGE/Contents/PkgInfo"

# 临时 ad-hoc 签名：避免 Gatekeeper 对未签名可执行文件的奇怪行为；失败不致命
codesign --force --sign - "$STAGE" >/dev/null 2>&1 || true

if [ -d "$APP" ]; then
  rm -rf "$APP"
fi
mkdir -p "$HERE/bin"
cp -R "$STAGE" "$APP"

echo "==> 已更新 bin/VibeKeyStatusBar.app（$(du -sh "$APP" | awk '{print $1}')）"
echo
echo "提示：替换后要让常驻进程用上新版本"
echo "  launchctl kickstart -k gui/\$(id -u)/com.proma.vibekey-menubar"
