#!/bin/bash
# 重新编译 vibekit-led（设备层 HID 工具）
#
# 源码来自开源项目 OpenVibeKey 的 VibeKit Swift 包（vendor/ 下），
# 另外加了本项目需要的自定义子命令：busy / pulse / pulse-loop / mode /
# dial / dialcfg / flash / dump88 / ledtypes / breathe。
# 这些命令的代码在源码的 Sources/VibeKitWrite/main.swift 里，用 PEP 标记 "本项目新增"。
#
# 依赖：Xcode Command Line Tools（swift 命令）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v swift >/dev/null || { echo "❌ 没有 swift，先装 Xcode Command Line Tools：xcode-select --install"; exit 1; }

echo "==> 编译（首次约 1 分钟）"
swift build --package-path "$HERE/vendor" --product VibeKitWrite 2>&1 | tail -5

BIN="$HERE/vendor/.build/debug/VibeKitWrite"
[ -x "$BIN" ] || { echo "❌ 编译产物没找到：$BIN"; exit 1; }

cp "$BIN" "$HERE/bin/vibekit-led"
chmod +x "$HERE/bin/vibekit-led"
echo "==> 已更新 bin/vibekit-led"
"$HERE/bin/vibekit-led" status 2>&1 | head -3 || true
