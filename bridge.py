#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Proma 状态 → Ulanzi Vibe Key (AU05) 灯光桥

作用
----
让麦克风的灯跟着 Proma Agent 的工作状态走：

    状态                      设备动作                     看到的效果
    ----------------------    --------------------------    ------------------------------
    思考 / 调工具             全亮模式 + 亮度 20            旋钮与三颗按键灯全亮
    弹问题等你确认             亮度 1↔20 交替抖动            闪 6 下 → 停 2.5 秒 → 循环
    工具报错 / 中断            同上，更短促                  快闪约 2 秒后恢复常亮
    本轮结束 / 空闲            工作模式                      按键灯灭，只剩旋钮一圈微光

原理
----
1. 事件源：Proma 主进程实时把会话事件写到
   ~/.proma/sdk-config/sessions/<ts>_<uuid>.jsonl
   （message.role = user / assistant / toolResult，带毫秒时间戳）。
   本脚本持续 tail 这些文件，翻译成内部状态。
2. 执行：调同目录 bin/vibekit-led（OpenVibeKey 逆向出的 HID 命令），
   用「整机灯效模式 + 整机亮度」驱动灯。
   关键：设备只在亮度值**变化**时才重新施加亮度，重复写同值物理无效。

另外，脚本仍会顺带把状态作为 Ulanzi Studio 的 hook 事件上报一份
（ustudio-cli --agent claude-code --event ...）。Studio 目前对 AU05 不做
状态映射，这部分只为将来 Studio 修好后能自动接上。

用法
----
  bridge.py                 常驻（由 LaunchAgent 启动）
  bridge.py --send <状态>    手动发一次：idle/thinking/working/error/attention/confirm
  bridge.py --demo          依次演示所有状态
  bridge.py --status        打印最近一次状态
  bridge.py --no-studio     只控灯，不上报 Studio（调试用）
"""

from __future__ import annotations

import argparse
import atexit
import json
import os
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
SESSION_DIR = os.path.join(HOME, ".proma", "sdk-config", "sessions")
LOG_DIR = os.environ.get("PROMAC_LOG_DIR") or os.path.join(HOME, "Library", "Logs", "PromaVibeKey")
LOG_FILE = os.path.join(LOG_DIR, "bridge.log")

# Ulanzi Studio 侧
USTUDIO_ROOT = os.path.join(HOME, "Library", "Application Support", "Ulanzi", "UlanziDeck", "ustudio-cli")
# 以哪个 agent 的身份上报。claude-code 是 Studio 里状态映射最全的一条通道。
def _resolve_led_tool() -> str:
    """找 vibekit-led：环境变量 > 项目 bin/ > 旧的运行期副本。"""
    env = os.environ.get("PROMAC_LED_TOOL")
    if env and os.access(env, os.X_OK):
        return env
    here = os.path.dirname(os.path.abspath(__file__))
    real = os.path.dirname(os.path.realpath(__file__))
    cands = [
        os.path.join(here, "bin", "vibekit-led"),      # 项目内
        os.path.join(real, "bin", "vibekit-led"),      # 经 symlink 启动时
        os.path.join(HOME, "Library", "Application Support", "PromaVibeKey", "vibekit-led"),
    ]
    for c in cands:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return cands[0]


# 设备层工具（OpenVibeKey 逆向出的 HID 通道）
LED_TOOL = _resolve_led_tool()
# 灯语义：Proma 忙时切到「全亮模式 + 亮度 20」（旋钮灯明显变亮），
# 空闲/本轮结束回「工作模式」（旋钮灯暗）。亮度上限是 20，写 21 设备会当成灭。
BUSY_STATES = {"thinking", "working", "error"}
BRIGHT_LEVEL = 20
BUSY_MODE = 1      # 全亮模式
IDLE_MODE = 2      # 工作模式
# 脉冲（呼吸/闪烁）参数：设备只在亮度值变化时重新施加亮度，交替写两个值就能抖出明暗
PULSE_MS = 250         # 每档停留毫秒（实测 250ms 比 600ms 更明显）
PULSE_LOW = 1
PULSE_HIGH = 20
PULSE_BURST = 6        # 每组闪几下
PULSE_GAP = 2500       # 组间停顿毫秒
# 需要「抖动提醒」的状态：等你确认、工具报错/中断
PULSE_STATES = {"confirm", "error"}
AGENT_ID = os.environ.get("PROMAC_AGENT", "claude-code")

# Proma 状态 -> (Studio event, 去重后允许重发的最小间隔秒)
STATE_EVENT = {
    "confirm": ("PermissionRequest", 2.0),
    "idle": ("SessionStart", 30.0),
    "thinking": ("UserPromptSubmit", 3.0),
    "working": ("PreToolUse", 8.0),
    "error": ("PostToolUseFailure", 3.0),
    "attention": ("Stop", 5.0),
}
PRIORITY = {"confirm": 6, "error": 5, "working": 4, "thinking": 3, "attention": 2, "idle": 1}

TICK = 0.25               # 轮询间隔
DONE_DEBOUNCE = 1.6       # 已经给出最终答复后，安静这么久就算本轮结束
LONG_SILENCE = 150.0      # 工具执行中长时间无事件（长命令）也不误判
ERROR_HOLD = 2.0          # 报错状态保持时间
SESSION_ALIVE = 120.0     # 文件多久内活跃过才算「这个会话在跑」
IDLE_DECAY = 900.0        # attention 挂多久后回到 idle
LOG_MAX = 1_000_000
PAUSE_FILE = os.path.join(LOG_DIR, "pause")


# ---------------------------------------------------------------- logging
def log(msg: str) -> None:
    line = "%s %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > LOG_MAX:
            shutil.move(LOG_FILE, LOG_FILE + ".1")
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass
    if os.environ.get("PROMAC_VERBOSE"):
        print(line, flush=True)


# ---------------------------------------------------------------- ulanzi cli
def resolve_cli() -> str | None:
    """取 ustudio-cli，优先按 manifest 的 latest，其次取最高版本目录。"""
    try:
        with open(os.path.join(USTUDIO_ROOT, "manifest.json"), encoding="utf-8") as fh:
            latest = json.load(fh).get("latest")
    except (OSError, ValueError):
        latest = None
    candidates = []
    if latest:
        candidates.append(os.path.join(USTUDIO_ROOT, "bin", latest, "ustudio-cli"))
    bin_root = os.path.join(USTUDIO_ROOT, "bin")
    try:
        for name in sorted(os.listdir(bin_root), reverse=True):
            candidates.append(os.path.join(bin_root, name, "ustudio-cli"))
    except OSError:
        pass
    for path in candidates:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


CLI = None
_busy = None
_last_assert = 0.0
_pulse_proc = None


def stop_pulse() -> bool:
    """停掉正在跑的脉冲子进程；返回是否真的停掉了东西。"""
    global _pulse_proc
    stopped = False
    if _pulse_proc is not None:
        try:
            _pulse_proc.terminate()
            _pulse_proc.wait(timeout=2)
        except (OSError, subprocess.TimeoutExpired):
            try:
                _pulse_proc.kill()
            except OSError:
                pass
        log("pulse stop")
        _pulse_proc = None
        stopped = True
    return stopped


def start_pulse() -> None:
    """后台起持续脉冲；状态一变就会被 stop_pulse 干掉。"""
    global _pulse_proc
    if _pulse_proc is not None and _pulse_proc.poll() is None:
        return
    if not (os.path.isfile(LED_TOOL) and os.access(LED_TOOL, os.X_OK)):
        return
    try:
        _pulse_proc = subprocess.Popen(
            [LED_TOOL, "pulse-loop", str(PULSE_MS), str(PULSE_LOW),
             str(PULSE_HIGH), str(PULSE_BURST), str(PULSE_GAP)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        log("pulse start pid=%s %sms %s<->%s" % (_pulse_proc.pid, PULSE_MS, PULSE_LOW, PULSE_HIGH))
    except OSError as exc:
        log("pulse.fail %s" % exc)


def set_busy(busy: bool, force: bool = False) -> None:
    """设备层直控：忙=全亮模式(亮)，闲=工作模式(暗)。"""
    global _busy, _last_assert
    now = time.time()
    # 脉冲会把亮度停在低档，所以刚停完必须重写一次，不能因为状态没变就跳过
    stopped = stop_pulse()
    if _busy is busy and not force and not stopped:
        return
    if not (os.path.isfile(LED_TOOL) and os.access(LED_TOOL, os.X_OK)):
        return
    # 忙态走 busy 子命令：设备只在亮度值变化时才重新施加亮度，
    # 里面会先写 level-1 再写 level，避免重复写同值物理无效。
    args = [LED_TOOL, "busy", str(BRIGHT_LEVEL)] if busy else [LED_TOOL, "mode", str(IDLE_MODE)]
    try:
        proc = subprocess.run(args, capture_output=True, text=True, timeout=8)
        tail = (proc.stdout or "").strip().splitlines()[-1:] or [""]
        log("light %-4s rc=%s %s" % ("busy" if busy else "idle",
                                    proc.returncode, tail[0][:80]))
        if proc.returncode == 0:
            _busy = busy
            _last_assert = now
    except (OSError, subprocess.TimeoutExpired) as exc:
        log("light.fail %s" % exc)


def send_state(state: str) -> bool:
    """把一个状态送进 Ulanzi Studio。返回是否成功。"""
    global CLI
    pair = STATE_EVENT.get(state)
    if not pair:
        log("send.skip unknown state=%s" % state)
        return False
    event = pair[0]
    if CLI is None:
        CLI = resolve_cli()
    if not CLI:
        log("send.fail ustudio-cli not found")
        return False
    try:
        proc = subprocess.run(
            [CLI, "--agent", AGENT_ID, "--event", event],
            input="{}",
            text=True,
            capture_output=True,
            timeout=8,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        log("send.fail state=%s event=%s err=%s" % (state, event, exc))
        return False
    ok = proc.returncode == 0
    detail = (proc.stderr or proc.stdout or "").strip().replace("\n", " ")[:120]
    log("send state=%-9s event=%-18s rc=%s %s" % (state, event, proc.returncode, detail))
    return ok


# ---------------------------------------------------------------- tailing
class Tail:
    """增量读取一个 jsonl 文件。"""

    def __init__(self, path: str) -> None:
        self.path = path
        self.offset = 0
        self.inode = None
        self.buffer = ""

    def reset(self) -> None:
        self.offset = 0
        self.buffer = ""
        try:
            st = os.stat(self.path)
            self.inode = st.st_ino
        except OSError:
            self.inode = None

    def read_new(self) -> list[dict]:
        try:
            st = os.stat(self.path)
        except OSError:
            return []
        if self.inode is None:
            self.inode = st.st_ino
        if st.st_ino != self.inode:      # 文件被替换
            self.reset()
        if st.st_size < self.offset:      # 被截断
            self.reset()
            self.inode = st.st_ino
        if st.st_size == self.offset:
            return []
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                fh.seek(self.offset)
                chunk = fh.read()
                self.offset = fh.tell()
        except OSError:
            return []
        self.buffer += chunk
        out = []
        while "\n" in self.buffer:
            raw, self.buffer = self.buffer.split("\n", 1)
            raw = raw.strip()
            if not raw:
                continue
            try:
                out.append(json.loads(raw))
            except ValueError:
                continue
        return out


class SessionState:
    def __init__(self, path: str) -> None:
        self.tail = Tail(path)
        self.tail.reset()
        self.state = "idle"
        self.active = False
        self.pending_done = False
        self.last_event = time.time()
        self.last_signature = None
        self.error_until = 0.0

    def feed(self, record: dict) -> str | None:
        rtype = record.get("type")
        msg = record.get("message") or {}
        role = msg.get("role")

        if rtype == "session":
            self.active = True
            self.last_event = time.time()
            return "thinking"

        if rtype != "message":
            return None

        if role == "user":
            self.active = True
            self.pending_done = False
            self.last_event = time.time()
            return "thinking"        # 你回答了就回到思考，主循环会停脉冲

        if role == "assistant":
            self.last_event = time.time()
            blocks = msg.get("content") or []
            tool_names = [(b.get("toolName") or b.get("name") or "")
                          for b in blocks
                          if isinstance(b, dict) and b.get("type") in ("toolCall", "tool_call")]
            has_tool = bool(tool_names or any(
                isinstance(b, dict) and b.get("type") in ("toolCall", "tool_call") for b in blocks))
            self.pending_done = not has_tool
            if tool_names and any("askuserquestion" in n.lower() for n in tool_names):
                return "confirm"      # 正在弹问题等你选 -> 抖动提醒
            if has_tool:
                return "working"
            return None  # 纯文本/思考块：可能要收尾了，由超时判定

        if role == "toolResult":
            self.pending_done = False
            self.last_event = time.time()
            if msg.get("isError"):
                self.error_until = time.time() + ERROR_HOLD
                return "error"
            return "working"

        return None


# ---------------------------------------------------------------- bridge
def list_session_files() -> list[str]:
    try:
        names = os.listdir(SESSION_DIR)
    except OSError:
        return []
    return [os.path.join(SESSION_DIR, n) for n in names if n.endswith(".jsonl")]


def write_status(state: str, detail: str) -> None:
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(os.path.join(LOG_DIR, "status.json"), "w", encoding="utf-8") as fh:
            json.dump({"state": state, "detail": detail, "at": int(time.time() * 1000)}, fh, ensure_ascii=False)
    except OSError:
        pass


def cleanup_orphan_pulses() -> None:
    """桥被强杀时脉冲子进程会变孤儿，启动时先清一遍。"""
    try:
        subprocess.run(["pkill", "-f", "vibekit-led pulse-loop"],
                       capture_output=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        pass


def run_loop() -> None:
    global CLI
    cleanup_orphan_pulses()
    atexit.register(stop_pulse)
    CLI = resolve_cli()
    log("bridge.start cli=%s agent=%s dir=%s" % (CLI, AGENT_ID, SESSION_DIR))

    sessions: dict[str, SessionState] = {}
    last_sent = {k: 0.0 for k in STATE_EVENT}
    current = None
    attention_since = 0.0

    while True:
        now = time.time()
        try:
            files = list_session_files()
        except Exception as exc:                     # noqa: BLE001
            log("loop.error %s" % exc)
            files = []

        # 只跟踪近期活跃过的会话文件，避免历史文件堆积
        for path in files:
            st = sessions.get(path)
            if st is None:
                try:
                    if now - os.path.getmtime(path) > SESSION_ALIVE:
                        continue
                except OSError:
                    continue
                st = SessionState(path)
                sessions[path] = st
            for record in st.tail.read_new():
                new_state = st.feed(record)
                if new_state and PRIORITY[new_state] >= PRIORITY.get(st.state, 1):
                    st.state = new_state
                elif new_state:
                    st.state = new_state

        # 会话收尾：一段时间没有新事件，且不是在做工具
        for st in sessions.values():
            if not st.active:
                continue
            idle_for = now - st.last_event
            if (st.pending_done and idle_for > DONE_DEBOUNCE) or idle_for > LONG_SILENCE:
                st.active = False
                st.pending_done = False
                st.state = "attention"

        # 聚合：优先级最高的赢；同优先级取最近活跃的
        live = [s for s in sessions.values() if now - s.last_event <= SESSION_ALIVE]
        if live:
            live.sort(key=lambda s: (PRIORITY.get(s.state, 0), s.last_event), reverse=True)
            target = live[0].state
        else:
            target = "idle"

        # 报错状态到点后回落到 working
        if target == "error" and now > max(s.error_until for s in live or [SessionState("/dev/null")]):
            target = "working"

        paused = os.path.exists(PAUSE_FILE)
        if not paused:
            if target in PULSE_STATES:
                start_pulse()                      # 等你确认 / 报错 -> 抖动
            else:
                busy = target in BUSY_STATES
                # 每 45 秒补写一次（带亮度脉冲），兜住设备待机导致的漏亮
                stale = (busy and now - _last_assert > 45.0)
                set_busy(busy, force=stale)

        if paused:
            current = None
        elif target != current:
            event, _ = STATE_EVENT[target]
            if now - last_sent[target] >= STATE_EVENT[target][1]:
                ok = send_state(target)
                if ok:
                    last_sent[target] = now
                    current = target
                    if target == "attention":
                        attention_since = now
                    write_status(target, "-> %s" % event)
                else:
                    # 送不进去（例如 Studio 没开）就退回去，下一轮重试
                    current = None
            else:
                current = None
        elif target == "attention" and attention_since and now - attention_since > IDLE_DECAY:
            target = "idle"
            current = None

        # 清理长时间不活跃的跟踪项
        if len(sessions) > 40:
            for path in [p for p, s in sessions.items() if now - s.last_event > 3 * SESSION_ALIVE]:
                sessions.pop(path, None)

        time.sleep(TICK)


def main() -> int:
    ap = argparse.ArgumentParser(description="Proma -> Ulanzi Vibe Key 灯光桥")
    ap.add_argument("--send", metavar="STATE", help="发送单个状态后退出：idle/thinking/working/error/attention")
    ap.add_argument("--demo", action="store_true", help="依次演示全部状态")
    ap.add_argument("--status", action="store_true", help="打印最近的桥接状态")
    args = ap.parse_args()

    if args.send:
        if args.send not in STATE_EVENT:
            print("未知状态 %s，可用：%s" % (args.send, "/".join(STATE_EVENT)))
            return 2
        return 0 if send_state(args.send) else 1

    if args.demo:
        for state in ("thinking", "working", "error", "attention", "idle"):
            print("->", state, flush=True)
            send_state(state)
            time.sleep(2.0)
        return 0

    if args.status:
        path = os.path.join(LOG_DIR, "status.json")
        try:
            with open(path, encoding="utf-8") as fh:
                print(fh.read())
        except OSError:
            print("还没有状态记录")
        return 0

    try:
        run_loop()
    except KeyboardInterrupt:
        log("bridge.stop keyboard")
    return 0


if __name__ == "__main__":
    sys.exit(main())
