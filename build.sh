#!/bin/bash
# 重新编译 vibekit-led（设备层 HID 工具）
#
# 源码来自开源项目 OpenVibeKey 的 VibeKit Swift 包（vendor/ 下），
# 另外加了本项目需要的自定义子命令：busy / pulse / pulse-loop / mode /
# dial / dialcfg / flash / dump88 / ledtypes / breathe。
# 这些命令的代码在源码的 Sources/VibeKitWrite/main.swift 里，用 PEP 标记 "本项目新增"。
#
# 为什么必须用 release + strip：
#   debug 产物会把构建机的绝对路径（/Users/<你>/...）写进调试信息。
#   这些路径随二进制一起进仓库，既暴露用户名和目录结构，也让体积翻倍。
#   release 构建 + strip -x 后路径清零，体积约减半，功能行为不变。
#
# 依赖：Xcode Command Line Tools（swift 命令）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v swift >/dev/null || { echo "❌ 没有 swift，先装 Xcode Command Line Tools：xcode-select --install"; exit 1; }

echo "==> 编译 release（首次约 1 分钟）"
swift build --package-path "$HERE/vendor" -c release --product VibeKitWrite 2>&1 | tail -3

BIN="$HERE/vendor/.build/release/VibeKitWrite"
[ -x "$BIN" ] || { echo "❌ 编译产物没找到：$BIN"; exit 1; }

# 先落到临时文件，strip 成功且功能可用才替换，避免编译失败时把现有二进制搞坏
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
cp "$BIN" "$TMP"
strip -x "$TMP"
chmod +x "$TMP"

echo "==> 校验"
if ! "$TMP" status >/dev/null 2>&1; then
    echo "❌ 剥离后无法运行，保留原 bin/vibekit-led 不动"
    exit 1
fi
LEAK=$(grep -c -a "$HOME" "$TMP" 2>/dev/null || true)
echo "    内嵌本机路径：${LEAK:-0} 处  体积：$(ls -lh "$TMP" | awk '{print $5}')"

cp "$TMP" "$HERE/bin/vibekit-led"
echo "==> 已更新 bin/vibekit-led"
echo
echo "提示：替换后重载服务使其生效"
echo "  launchctl kickstart -k gui/\$(id -u)/com.proma.vibekey-bridge"
"$HERE/bin/vibekit-led" status 2>&1 | head -3 || true
