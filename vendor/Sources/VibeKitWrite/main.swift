import Foundation
import IOKit
import IOKit.hid
import VibeKitCore
import VibeKitHID
import VibeKitAudio

if CommandLine.arguments.contains("counts") {
    let c = VibeKitHID.reportCounts()
    func s(_ v: Int?) -> String { v.map(String.init) ?? "（探针不可用）" }
    print("键盘/消费/鼠标口 累计输入报告 = \(s(c.keyboard))   ← 按键都走这里")
    print("厂商口 0x55      累计输入报告 = \(s(c.vendor))   ← 每 2~3 秒电池广播会让它稳定上涨")
    exit(0)
}

let hid = VibeKitHID()
do { try hid.open() } catch { print("❌ 打开设备失败：\(error)"); exit(1) }
let dev = VibeKitDevice(hid)
print("✅ 已连接\n")

if let p = CommandLine.arguments.firstIndex(of: "breathe"), p + 1 < CommandLine.arguments.count {
    let v = (Int(CommandLine.arguments[p + 1]) ?? 0) != 0
    func raw(_ d: [UInt8]?) -> String { d.map { $0.prefix(10).map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "nil" }
    print("写入前 全局呼吸=\(dev.getIndicatorBreathe().map(String.init) ?? "无响应")  灯效=\(raw(dev.getIndicatorRaw()))")
    try? dev.setIndicatorBreathe(v)
    Thread.sleep(forTimeInterval: 0.5)
    print("写入后 全局呼吸=\(dev.getIndicatorBreathe().map(String.init) ?? "无响应")  灯效=\(raw(dev.getIndicatorRaw()))")
    hid.close(); exit(0)
}

if let p = CommandLine.arguments.firstIndex(of: "ledtypes"), p + 1 < CommandLine.arguments.count {
    let parts = CommandLine.arguments[p + 1].split(separator: ",").compactMap { Int($0) }
    guard parts.count == 4 else { print("用法: ledtypes t1,t2,t3,dial"); hid.close(); exit(1) }
    try? dev.setLedTypes(parts, focus: 3)
    Thread.sleep(forTimeInterval: 0.4)
    print("写入 types=\(parts) → 读回 types=\(dev.getLedTypes().map(String.init(describing:)) ?? "无响应")")
    hid.close(); exit(0)
}

if let p = CommandLine.arguments.firstIndex(of: "dial"), p + 1 < CommandLine.arguments.count {
    let t = Int(CommandLine.arguments[p + 1]) ?? 1
    var types = dev.getLedTypes() ?? [2, 0, 0, 1]
    types[3] = t
    try? dev.setLedTypes(types, focus: 3)
    Thread.sleep(forTimeInterval: 0.35)
    print("dial → \(t)  读回 types=\(dev.getLedTypes().map(String.init(describing:)) ?? "无响应")")
    hid.close(); exit(0)
}

if let p = CommandLine.arguments.firstIndex(of: "dialcfg"), p + 1 < CommandLine.arguments.count {
    let t = Int(CommandLine.arguments[p + 1]) ?? 1
    let ao = (p + 2 < CommandLine.arguments.count ? Int(CommandLine.arguments[p + 2]) : nil) ?? 21
    let bb = (p + 3 < CommandLine.arguments.count ? Int(CommandLine.arguments[p + 3]) : nil) ?? ao
    guard let cur = dev.getIndicatorRaw(), cur.count >= 24 else {
        print("❌ 读不到灯效配置"); hid.close(); exit(1)
    }
    func hx(_ d: [UInt8]) -> String { d.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ") }
    var payload = Array(cur.prefix(24))
    let base = 4 + 5 * 3          // 旋钮 = index 3
    payload[base]     = UInt8(max(0, min(255, t)))
    payload[base + 3] = UInt8(max(0, min(255, bb)))
    payload[base + 4] = UInt8(max(0, min(255, ao)))
    payload[1] = 3                // focus = 旋钮
    payload[2] = 0
    payload[3] = 0
    print("写入前 = \(hx(cur))")
    try? hid.send(VibeKitFrame.sentFrame(b0: 0x01, b1: 0x0b, b2: 0x88, b3: 0x04, payload: payload))
    Thread.sleep(forTimeInterval: 0.5)
    if let after = dev.getIndicatorRaw() {
        print("写入后 = \(hx(after))")
        print("旋钮块(type,workTime,breatheLevel,breatheBright,alwaysOnBright) = \((0..<5).map { Int(after[base + $0]) })")
    }
    hid.close(); exit(0)
}

if let p = CommandLine.arguments.firstIndex(of: "mode"), p + 1 < CommandLine.arguments.count {
    let m = Int(CommandLine.arguments[p + 1]) ?? 2
    let br = (p + 2 < CommandLine.arguments.count ? Int(CommandLine.arguments[p + 2]) : nil)
    try? dev.setLedMode(m); Thread.sleep(forTimeInterval: 0.3)
    if let br = br { try? dev.setLedBrightness(br); Thread.sleep(forTimeInterval: 0.4) }
    let raw = dev.getIndicatorRaw()
    print("mode=\(m) 亮度档=\(br.map(String.init) ?? "-")  读回 mode=\(raw.map { String($0[2]) } ?? "?") 全亮亮度=\(raw.map { String($0[3]) } ?? "?")")
    hid.close(); exit(0)
}

if let p = CommandLine.arguments.firstIndex(of: "flash"), p + 1 < CommandLine.arguments.count {
    let n = Int(CommandLine.arguments[p + 1]) ?? 5
    let ms = (p + 2 < CommandLine.arguments.count ? Int(CommandLine.arguments[p + 2]) : nil) ?? 400
    guard let cur = dev.getIndicatorRaw(), cur.count >= 24 else { print("❌ 读不到灯效"); hid.close(); exit(1) }
    let base = 4 + 5 * 3
    func put(_ t: UInt8) {
        var pl = Array(cur.prefix(24))
        pl[base] = t
        pl[1] = 3; pl[2] = 0; pl[3] = 0
        try? hid.send(VibeKitFrame.sentFrame(b0: 0x01, b1: 0x0b, b2: 0x88, b3: 0x04, payload: pl))
    }
    for i in 0..<n {
        put(1); Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
        put(0); Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
        if i == 0 { print("闪了 1 次（\(ms)ms 间隔），共 \(n) 次") }
    }
    put(1)
    print("结束，停在常亮。读回 types=\(dev.getLedTypes().map(String.init(describing:)) ?? "?")")
    hid.close(); exit(0)
}

if CommandLine.arguments.contains("dump88") {
    guard let d = dev.getIndicatorRaw() else { print("（无响应）"); hid.close(); exit(1) }
    var line = ""
    for (i, b) in d.enumerated() {
        line += String(format: "%02d:%02x ", i, b)
        if (i + 1) % 8 == 0 { print(line); line = "" }
    }
    if !line.isEmpty { print(line) }
    print("types[btn1,btn2,btn3,dial]=\((0..<4).map { Int(d[4 + 5 * $0]) })  mode=\(d[2])  allOnBright=\(d[3])")
    hid.close(); exit(0)
}

// 忙态点灯：设备只在亮度值「变化」时才重新施加亮度，
// 所以必须先写 level-1 再写 level，否则重复写同值不生效。
if let p = CommandLine.arguments.firstIndex(of: "busy"), p + 1 < CommandLine.arguments.count {
    let lvl = max(1, min(20, Int(CommandLine.arguments[p + 1]) ?? 20))
    try? dev.setLedMode(1); Thread.sleep(forTimeInterval: 0.20)
    try? dev.setLedBrightness(lvl - 1); Thread.sleep(forTimeInterval: 0.25)
    try? dev.setLedBrightness(lvl); Thread.sleep(forTimeInterval: 0.30)
    if let d = dev.getIndicatorRaw(), d.count >= 24 {
        print("busy mode=\(d[2]) allOnBright=\(d[3]) types=\((0..<4).map { Int(d[4 + 5 * $0]) })")
    } else { print("busy 读回无响应") }
    hid.close(); exit(0)
}

// 脉冲：全亮模式下按「亮度值变化」抖出一段呼吸/闪烁。
// 参数：pulse <次数> <间隔ms> <低亮度> <高亮度>
// 设备只在亮度值变化时重新施加亮度，所以交替写两个不同值才能产生可见的明暗变化。
if let p = CommandLine.arguments.firstIndex(of: "pulse"), p + 4 < CommandLine.arguments.count {
    let n = max(1, Int(CommandLine.arguments[p + 1]) ?? 4)
    let ms = max(60, Int(CommandLine.arguments[p + 2]) ?? 350)
    let lo = max(1, min(20, Int(CommandLine.arguments[p + 3]) ?? 3))
    let hi = max(lo + 1, min(20, Int(CommandLine.arguments[p + 4]) ?? 20))
    try? dev.setLedMode(1); Thread.sleep(forTimeInterval: 0.15)
    for i in 0..<n {
        try? dev.setLedBrightness(hi); Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
        try? dev.setLedBrightness(lo); Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
        if i == 0 { print("脉冲 \(n) 次，间隔 \(ms)ms，亮度 \(lo)<->\(hi)") }
    }
    try? dev.setLedBrightness(hi); Thread.sleep(forTimeInterval: 0.2)
    if let d = dev.getIndicatorRaw(), d.count >= 24 {
        print("结束 mode=\(d[2]) allOnBright=\(d[3])")
    }
    hid.close(); exit(0)
}

// 持续脉冲：供桥接器当子进程用，状态变化时由外部 kill 掉。
// 用法：pulse-loop <间隔ms> <低亮度> <高亮度> [每组次数] [组间停顿ms]
// 一组闪几下 -> 停一会儿 -> 再闪，避免一直抖动得太烦。
if let p = CommandLine.arguments.firstIndex(of: "pulse-loop"), p + 3 < CommandLine.arguments.count {
    let ms = max(60, Int(CommandLine.arguments[p + 1]) ?? 250)
    let lo = max(1, min(20, Int(CommandLine.arguments[p + 2]) ?? 1))
    let hi = max(lo + 1, min(20, Int(CommandLine.arguments[p + 3]) ?? 20))
    let burst = max(1, Int(CommandLine.arguments.count > p + 4 ? CommandLine.arguments[p + 4] : "6") ?? 6)
    let gap = max(0, Int(CommandLine.arguments.count > p + 5 ? CommandLine.arguments[p + 5] : "3000") ?? 3000)
    try? dev.setLedMode(1); Thread.sleep(forTimeInterval: 0.15)
    print("pulse-loop 间隔\(ms)ms 亮度\(lo)<->\(hi) 每组\(burst)次 组间\(gap)ms")
    fflush(stdout)
    while true {
        for _ in 0..<burst {
            try? dev.setLedBrightness(hi); Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
            try? dev.setLedBrightness(lo); Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
        }
        try? dev.setLedBrightness(hi)
        Thread.sleep(forTimeInterval: Double(gap) / 1000.0)
    }
}

if CommandLine.arguments.contains("dump") {
    func b(_ v: UInt8?) -> String { v.map { "\($0)" } ?? "（无响应）" }
    print("== 全局模式（按键失效的头号嫌疑）==")
    let hooks = hid.request(b1: 0x0b, b2: 0x89)?.first
    let audioBtn = hid.request(b1: 0x06, b2: 0x51)?.first
    print("  HooksMode            = \(b(hooks))   ← 非 0 表示按键被钩给上位机，固件不再自己发键")
    print("  AudioButtonSystemMode= \(b(audioBtn))   ← 同上")
    if let w = hid.request(b1: 0x01, b2: 0x34) {
        print("  WheelEnableStatus    = [\(w.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))]")
    } else { print("  WheelEnableStatus    = （无响应）") }
    print("\n== 各 index 的两套存储（0x50 快捷键 / 0x10 固定功能）==")
    print("  0x10 打印原始 data 字节（响应布局未实测，不做解释）。")
    for i in UInt8(0)...9 {
        let sc = dev.getShortcut(index: i)
        let scDisp = sc.map { $0.isEmpty ? "（空槽）" : VibeKitKeymap.tokensToDisplay($0) } ?? "（无响应）"
        let raw50 = hid.request(b1: 0x06, b2: 0x50, dir: 0x01, payload: [i])
        let raw10 = hid.request(b1: 0x06, b2: 0x10, dir: 0x01, payload: [0x00, i])
        func hx(_ d: [UInt8]?) -> String {
            d.map { $0.prefix(10).map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "（无响应）"
        }
        print("  index \(i):  快捷键=\(scDisp.padding(toLength: 16, withPad: " ", startingAt: 0))")
        print("            0x50 raw = \(hx(raw50))")
        print("            0x10 raw = \(hx(raw10))")
    }
    print("\n若 HooksMode / AudioButtonSystemMode 非 0 → 跑 swift run VibeKitWrite resetmodes 复位。")
    hid.close(); exit(0)
}

if CommandLine.arguments.contains("probe") {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey as String: 0xfff1] as CFDictionary)
    let openRet = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    let devs = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
    print("== VID 0xfff1 下的 HID 接口：\(devs.count) 个 (ManagerOpen=0x\(String(format: "%x", openRet))) ==")
    for d in devs {
        func ii(_ k: String) -> Int { (IOHIDDeviceGetProperty(d, k as CFString) as? Int) ?? -1 }
        func ss(_ k: String) -> String { (IOHIDDeviceGetProperty(d, k as CFString) as? String) ?? "—" }
        let up = ii(kIOHIDPrimaryUsagePageKey), us = ii(kIOHIDPrimaryUsageKey)
        let kind: String
        switch (up, us) {
        case (0x01, 0x06): kind = "键盘 ← 普通快捷键从这里发"
        case (0x0c, 0x01): kind = "consumer ← 媒体键从这里发"
        case (0x01, 0x02): kind = "鼠标"
        case (0xfffc, _):  kind = "厂商口(配置通道)"
        default:           kind = ""
        }
        print(String(format: "  usagePage=0x%04x usage=0x%02x  pid=0x%04x  %@  %@",
                     up, us, ii(kIOHIDProductIDKey), ss(kIOHIDProductKey), kind))
    }
    hid.close(); exit(0)
}

if CommandLine.arguments.contains("sniff") {
    let selftest = CommandLine.arguments.contains("selftest")
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    var match: [String: Any] = [kIOHIDPrimaryUsagePageKey as String: 0x0c]
    if !selftest { match[kIOHIDVendorIDKey as String] = 0xfff1 }
    IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
    let ret = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    guard ret == kIOReturnSuccess else {
        print("❌ 打开 consumer 口失败 ret=0x\(String(format: "%x", ret))（若为 e00002c1/notPermitted，需在 系统设置→隐私与安全性→输入监控 里放行终端）")
        hid.close(); exit(1)
    }
    let devs = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
    print("== 匹配到 \(devs.count) 个 consumer 接口 ==")
    for d in devs {
        let vid = (IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int) ?? -1
        let name = (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? "—"
        print(String(format: "   vid=0x%04x  %@", vid, name))
    }
    var count = 0
    IOHIDManagerRegisterInputValueCallback(mgr, { _, _, _, value in
        let el = IOHIDValueGetElement(value)
        let dev = IOHIDElementGetDevice(el)
        let vid = (IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int) ?? -1
        let up = IOHIDElementGetUsagePage(el), us = IOHIDElementGetUsage(el)
        let v = IOHIDValueGetIntegerValue(value)
        if v != 0 { print(String(format: "  ▶ vid=0x%04x usagePage=0x%02x usage=0x%02x value=%ld", vid, up, us, v)) }
    }, &count)
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    if selftest {
        print("\n== 自检：监听全系统 consumer 事件 20 秒 ==")
        print("   请按几下【Mac 自带键盘】的音量加/减键。")
        print("   有 ▶ 输出 = 工具正常，之前 VibeKey 的零报告才算数；")
        print("   没有输出 = 工具本身收不到事件，之前的零报告全部作废。")
    } else {
        print("\n== 正在监听 VibeKey consumer 口 20 秒 ==")
        print("   请依次：按 btn1 / btn2 / btn3、左转旋钮、右转旋钮、按下旋钮")
    }
    RunLoop.current.run(until: Date().addingTimeInterval(20))
    print("== 监听结束 ==")
    hid.close(); exit(0)
}

// 最小灯效验证：保留其他三灯的完整配置，只把 btn1 设为持续呼吸。
// 用法：btn1breathe <首次备份.json>；恢复：ledrestore <首次备份.json>。
if let p = CommandLine.arguments.firstIndex(of: "btn1breathe"), p + 1 < CommandLine.arguments.count {
    let backupPath = CommandLine.arguments[p + 1]
    func hx(_ d: [UInt8]) -> String { d.map { String(format: "%02x", $0) }.joined(separator: " ") }
    guard !FileManager.default.fileExists(atPath: backupPath) else {
        print("❌ 备份文件已存在，拒绝覆盖：\(backupPath)"); hid.close(); exit(1)
    }
    guard let original = dev.getIndicatorRaw(), original.count >= 24 else {
        print("❌ 读不到完整灯效配置，未写入。请按 AU05 任意实体键唤醒后再试。"); hid.close(); exit(1)
    }
    guard original[2] == 2 else {
        print("❌ 当前不是工作模式（读回 mode=\(original[2])），未写入。"); hid.close(); exit(1)
    }
    var slots: [[String: Any]] = []
    for i in UInt8(0)...5 {
        let shortcut = dev.getShortcut(index: i)
        let fixedFunction = dev.getButtonFixedFunction(index: i)
        slots.append([
            "index": Int(i),
            "shortcut": shortcut == nil ? NSNull() : shortcut!,
            "fixedFunction": fixedFunction == nil ? NSNull() : Int(fixedFunction!),
        ])
    }
    let backup: [String: Any] = [
        "createdAt": ISO8601DateFormatter().string(from: Date()),
        "indicatorRaw": original.map(Int.init),
        "ledTypes": (0..<4).map { Int(original[4 + 5 * $0]) },
        "indicatorBreathe": dev.getIndicatorBreathe() ?? NSNull(),
        "micUiFlick": dev.getMicUiFlick() ?? NSNull(),
        "slots": slots,
    ]
    do {
        let data = try JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: backupPath), options: .atomic)
    } catch {
        print("❌ 备份失败，未写入：\(error)"); hid.close(); exit(1)
    }
    print("== 写入前原始配置 ==")
    print("  备份：\(backupPath)")
    print("  mode=\(original[2])（工作）  types[btn1,btn2,btn3,dial]=\((0..<4).map { Int(original[4 + 5 * $0]) })")
    print("  raw[\(original.count)] = \(hx(original))")

    var test = original
    test[4] = 2                                  // 仅 btn1 type=呼吸
    test[5] = 0x0a                               // btn1 workTime
    test[6] = 0x02                               // btn1 breatheLevel
    test[7] = 0x02                               // btn1 breatheBright
    test[8] = 0x02                               // btn1 alwaysOnBright
    var payload = Array(test.prefix(24))          // 其他三灯的 5 字节块原样携带
    payload[0] = 0x7c                            // type|workTime|breatheLevel|breatheBright|alwaysOn
    payload[1] = 0x00                            // focus=btn1
    payload[2] = 0x00
    payload[3] = 0x00
    do {
        try hid.send(VibeKitFrame.sentFrame(b0: 0x01, b1: 0x0b, b2: 0x88, b3: 0x04, payload: payload))
    } catch {
        print("❌ HID 写入失败：\(error)。原始备份已保留，未重发。"); hid.close(); exit(1)
    }
    Thread.sleep(forTimeInterval: 0.4)
    guard let after = dev.getIndicatorRaw(), after.count >= 24 else {
        print("⚠️ 已发送，但读回失败；请观察实体灯，恢复时使用上面的备份。"); hid.close(); exit(2)
    }
    let otherBlocksUnchanged = Array(after[9..<24]) == Array(original[9..<24])
    print("== 写入后读回（不代表肉眼已确认）==")
    print("  types[btn1,btn2,btn3,dial]=\((0..<4).map { Int(after[4 + 5 * $0]) })")
    print("  btn1 参数 = \(hx(Array(after[4..<9])))")
    print("  其他三灯配置块保持不变 = \(otherBlocksUnchanged ? "是" : "否")")
    print("  raw[\(after.count)] = \(hx(after))")
    print("➡️ 请只观察三颗按键下的灯：按钮 1 是否持续呼吸？旋钮黄灯不参与本项判断。")
    hid.close(); exit(otherBlocksUnchanged && after[4] == 2 ? 0 : 2)
}

// 只开启全局呼吸门控，不改四灯 type/参数；用于验证 type=2 但全局呼吸关闭时熄灭的情况。
if let p = CommandLine.arguments.firstIndex(of: "btn1globalbreathe"), p + 1 < CommandLine.arguments.count {
    let backupPath = CommandLine.arguments[p + 1]
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: backupPath))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let values = obj?["indicatorRaw"] as? [Int], values.count >= 24,
              let originalBreathe = obj?["indicatorBreathe"] as? Bool else {
            print("❌ 备份缺少灯效或全局呼吸原值，未写入。"); hid.close(); exit(1)
        }
        let original = values.map { UInt8(clamping: $0) }
        guard let before = dev.getIndicatorRaw(), before.count >= 24,
              Array(before.prefix(24)) == Array(original.prefix(24)),
              dev.getLedTypes() == [2, 0, 0, 1] else {
            print("❌ 当前灯效不在已备份的原始状态，未写入。"); hid.close(); exit(1)
        }
        print("写入前：全局呼吸=\(dev.getIndicatorBreathe().map(String.init) ?? "无响应")  types=[2,0,0,1]")
        try dev.setIndicatorBreathe(true)
        Thread.sleep(forTimeInterval: 0.4)
        guard let after = dev.getIndicatorRaw(), after.count >= 24 else {
            print("⚠️ 全局呼吸开启命令已发送，但读回失败。"); hid.close(); exit(2)
        }
        let rawUnchanged = Array(after.prefix(24)) == Array(original.prefix(24))
        print("写入后：全局呼吸=\(dev.getIndicatorBreathe().map(String.init) ?? "无响应")  四灯配置未变=\(rawUnchanged)")
        print("原始全局呼吸值=\(originalBreathe)，恢复时写回。请观察按钮 1 是否持续呼吸，以及其他灯是否变化。")
        hid.close(); exit(rawUnchanged ? 0 : 2)
    } catch {
        print("❌ 开启全局呼吸失败：\(error)"); hid.close(); exit(1)
    }
}

// 只切换 btn1 的麦克风 UI 闪烁通道，不改工作模式四灯配置。
if let p = CommandLine.arguments.firstIndex(of: "btn1micflick"), p + 1 < CommandLine.arguments.count {
    let backupPath = CommandLine.arguments[p + 1]
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: backupPath))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let originalFlick = obj?["micUiFlick"] as? Bool else {
            print("❌ 备份缺少 micUiFlick 原值，未写入。"); hid.close(); exit(1)
        }
        print("写入前：micUiFlick=\(dev.getMicUiFlick().map(String.init) ?? "无响应")")
        try dev.setMicUiFlick(true)
        Thread.sleep(forTimeInterval: 0.4)
        let after = dev.getMicUiFlick()
        print("写入后：micUiFlick=\(after.map(String.init) ?? "无响应")  原始值=\(originalFlick)")
        print("请观察按钮 1 是否独立闪烁，以及 btn2/btn3/旋钮是否保持原样。")
        hid.close(); exit(after == true ? 0 : 2)
    } catch {
        print("❌ 开启 btn1 麦克风 UI 闪烁失败：\(error)"); hid.close(); exit(1)
    }
}

if let p = CommandLine.arguments.firstIndex(of: "ledrestore"), p + 1 < CommandLine.arguments.count {
    let backupPath = CommandLine.arguments[p + 1]
    func hx(_ d: [UInt8]) -> String { d.map { String(format: "%02x", $0) }.joined(separator: " ") }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: backupPath))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let values = obj?["indicatorRaw"] as? [Int], values.count >= 24 else {
            print("❌ 备份中没有完整 indicatorRaw，未写入。"); hid.close(); exit(1)
        }
        let original = values.map { UInt8(clamping: $0) }
        var payload = Array(original.prefix(24))
        payload[0] = 0x7c; payload[1] = 0x00; payload[2] = 0x00; payload[3] = 0x00
        try hid.send(VibeKitFrame.sentFrame(b0: 0x01, b1: 0x0b, b2: 0x88, b3: 0x04, payload: payload))
        Thread.sleep(forTimeInterval: 0.25)
        try dev.setLedMode(Int(original[2]))
        Thread.sleep(forTimeInterval: 0.25)
        try dev.setLedBrightness(Int(original[3]))
        Thread.sleep(forTimeInterval: 0.25)
        if let originalBreathe = obj?["indicatorBreathe"] as? Bool {
            try dev.setIndicatorBreathe(originalBreathe)
            Thread.sleep(forTimeInterval: 0.25)
        }
        if let originalFlick = obj?["micUiFlick"] as? Bool {
            try dev.setMicUiFlick(originalFlick)
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let after = dev.getIndicatorRaw(), after.count >= 24 else {
            print("⚠️ 恢复命令已发送，但读回失败；请唤醒设备后核验。"); hid.close(); exit(2)
        }
        let rawOK = Array(after.prefix(24)) == Array(original.prefix(24))
        let expectedBreathe = obj?["indicatorBreathe"] as? Bool
        let expectedFlick = obj?["micUiFlick"] as? Bool
        let breatheOK = expectedBreathe == nil || dev.getIndicatorBreathe() == expectedBreathe
        let flickOK = expectedFlick == nil || dev.getMicUiFlick() == expectedFlick
        print("恢复读回：types=\((0..<4).map { Int(after[4 + 5 * $0]) })  mode=\(after[2])  全局呼吸=\(dev.getIndicatorBreathe().map(String.init) ?? "无响应")  micUiFlick=\(dev.getMicUiFlick().map(String.init) ?? "无响应")")
        print("raw[\(after.count)] = \(hx(after))")
        print(rawOK && breatheOK && flickOK ? "✅ 灯效、全局呼吸与 btn1 闪烁开关均恢复；本测试未写任何按键槽位。" : "⚠️ 恢复读回与备份不完全一致，不能报告恢复完成。")
        hid.close(); exit(rawOK && breatheOK && flickOK ? 0 : 2)
    } catch {
        print("❌ 恢复失败：\(error)"); hid.close(); exit(1)
    }
}

if CommandLine.arguments.contains("ledon2") {
    // UI 的全亮亮度档位是 0/1/2；不用 ledon 里的 100 作为有效档位假设。
    do {
        try dev.setLedMode(1); Thread.sleep(forTimeInterval: 0.25)
        try dev.setLedBrightness(2); Thread.sleep(forTimeInterval: 0.4)
        let raw = dev.getIndicatorRaw()
        print("已写 mode=1、全亮亮度档=2；mode 读回=\(raw?.count ?? 0 > 2 ? String(raw![2]) : "无响应")")
        print("请观察三颗按键灯与旋钮灯。此输出不代表肉眼结果。")
        hid.close(); exit(0)
    } catch {
        print("❌ 全亮档位测试写入失败：\(error)"); hid.close(); exit(1)
    }
}

if CommandLine.arguments.contains("ledon") {
    try? dev.setLedMode(1); Thread.sleep(forTimeInterval: 0.2)
    try? dev.setLedBrightness(100); Thread.sleep(forTimeInterval: 0.2)
    try? dev.setLedTypes([1, 1, 1, 1], focus: 0)
    print("已发：灯效模式=全亮 / 亮度=100 / 四灯=常亮")
    hid.close(); exit(0)
}

if let p = CommandLine.arguments.firstIndex(of: "standby") {
    let before = dev.getStandbyTime()
    if p + 1 < CommandLine.arguments.count, let secs = Int(CommandLine.arguments[p + 1]) {
        try? dev.setStandbyTime(secs)
        Thread.sleep(forTimeInterval: 0.3)
        print("待机时长：\(before.map(String.init) ?? "无响应") → \(dev.getStandbyTime().map(String.init) ?? "无响应")（目标 \(secs)）")
    } else {
        print("待机时长：\(before.map(String.init) ?? "无响应")  睡眠：\(dev.getSleepTime().map(String.init) ?? "无响应")")
    }
    hid.close(); exit(0)
}

if CommandLine.arguments.contains("wake") {
    try? dev.sendHeartbeat()
    print("已发 deviceHeartbeat (06 01 23 00)")
    hid.close(); exit(0)
}

if CommandLine.arguments.contains("restoredial") {
    let plan: [(UInt8, UInt8, String)] = [(3, 11, "按下→静音"), (4, 12, "右转→音量+"), (5, 13, "左转→音量-")]
    for (idx, fn, label) in plan {
        try? dev.setShortcut(index: idx, tokens: [])
        Thread.sleep(forTimeInterval: 0.15)
        try? dev.setButtonFixedFunction(index: idx, funcIndex: fn)
        Thread.sleep(forTimeInterval: 0.15)
        let sc = dev.getShortcut(index: idx)
        let ff = dev.getButtonFixedFunction(index: idx)
        let scOK = (sc?.isEmpty ?? false), ffOK = (ff == fn)
        print("  index \(idx) \(label): 0x50=\(scOK ? "空 ✅" : "\(sc.map(String.init(describing:)) ?? "?") ⚠️")  0x10=\(ff.map(String.init) ?? "?") \(ffOK ? "✅" : "⚠️")")
    }
    hid.close(); exit(0)
}

if let p = CommandLine.arguments.firstIndex(of: "media"), p + 2 < CommandLine.arguments.count,
   let idx = UInt8(CommandLine.arguments[p + 1]), let fn = UInt8(CommandLine.arguments[p + 2]) {
    let before = dev.getSlot(index: idx)
    try? dev.setMediaKey(index: idx, funcIndex: fn)
    Thread.sleep(forTimeInterval: 0.25)
    let after = dev.getSlot(index: idx)
    func d(_ s: (shortcut: [String]?, funcIndex: UInt8)) -> String {
        let sc = s.shortcut.map { $0.isEmpty ? "空" : VibeKitKeymap.tokensToDisplay($0) } ?? "?"
        return "0x50=\(sc)  0x10=\(s.funcIndex)"
    }
    print("  写入前: \(d(before))")
    print("  写入后: \(d(after))")
    let ok = (after.shortcut?.isEmpty ?? false) && after.funcIndex == fn
    print(ok ? "  ✅ 互斥写入正确：0x50 已清空，0x10 = \(fn)" : "  ⚠️ 不符合预期")
    hid.close(); exit(0)
}

if let p = CommandLine.arguments.firstIndex(of: "get"), p + 2 < CommandLine.arguments.count,
   let b1 = UInt8(CommandLine.arguments[p + 1], radix: 16), let b2 = UInt8(CommandLine.arguments[p + 2], radix: 16) {
    let d = hid.request(b1: b1, b2: b2)
    print(String(format: "01 %02x %02x 01 → ", b1, b2) + (d.map { $0.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "（无响应）"))
    hid.close(); exit(0)
}

if CommandLine.arguments.contains("status") {
    let items: [(String, UInt8, UInt8)] = [
        ("待机状态 StandbyStatus", 0x01, 0x0d),
        ("待机时长 StandbyTime", 0x01, 0x2c),
        ("休眠时长 SleepTime", 0x01, 0x42),
        ("旋钮使能 WheelEnable", 0x01, 0x34),
        ("麦克风使能 MicEnable", 0x01, 0x2a),
        ("HooksMode", 0x0b, 0x89),
        ("AudioButtonSystemMode", 0x06, 0x51),
        ("AI 键功能 AIButtonFunc", 0x06, 0x21),
        ("全部按键功能 AllButtonFunc", 0x06, 0x31),
        ("支持的按键功能 SupportButtonFunc", 0x06, 0x38),
    ]
    for (name, b1, b2) in items {
        let d = hid.request(b1: b1, b2: b2)
        let hx = d.map { $0.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "（无响应）"
        print("  \(name.padding(toLength: 30, withPad: " ", startingAt: 0)) = \(hx)")
    }
    if let b = dev.getBatteryFull() { print("  电池 = \(b.percent)% / \(b.voltage)mV / 充电中=\(b.charging)") }
    hid.close(); exit(0)
}

if let p = CommandLine.arguments.firstIndex(of: "clearsc"),
   p + 1 < CommandLine.arguments.count, let idx = UInt8(CommandLine.arguments[p + 1]) {
    try? dev.setShortcut(index: idx, tokens: [])
    Thread.sleep(forTimeInterval: 0.2)
    let sc = dev.getShortcut(index: idx)
    print("index \(idx) 快捷键已清空，读回 = \(sc.map { $0.isEmpty ? "（空槽）" : VibeKitKeymap.tokensToDisplay($0) } ?? "?")")
    print("index \(idx) 固定功能仍为 = \(dev.getButtonFixedFunction(index: idx).map(String.init) ?? "?")")
    hid.close(); exit(0)
}

if let p = CommandLine.arguments.firstIndex(of: "ff") {
    let rest = CommandLine.arguments.dropFirst(p + 1).compactMap { UInt8($0) }
    guard let idx = rest.first else { print("用法: ff <index> [funcIndex]"); hid.close(); exit(1) }
    if rest.count >= 2 {
        try? dev.setButtonFixedFunction(index: idx, funcIndex: rest[1])
        Thread.sleep(forTimeInterval: 0.2)
        print("index \(idx) 固定功能写入 \(rest[1])，读回 = \(dev.getButtonFixedFunction(index: idx).map(String.init) ?? "?")")
    } else {
        print("index \(idx) 固定功能 = \(dev.getButtonFixedFunction(index: idx).map(String.init) ?? "（无响应）")")
    }
    hid.close(); exit(0)
}

if CommandLine.arguments.contains("hooksprobe") {
    func rd(_ b1: UInt8, _ b2: UInt8) -> String {
        hid.request(b1: b1, b2: b2).map { d in d.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "（无响应）"
    }
    func hooks() -> String { rd(0x0b, 0x89) }
    func audio() -> String { rd(0x06, 0x51) }

    for cmd in ["setDeviceHooksMode:", "setDeviceAudioButtonSystemMode:"] {
        if let f = try? VibeKitCommands.build(cmd, args: [1]) {
            print("  \(cmd.padding(toLength: 34, withPad: " ", startingAt: 0)) 密文 \(f.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " "))")
            let plain = VibeKitFrame.decodeVendorFrame(f)
            print("  \(String(repeating: " ", count: 34)) 明文 \(plain.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " "))")
        } else { print("  ⚠️ \(cmd) 构造失败") }
    }

    print("\n== 初始 ==  Hooks=\(hooks())  Audio=\(audio())")

    print("\n---- 发 setDeviceHooksMode:1（显式捕获错误）----")
    do {
        let f = try VibeKitCommands.build("setDeviceHooksMode:", args: [1])
        try hid.send(f)
        print("  发送成功（无错误）")
    } catch { print("  ❌ 发送抛错：\(error)") }

    for t in [0.1, 0.4, 1.0, 2.0, 4.0] {
        Thread.sleep(forTimeInterval: t == 0.1 ? 0.1 : 0.3)
        print("  +\(t)s  Hooks=\(hooks())")
    }

    for v in [2, 1, 0] {
        if let f = try? VibeKitCommands.build("setDeviceHooksMode:", args: [v]) { try? hid.send(f) }
        Thread.sleep(forTimeInterval: 0.4)
        print("  写 \(v) → 读回 Hooks=\(hooks())")
    }

    print("\n---- 先 Audio=1，再 Hooks=1 ----")
    if let f = try? VibeKitCommands.build("setDeviceAudioButtonSystemMode:", args: [1]) { try? hid.send(f) }
    Thread.sleep(forTimeInterval: 0.4)
    print("  Audio=\(audio())")
    if let f = try? VibeKitCommands.build("setDeviceHooksMode:", args: [1]) { try? hid.send(f) }
    Thread.sleep(forTimeInterval: 0.4)
    print("  Hooks=\(hooks())   ← 这就是 hookstest 第 2 轮当时的真实状态（那轮从没回读过 Hooks）")

    print("\n---- 手搓帧 01 0b 89 04 | 01 ----")
    try? hid.send(VibeKitFrame.sentFrame(b0: 0x01, b1: 0x0b, b2: 0x89, b3: 0x04, payload: [0x01]))
    Thread.sleep(forTimeInterval: 0.4)
    print("  Hooks=\(hooks())")
    for (label, pl) in [("payload=[00,01]", [UInt8](arrayLiteral: 0x00, 0x01)), ("payload=[01,00]", [0x01, 0x00]), ("payload=[00,00,01]", [0x00, 0x00, 0x01])] {
        try? hid.send(VibeKitFrame.sentFrame(b0: 0x01, b1: 0x0b, b2: 0x89, b3: 0x04, payload: pl))
        Thread.sleep(forTimeInterval: 0.4)
        print("  \(label) → Hooks=\(hooks())")
    }

    for cmd in ["setDeviceHooksMode:", "setDeviceAudioButtonSystemMode:"] {
        if let f = try? VibeKitCommands.build(cmd, args: [0]) { try? hid.send(f); Thread.sleep(forTimeInterval: 0.2) }
    }
    print("\n== 复位 ==  Hooks=\(hooks())  Audio=\(audio())")
    hid.close(); exit(0)
}

if CommandLine.arguments.contains("hookstest") {
    func readMode(_ b1: UInt8, _ b2: UInt8) -> UInt8? { hid.request(b1: b1, b2: b2)?.first }
    func restore() {
        for cmd in ["setDeviceHooksMode:", "setDeviceAudioButtonSystemMode:"] {
            if let f = try? VibeKitCommands.build(cmd, args: [0]) { try? hid.send(f); Thread.sleep(forTimeInterval: 0.15) }
        }
        let h = readMode(0x0b, 0x89), a = readMode(0x06, 0x51)
        print("\n== 复位 == HooksMode=\(h.map(String.init) ?? "?")  AudioButtonSystemMode=\(a.map(String.init) ?? "?") \((h == 0 && a == 0) ? "✅" : "⚠️ 未复位成功，按键可能失效，请重跑 resetmodes")")
    }

    guard let h0 = readMode(0x0b, 0x89) else {
        print("❌ 厂商口无响应——设备多半在待机。请按一下设备上任意键唤醒后重跑。")
        print("   （USB 还在、hid.open() 成功都不代表没待机，这点已踩过坑）")
        hid.close(); exit(1)
    }
    print("== 起始状态 ==  HooksMode=\(h0)  AudioButtonSystemMode=\(readMode(0x06, 0x51).map(String.init) ?? "?")\n")

    var baselineHeaders = Set<String>()   // 对照轮见过的帧头 = 设备自发的背景噪声
    var collecting = true                 // 对照轮：收集基线；之后：比对
    var novel = 0                         // 当前轮里「基线没见过」的帧数

    func segment(_ label: String, _ secs: TimeInterval) {
        print("  ▸ \(label)（\(Int(secs))秒）")
        var shown = 0
        let t0 = Date()
        hid.listenRaw(window: secs) { rid, cipher in
            let plain = VibeKitFrame.decodeVendorFrame(cipher.first == 0x55 && cipher.count > 1 ? Array(cipher.dropFirst()) : cipher)
            let head = plain.prefix(3).map { String(format: "%02x", $0) }.joined(separator: " ")
            if collecting { baselineHeaders.insert(head); return }   // 对照轮只记帧头，不刷屏
            guard !baselineHeaders.contains(head) else { return }    // 背景噪声，跳过
            novel += 1; shown += 1
            let hx = { (d: [UInt8]) in d.prefix(14).map { String(format: "%02x", $0) }.joined(separator: " ") }
            print(String(format: "      [%+.1fs] rid=0x%x len=%d  ← 新帧头 %@", Date().timeIntervalSince(t0), rid, cipher.count, head))
            print("             明文 \(hx(plain))")
            print("             密文 \(hx(cipher))")
        }
        if !collecting && shown == 0 { print("      —— 无新增帧（只有背景噪声）") }
    }

    func round(_ title: String) -> Int {
        novel = 0
        print("\n\(title)")
        segment("按 btn1 两次", 5)
        segment("按 btn2 两次", 5)
        segment("按 btn3 两次", 5)
        segment("旋钮左转几格", 5)
        segment("旋钮右转几格", 5)
        segment("按下旋钮两次", 5)
        return novel
    }

    _ = round("== 第 0 轮 · 对照（全关）==  照提示操作，本轮只采集设备自发帧的帧头做基线")
    collecting = false
    print("  基线帧头：\(baselineHeaders.isEmpty ? "（无）" : baselineHeaders.sorted().joined(separator: " / "))  ← 后面出现这些就不算按键上报")

    print("\n---- 开启 HooksMode=1 ----")
    if let f = try? VibeKitCommands.build("setDeviceHooksMode:", args: [1]) { try? hid.send(f) }
    Thread.sleep(forTimeInterval: 0.3)
    let h1 = readMode(0x0b, 0x89)
    let h1ok = (h1 == 1)
    print("   读回 HooksMode=\(h1.map(String.init) ?? "?") \(h1ok ? "✅ 写入生效" : "⚠️ 没写进去——这轮测的其实还是关闭状态，结果不能算数")")
    let r1 = round("== 第 1 轮 · HooksMode=\(h1.map(String.init) ?? "?") ==")

    print("\n---- 追加 AudioButtonSystemMode=1 ----")
    if let f = try? VibeKitCommands.build("setDeviceAudioButtonSystemMode:", args: [1]) { try? hid.send(f) }
    Thread.sleep(forTimeInterval: 0.3)
    let a1 = readMode(0x06, 0x51)
    let h2 = readMode(0x0b, 0x89)   // 顺带复查 Hooks——首版漏了这次回读，导致第2轮的真实状态未知
    print("   读回 AudioButtonSystemMode=\(a1.map(String.init) ?? "?") \(a1 == 1 ? "✅" : "⚠️ 没写进去，结果不作数")   HooksMode=\(h2.map(String.init) ?? "?")")
    let r2 = round("== 第 2 轮 · Hooks=\(h2.map(String.init) ?? "?") + Audio=\(a1.map(String.init) ?? "?") ==")

    print("\n== 结果（只计基线之外的新帧头）==")
    print("  第 1 轮 = \(r1) 帧   （HooksMode 实际值 \(h1.map(String.init) ?? "?")）")
    print("  第 2 轮 = \(r2) 帧   （Hooks \(h2.map(String.init) ?? "?") / Audio \(a1.map(String.init) ?? "?")）")
    if r1 == 0 && r2 == 0 {
        if !h1ok {
            print("\n结论：不成立也不否定——HooksMode 压根没写进去，等于没测。先跑 hooksprobe 查清为什么写不进去。")
        } else {
            print("\n结论：开了上报模式设备依然不经厂商口上报按键 → B 方案（上位机转发）不成立，需另找路径。")
        }
    } else {
        print("\n结论：出现了基线之外的帧 → 值得继续。下一步按分段标签解析：哪一字节代表哪个键、按下/抬起怎么区分。")
        print("      注意先人工核对上面的新帧确实跟按键时刻对得上，别再让一个定时广播蒙混过关。")
    }
    restore()
    hid.close(); exit(0)
}

if CommandLine.arguments.contains("hooks") {
    print("== 开启 HooksMode / AudioButtonSystemMode 后监听 10 秒，请按 btn/转旋钮 ==")
    for cmd in ["setDeviceHooksMode:", "setDeviceAudioButtonSystemMode:"] {
        if let f = try? VibeKitCommands.build(cmd, args: [1]) { try? hid.send(f); print("  已发 \(cmd)=1") }
    }
    Thread.sleep(forTimeInterval: 0.3)
    var n = 0
    hid.listen(window: 10) { p in
        n += 1
        let hx = p.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
        print("  [\(n)] \(hx)")
    }
    print("  共 \(n) 帧")
    for cmd in ["setDeviceHooksMode:", "setDeviceAudioButtonSystemMode:"] {
        if let f = try? VibeKitCommands.build(cmd, args: [0]) { try? hid.send(f) }
    }
    hid.close(); exit(0)
}

if CommandLine.arguments.contains("resetmodes") {
    for cmd in ["setDeviceHooksMode:", "setDeviceAudioButtonSystemMode:"] {
        if let f = try? VibeKitCommands.build(cmd, args: [0]) { try? hid.send(f) }
    }
    print("已复位 HooksMode/AudioButtonSystemMode=0"); hid.close(); exit(0)
}

if CommandLine.arguments.contains("hooksraw") {
    for cmd in ["setDeviceHooksMode:", "setDeviceAudioButtonSystemMode:"] {
        if let f = try? VibeKitCommands.build(cmd, args: [1]) { try? hid.send(f) }
    }
    Thread.sleep(forTimeInterval: 0.3)
    print("== HooksMode=1 已开。原始监听 12 秒：慢按 btn1×2 / btn2×2 / btn3×2 / 转旋钮 ==")
    var n = 0
    hid.listenRaw(window: 12) { rid, bytes in
        n += 1
        let hx = bytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
        print("  [\(n)] rid=0x\(String(rid, radix:16)) len=\(bytes.count)  \(hx)")
    }
    print("  共 \(n) 帧")
    for cmd in ["setDeviceHooksMode:", "setDeviceAudioButtonSystemMode:"] {
        if let f = try? VibeKitCommands.build(cmd, args: [0]) { try? hid.send(f); Thread.sleep(forTimeInterval: 0.15) }
    }
    print("  已复位 HooksMode/AudioButtonSystemMode=0")
    hid.close(); exit(0)
}

if CommandLine.arguments.contains("listenraw") {
    print("== 原始监听 12 秒：请依次慢按 btn1 / btn2 / btn3，每个按两次，再转旋钮 ==")
    var n = 0
    hid.listenRaw(window: 12) { rid, bytes in
        n += 1
        let hx = bytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
        print("  [\(n)] reportID=0x\(String(rid, radix:16)) len=\(bytes.count)  \(hx)")
    }
    print("  共 \(n) 帧")
    hid.close(); exit(0)
}

if CommandLine.arguments.contains("listen") {
    print("== 被动监听 12 秒：请依次 按 btn1/btn2/btn3、转动旋钮、按下旋钮 ==")
    print("   (只听不发；观察是否有未请求的 st_key_msg 上报)")
    var n = 0
    hid.listen(window: 12) { p in
        n += 1
        let hx = p.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
        print("  [\(n)] hdr=\(String(format:"%02x %02x %02x %02x", p.count>0 ? p[0]:0, p.count>1 ? p[1]:0, p.count>2 ? p[2]:0, p.count>3 ? p[3]:0))  data=\(hx)")
    }
    print("  共 \(n) 帧。若为 0，则按键不走 0x55 通道(只走标准键盘口)。")
    hid.close(); exit(0)
}

if CommandLine.arguments.contains("mic") {
    print("当前默认输入: \(VibeKitAudio.currentInputName())")
    if let au = VibeKitAudio.inputDevices().first(where: { $0.name.localizedCaseInsensitiveContains("au05") }) {
        let ok = VibeKitAudio.setDefaultInput(au.id)
        Thread.sleep(forTimeInterval: 0.3)
        print("切到 AU05: \(ok ? "成功" : "失败") → 现在默认输入: \(VibeKitAudio.currentInputName())")
    } else { print("未找到 AU05 输入设备") }
    hid.close(); exit(0)
}

if CommandLine.arguments.contains("ledbright") {
    func raw(_ d: [UInt8]?) -> String { d.map { $0.prefix(10).map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "nil" }
    try? dev.setLedMode(1); Thread.sleep(forTimeInterval: 0.5)  // 全亮
    for v in [100, 50, 10, 1, 2, 0, 100] {
        try? dev.setLedBrightness(v); Thread.sleep(forTimeInterval: 1.5)
        print("  亮度写入=\(v)，读回: \(raw(dev.getIndicatorRaw()))  ← 灯现在多亮？")
    }
    hid.close(); exit(0)
}

if CommandLine.arguments.contains("led") {
    print("== 灯效标定：依次 亮度=100 + 模式 0/1/2，请观察 VibeKey 的灯 ==")
    func raw(_ d: [UInt8]?) -> String { d.map { $0.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "nil" }
    print("  初始指示灯读回: \(raw(dev.getIndicatorRaw()))")
    try? dev.setLedBrightness(100); Thread.sleep(forTimeInterval: 0.3)
    for m in [0, 1, 2] {
        try? dev.setLedMode(m)
        Thread.sleep(forTimeInterval: 1.5)
        print("  已设模式=\(m)，读回: \(raw(dev.getIndicatorRaw()))  ← 现在灯是什么状态？")
    }
    print("  提示：告诉我 模式0/1/2 分别对应 全灭/全亮/工作 里的哪个")
    hid.close(); exit(0)
}

if CommandLine.arguments.contains("powerprobe") {
    func readU32(_ b2: UInt8) -> UInt32? {
        guard let d = hid.request(b1: 0x01, b2: b2), d.count >= 4 else { return nil }
        return UInt32(d[0]) | (UInt32(d[1]) << 8) | (UInt32(d[2]) << 16) | (UInt32(d[3]) << 24)
    }
    let layouts: [(name: String, dir: UInt8, enc: (UInt32) -> [UInt8])] = [
        ("u32le b3=02", 0x02, { v in (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }),
        ("u16le b3=02", 0x02, { v in (0..<2).map { UInt8((v >> (8 * $0)) & 0xff) } }),
        ("u32le b3=04", 0x04, { v in (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }),
        ("u32le b3=00", 0x00, { v in (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }),
        ("u32be b3=02", 0x02, { v in (0..<4).reversed().map { UInt8((v >> (8 * $0)) & 0xff) } }),
    ]
    for (label, b2) in [("待机 StandbyTime", UInt8(0x2c)), ("休眠 SleepTime", UInt8(0x42))] {
        print("== \(label)  (GET 01 01 \(String(format: "%02x", b2)) 01) ==")
        guard let orig = readU32(b2) else { print("  ❌ 读不到当前值，跳过\n"); continue }
        let test: UInt32 = orig >= 600 ? orig + 600 : 600     // 只增不减
        print("  当前值 = \(orig) 秒；测试值 = \(test) 秒（只往长了写）")
        var hit: String? = nil
        for L in layouts {
            try? hid.send(VibeKitFrame.sentFrame(b0: 0x01, b1: 0x01, b2: b2, b3: L.dir, payload: L.enc(test)))
            Thread.sleep(forTimeInterval: 0.25)
            let back = readU32(b2)
            print("    试 \(L.name)  写 \(test) → 读回 \(back.map(String.init) ?? "nil")")
            if back == test {
                hit = L.name
                try? hid.send(VibeKitFrame.sentFrame(b0: 0x01, b1: 0x01, b2: b2, b3: L.dir, payload: L.enc(orig)))
                Thread.sleep(forTimeInterval: 0.25)
                print("  ✅ 命中 \(L.name)；已写回原值，复验 = \(readU32(b2).map(String.init) ?? "nil")")
                break
            }
        }
        if hit == nil {
            let now = readU32(b2)
            if now == orig {
                print("  ⚠️ 所有候选都没写进去，设备值未被改动（固件可能不支持写）")
            } else {
                print("  ‼️ 所有候选都没命中，但值已变成 \(now.map(String.init) ?? "nil")，尝试逐个布局写回原值 \(orig)")
                for L in layouts {
                    try? hid.send(VibeKitFrame.sentFrame(b0: 0x01, b1: 0x01, b2: b2, b3: L.dir, payload: L.enc(orig)))
                    Thread.sleep(forTimeInterval: 0.25)
                    if readU32(b2) == orig { print("  ✅ 已用 \(L.name) 写回原值"); break }
                }
            }
        }
        print("")
    }
    hid.close(); exit(0)
}

if CommandLine.arguments.contains("powertest") {
    guard let sb0 = dev.getStandbyTime(), let sl0 = dev.getSleepTime() else {
        print("❌ 读不到当前值（设备可能待机，先物理唤醒）"); hid.close(); exit(1)
    }
    print("原值：待机=\(sb0)s  休眠=\(sl0)s")
    try? dev.setStandbyTime(1800); Thread.sleep(forTimeInterval: 0.25)
    try? dev.setSleepTime(7200);  Thread.sleep(forTimeInterval: 0.25)
    let sb1 = dev.getStandbyTime(), sl1 = dev.getSleepTime()
    print("写 1800/7200 后读回：待机=\(sb1.map(String.init) ?? "nil")  休眠=\(sl1.map(String.init) ?? "nil")")
    let ok = (sb1 == 1800 && sl1 == 7200)
    try? dev.setStandbyTime(sb0); Thread.sleep(forTimeInterval: 0.25)
    try? dev.setSleepTime(sl0);   Thread.sleep(forTimeInterval: 0.25)
    print("还原后读回：待机=\(dev.getStandbyTime().map(String.init) ?? "nil")  休眠=\(dev.getSleepTime().map(String.init) ?? "nil")")
    print(ok ? "✅ 设备层读写一致" : "❌ 读回与写入不符")
    hid.close(); exit(ok ? 0 : 1)
}

var argv = Array(CommandLine.arguments.dropFirst())
var index: UInt8 = 0  // btn1
if let p = argv.firstIndex(of: "idx"), p + 1 < argv.count, let v = UInt8(argv[p + 1]) {
    index = v
    argv.removeSubrange(p...(p + 1))
}
var tokens = argv
if tokens.isEmpty { tokens = ["LCmd", "C"] }

print("== 写离线快捷键到 index \(index)：\(VibeKitKeymap.tokensToDisplay(tokens)) ==")
do {
    try dev.setShortcut(index: index, tokens: tokens)
    print("  已发送写入命令")
} catch { print("  ❌ 写入失败：\(error)"); exit(1) }

Thread.sleep(forTimeInterval: 0.2)
if let rb = dev.getShortcut(index: index) {
    let ok = rb == tokens
    print("  回读: \(VibeKitKeymap.tokensToDisplay(rb))  \(ok ? "✅ 与写入一致" : "⚠️ 不一致(写入=\(tokens) 读回=\(rb))")")
} else {
    print("  ⚠️ 回读失败（设备可能待机/被占用）")
}

print("\n== 写亮度=50 并读回 ==")
try? dev.setBrightness(50)
Thread.sleep(forTimeInterval: 0.2)
print("  亮度读回: \(dev.getBrightness().map(String.init) ?? "?")")

print("\n➡️ 现在把焦点放到任意输入框，按一下该槽对应的物理键，验证是否触发「\(VibeKitKeymap.tokensToDisplay(tokens))」")
hid.close()
