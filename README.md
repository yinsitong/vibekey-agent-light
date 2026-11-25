![VibeKey 状态灯](docs/assets/banner.png)

# VibeKey 状态灯 · Agent Status Light for Ulanzi AU05

用 Ulanzi Vibe Key（AU05）麦克风的灯 + macOS 菜单栏，显示本地 AI Agent 正在干什么。

![License: MIT](https://img.shields.io/badge/License-MIT-black.svg)
![Platform: macOS](https://img.shields.io/badge/Platform-macOS-000000.svg)
![Python: 3.9+](https://img.shields.io/badge/Python-3.9%2B-3776AB.svg)
![Device: Ulanzi AU05](https://img.shields.io/badge/Device-Ulanzi%20AU05-4B5563.svg)

[English](./README.en.md) · 中文

---

## 它解决什么问题

Agent 在我们本机跑长任务时，大部分时间待在后台。要知道它是在思考、在等你确认，
还是已经报错停下，得反复切窗口看——这个动作一天要重复几十次。

桌面上本来就有一盏灯，让它说话就行：

- **改完文件抬头看一眼** 就知道该不该继续等
- **切出去干别的事**，灯一闪就是它在问你问题
- **不用装仪表盘、不用开第二个窗口**，全是余光可见

灯走设备层 HID 直控，不依赖 Ulanzi Studio 的状态同步
（Studio 目前对 AU05 不做状态映射，调研过程见 [`docs/设备笔记.md`](docs/设备笔记.md)）。

灯不在手边、或根本不想开灯的时候，同一个状态也显示在 **macOS 顶部菜单栏**：
一个彩色圆点 + 两个字，抬头就能读到。

## 五种状态（灯 + 菜单栏同源）

```text
Agent 状态            灯的表现                              菜单栏
──────────────────   ─────────────────────────────────    ──────────────────────────
思考中              全亮（亮度 20，最亮档）                ● 思考（蓝）
执行工具            全亮                                   ● 工作（橙）
弹问题等你确认      亮度 1 ↔ 20 交替：闪 6 下 → 常亮 2.5 秒  ● 确认（紫，同频闪 + 内发光）
工具报错 / 中断     快闪 → 常亮                             ● 报错（红，同频闪 + 内发光）
本轮结束            按键灯灭，只剩旋钮一圈微光              ● 收尾（青）
空闲                按键灯灭，只剩旋钮一圈微光              ● 空闲（灰）
```

- **全亮**代表"我在干活，别催"
- **闪烁**是全项目最重要的一个信号：它在等你做决定，而且只有你能解
- **微光**是安全状态，说明可以放心离开
- 菜单栏另外还有两个状态：`○ 暂停`（灯光联动被手动关掉）和 `○ 离线`（桥接进程没心跳，该重载了）

## 能力

**状态感知**

- 实时读取 Proma 的会话事件流（`~/.proma/sdk-config/sessions/*.jsonl`，主进程逐条写入）
- 区分「思考 / 调工具 / 等你确认 / 报错 / 空闲」五种内部状态
- 正确判定「本轮结束」：只有最后一条是不含 toolCall 的 assistant 消息、且静默 1.6 秒才算结束——
  长命令执行期间没有事件，不能按静默判空

**灯光控制**

- 设备层 HID 直控，不依赖 Ulanzi Studio、不占用旋钮与按键的正常功能
- 全亮 / 工作模式 / 逐档亮度 / 循环闪烁 / 呼吸 / 单灯控制
- 忙态每 45 秒补写一次，抵抗设备 5 分钟无操作自动待机

**菜单栏状态**

- 原生 `NSStatusItem`，单文件 Swift 编译成 `VibeKeyStatusBar.app`，零第三方依赖
- 彩色圆点 + 短标签（`● 思考` / `● 工作` / `● 确认`…）
- **与麦克风灯同频闪**：等确认 / 报错时，圆点带动一圈同色内发光（光晕），
  按灯的真实节奏「闪 6 下 → 常亮 2.5 秒」循环。桥接把脉冲起点 `pulseAt` 与节奏参数
  写进 `status.json`，菜单栏用 `(now - pulseAt)` 取模算出当前是第几个半拍，
  所以两边是同一拍子，不是各闪各的；拿不到 `pulseAt` 时用本地时钟兜底
- **整条下沿外发光**：状态项下沿往下漏一圈同色光晕（独立透明浮窗，不挡点击）。
  等你确认/报错时跟着节拍一起亮暗，思考/执行时给一层很淡的底光，
  空闲/收尾/暂停/离线不画——那些时候屏幕应该安静
- 点开有完整状态、最近更新时间、「暂停灯光联动」、「只显示圆点」、「下沿外发光」、「重载桥接」、「打开日志」
- 桥接每 5 秒写一次心跳，超过 20 秒没更新就显示 `○ 离线`，等于自带健康检查
- 鼠标悬停有 tooltip：完整状态 + 活跃会话数 + 更新时间

**工程细节**

- 两个 LaunchAgent 托管：`com.proma.vibekey-bridge`（灯光）+ `com.proma.vibekey-menubar`（状态栏），登录自启、崩溃拉起、可反复执行 `install.sh`
- 状态文件与日志落在 `~/Library/Logs/PromaVibeKey/`，`touch pause` 即可临时静音
- 可选把状态作为 hook 事件上报给 Ulanzi Studio（`--no-studio` 可关）
- 事件源格式是公开的 JSONL：接别的 Agent 只需写一个适配器

## 快速开始

**要求**：macOS 13+、Python 3、一台 Ulanzi Vibe Key（AU05）及接收器。

```bash
git clone https://github.com/yinsitong/vibekey-agent-light.git
cd vibekey-agent-light

./install.sh                 # 装两个 LaunchAgent：灯光 + 菜单栏状态
python3 bridge.py --status   # 看当前识别到的状态
```

菜单栏 App 缺失时 `install.sh` 会自动调 `./build-menubar.sh` 编译（需要 Xcode Command Line Tools）。
也可以手动先编译：`./build-menubar.sh`。

`install.sh` 会把当前目录的绝对路径写进 LaunchAgent。**移动过目录后重跑一次即可。**

卸载：

```bash
./uninstall.sh
```

验证灯是否正常，不依赖 Agent：

```bash
python3 bridge.py --send confirm   # 应该看到一阵抖动
python3 bridge.py --send idle      # 暗下去
```

只验证菜单栏（不动灯、不碰 Studio）：

```bash
python3 bridge.py --publish thinking   # 菜单栏应变成「● 思考」
```

## 状态映射可以改

`bridge.py` 顶部集中了所有可调参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `BUSY_STATES` | `{"thinking", "working", "error"}` | 哪些状态算「忙」 |
| `BRIGHT_LEVEL` | `20` | 全亮亮度，**上限是 20**（写 21 设备会当成灭） |
| `IDLE_MODE` | `2` | 空闲时的灯效模式，改 `0` 是全灭，对比最强 |
| `PULSE_MS` | `250` | 闪烁每档毫秒 |
| `PULSE_LOW` / `PULSE_HIGH` | `1` / `20` | 暗 / 亮两档 |
| `PULSE_BURST` | `6` | 每组闪几下 |
| `PULSE_GAP` | `2500` | 组间停顿毫秒 |
| `PULSE_STATES` | `{"confirm", "error"}` | 哪些状态闪；改成 `set()` 就只剩亮/暗 |

改完重载：

```bash
./install.sh
# 或
launchctl kickstart -k gui/$(id -u)/com.proma.vibekey-bridge
```

临时静音（不卸载）：

```bash
touch ~/Library/Logs/PromaVibeKey/pause    # 暂停
rm ~/Library/Logs/PromaVibeKey/pause       # 恢复
```

## 工作原理

```text
┌──────────────────────┐        ┌──────────────┐        ┌─────────────────┐
│ Proma 主进程          │        │  bridge.py   │        │  Ulanzi AU05    │
│ sessions/*.jsonl     │──tail──▶│ 状态机        │──HID──▶│ 旋钮环 + 三键灯  │
│ （逐条实时写入）       │        │ 防抖 + 补写   │        │                 │
└──────────────────────┘        └──────┬───────┘        └─────────────────┘
                                       │ status.json（每 5 秒心跳）
                                       ▼
                                ┌──────────────┐
                                │ 菜单栏 App    │──▶ 顶部状态栏「● 工作」
                                └──────────────┘
```

`bridge.py` 持续 tail 事件文件，把每条事件翻译成内部状态；
状态变化时调用 `bin/vibekit-led`（Swift 编译的 HID 工具）改灯。

## 手动控灯与排查

```bash
BIN="./bin/vibekit-led"

$BIN busy 20                 # 全亮 + 亮度 20
$BIN mode 2                  # 工作模式（暗）
$BIN pulse 6 250 1 20        # 闪 6 下
$BIN dump88                  # 读回全部灯效字节
$BIN status                  # 设备状态概览
```

全部子命令：`busy` `pulse` `pulse-loop` `mode` `dial` `dialcfg` `flash`
`dump88` `ledtypes` `breathe` `ledrestore` `status` `get` `dump` `probe` `sniff`。

日志：

```bash
python3 bridge.py --publish confirm   # 只写 status.json（不动灯），用来单独验证菜单栏同频闪烁
tail -20 ~/Library/Logs/PromaVibeKey/bridge.log
```

## status.json 字段

菜单栏与外部工具都读它（`~/Library/Logs/PromaVibeKey/status.json`）：

| 字段 | 说明 |
| --- | --- |
| `state` | `thinking` / `working` / `confirm` / `error` / `attention` / `idle` / `paused` |
| `paused` | 是否手动静音了灯光 |
| `detail` | 给人看的第二行说明（中文 + 会话数） |
| `at` | 写入毫秒时间戳，每 5 秒至少更新一次；超过 20 秒没更新即视为桥接已死 |
| `pid` | 桥接进程号 |
| `pulseAt` | 仅闪灯状态：灯开始脉冲的毫秒时间戳，菜单栏用它对齐节拍 |
| `pulseMs` / `pulseBurst` / `pulseGap` | 仅闪灯状态：每半拍毫秒数 / 每组闪几下 / 组间停顿毫秒 |

## 三个必须知道的坑

1. **亮度上限是 20。** 写 21 不报错、读回也是 21，但灯会当成「灭」。
2. **设备只在亮度值变化时才重新施加亮度。** 重复写同一个值物理无效，切模式也不管用。
   所以忙态走 `busy`（内部先写 19 再写 20），闪烁靠交替写两个值。
3. **设备 5 分钟无操作进待机。** 待机时写入照常返回成功但灯不动，
   桥在忙态每 45 秒补写一次兜底。

菜单栏侧另有三条（写代码时才需要看）：

- 状态栏文字别用 `attributedTitle` 上色：深色菜单栏上 `labelColor` 会被算成黑色，文字几乎不可见。
  拆成「`button.image` 放彩色圆点 + `button.title` 放文字」才对。
- `statusItem.menu` 不能常驻，否则菜单会飞到屏幕最右侧；改成点击时临时挂上再摘掉。
- 圆点别用换 `button.image` 的方式闪：每次赋值都会触发状态项整组重排，250ms 一次就到 7% CPU。
  改成往按钮的 layer 里塞一个 `CALayer`，闪的时候只改图层 `opacity`/`transform`，实测降到 0.7%。

## 目录

| 路径 | 说明 |
| --- | --- |
| `bridge.py` | 主程序：tail 事件流 → 状态机 → 调 `bin/vibekit-led`，并写 `status.json` |
| `bin/vibekit-led` | 设备层 HID 工具（预编译的 release 产物，已 strip；`./build.sh` 可重编） |
| `menubar/VibeKeyStatusBar.swift` | 菜单栏 App 源码（单文件，`NSStatusItem` + 0.5 秒轮询 `status.json`） |
| `bin/VibeKeyStatusBar.app` | 编译好的菜单栏 App（LSUIElement，不占 Dock） |
| `vendor/` | VibeKit Swift 源码（来自 OpenVibeKey，MIT，见 [`THIRD-PARTY.md`](THIRD-PARTY.md)） |
| `install.sh` / `uninstall.sh` | 注册 / 移除两个 LaunchAgent |
| `build.sh` | 重新编译 `bin/vibekit-led`（release + strip，避免把本机路径写进二进制） |
| `build-menubar.sh` | 重新编译菜单栏 App |
| `docs/设备笔记.md` | HID 协议、灯效字节、官方通道调研结论 |

## 已知限制

- 只支持 macOS 13+（HID 与 LaunchAgent 都是 macOS 机制）
- 菜单栏项跟随「当前活跃显示器」的菜单栏显示；菜单栏特别挤（比如竖屏 + 图标很多）时可能被系统收进 `«` 折叠区，⌘-拖拽挪位置或在菜单里勾「只显示圆点」腾空间
- 需要设备接收器插在 Mac 上、VibeKey 开机；设备待机时写入无效（此时菜单栏仍正常显示状态）
- 事件源目前是 Proma 的会话格式；接其他 Agent 需要写适配器
- `bin/vibekit-led` 是预编译的 arm64 产物。Intel Mac 请用 `./build.sh` 重编
- 重编请走 `./build.sh`，不要直接 `swift build`：它会用 release + strip，避免把构建机的绝对路径写进二进制（debug 产物会，且体积翻倍）
- 不影响 VibeKey 原功能（旋钮、按键、麦克风），但重启设备后需要桥重新施加一次亮度

## Credits

- 设备逆向与 HID 协议：[palaemonboy/OpenVibeKey](https://github.com/palaemonboy/OpenVibeKey)（MIT）
- 事件源格式：Proma Agent

## License

[MIT](LICENSE) © 2026 Stone Yin
