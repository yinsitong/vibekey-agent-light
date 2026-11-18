# 第三方组件与来源

## VibeKit（`vendor/`）

- **来源**：[palaemonboy/OpenVibeKey](https://github.com/palaemonboy/OpenVibeKey)
- **许可**：MIT © 2026 palaemonboy（原文见 [`vendor/LICENSE`](./vendor/LICENSE)）
- **用途**：从设备层（HID）控制 Ulanzi AU05 的灯光，不依赖 Ulanzi Studio 的状态同步

本项目在 OpenVibeKey 的 VibeKit 源码基础上增加了面向状态灯的自定义子命令
（`busy` / `pulse` / `pulse-loop` / `mode` / `dial` / `dialcfg` / `flash` /
`dump88` / `ledtypes` / `breathe`），代码位于
`vendor/Sources/VibeKitWrite/main.swift`，以「本项目新增」标记。

`bin/vibekit-led` 是该 Swift 包 `VibeKitWrite` 产品的编译产物，可用 `./build.sh` 重编。

按 MIT 条款，`vendor/` 目录保留上游版权声明与许可证原文。

## Ulanzi Studio（可选）

`bridge.py` 默认会把状态作为 hook 事件额外上报一份给 Ulanzi Studio 的 CLI
（`ustudio-cli --agent claude-code --event ...`）。这一路是**可选**的：
Studio 目前不对 AU05 做状态映射，上报只是为了让它在将来支持时能自动接上。
用 `--no-studio` 或删掉相关调用不影响灯光控制。

Ulanzi Studio 是 Ulanzi 的商业软件，本仓库不包含其任何文件。
