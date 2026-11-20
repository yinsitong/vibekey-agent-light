// VibeKey 状态栏
//
// 在 macOS 顶部菜单栏显示 Proma Agent 的当前状态，和灯光完全同源：
// 读取 bridge.py 写出的 ~/Library/Logs/PromaVibeKey/status.json，
// 状态一变菜单栏立刻跟着变。灯不在手边（或设备没插）时也能看状态。
//
// 为什么用 Swift 而不是 Python：
//   - 菜单栏需要 NSStatusItem，PyObjC 不是系统自带，装依赖会让「登录自启」变脆；
//   - 本项目已经依赖 Xcode CLI 工具编译 vibekit-led，这里同样用 swiftc 编一个小 App，
//     零第三方依赖，编译产物就是 bin/VibeKeyStatusBar.app。
//
// 状态与视觉对应（● 实心 = 有明确动作，○ 空心 = 静止/异常）：
//   ● 空闲（灰）     ● 思考（蓝）     ● 工作（橙）
//   ● 确认（紫，闪） ● 报错（红，闪） ● 收尾（青）
//   ○ 暂停（灰）     ○ 离线（黄，桥接没写心跳）

import AppKit
import Foundation

// MARK: - 路径与常量

private let logDir = ("~/Library/Logs/PromaVibeKey" as NSString).expandingTildeInPath
private let statusPath = (logDir as NSString).appendingPathComponent("status.json")
private let pausePath = (logDir as NSString).appendingPathComponent("pause")

/// status.json 的 at 字段超过这个秒数没更新，就当桥接进程没在跑
private let staleAfter: TimeInterval = 20
/// 刷新间隔：0.5 秒。够快能跟上状态，且每 tick 只读一个小 JSON 文件
private let tickInterval: TimeInterval = 0.5

// MARK: - 状态样式

private struct Style {
    let short: String      // 菜单栏上的短标签
    let full: String       // 菜单里的完整说法
    let color: NSColor
    let blink: Bool
    let hollow: Bool
}

private func style(for state: String) -> Style {
    switch state {
    case "thinking":
        return Style(short: "思考", full: "思考中", color: .systemBlue, blink: false, hollow: false)
    case "working":
        return Style(short: "工作", full: "执行中", color: .systemOrange, blink: false, hollow: false)
    case "confirm":
        return Style(short: "确认", full: "等你说", color: .systemPurple, blink: true, hollow: false)
    case "error":
        return Style(short: "报错", full: "出错", color: .systemRed, blink: true, hollow: false)
    case "attention":
        return Style(short: "收尾", full: "刚结束", color: .systemTeal, blink: false, hollow: false)
    case "paused":
        return Style(short: "暂停", full: "已暂停联动", color: .systemGray, blink: false, hollow: true)
    case "offline":
        return Style(short: "离线", full: "桥接未运行", color: .systemYellow, blink: false, hollow: true)
    default:
        return Style(short: "空闲", full: "空闲", color: .systemGray, blink: false, hollow: false)
    }
}

// MARK: - status.json

private struct StatusFile: Decodable {
    let state: String
    let detail: String?
    let paused: Bool?
    let at: Double?
}

private struct Snapshot {
    var state: String
    var detail: String
    var updated: Date?
    var stale: Bool
}

private func readSnapshot() -> Snapshot {
    guard let data = FileManager.default.contents(atPath: statusPath) else {
        return Snapshot(state: "offline", detail: "还没有 status.json", updated: nil, stale: true)
    }
    guard let file = try? JSONDecoder().decode(StatusFile.self, from: data) else {
        return Snapshot(state: "offline", detail: "status.json 解析失败", updated: nil, stale: true)
    }
    let atMs = file.at ?? 0
    let date = Date(timeIntervalSince1970: atMs / 1000)
    let age = Date().timeIntervalSince(date)
    let stale = age > staleAfter
    return Snapshot(
        state: stale ? "offline" : file.state,
        detail: file.detail ?? "",
        updated: date,
        stale: stale
    )
}

// MARK: - 菜单栏控制器

final class StatusBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var blinkVisible = true

    private var headerItem: NSMenuItem!
    private var detailItem: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var iconOnlyItem: NSMenuItem!

    private var state = "offline"
    private var detail = ""
    private var updated: Date?
    private var lastTitleKey = ""

    /// 菜单**平时不挂在 statusItem 上**，只在点击那一刻临时挂上。
    ///
    /// 原因：`statusItem.menu` 常驻时，菜单位置靠系统根据状态项窗口 frame 现算。
    /// 我们的按钮宽度每 0.5 秒会因为状态文字/闪烁变化而重设，窗口 frame 的缓存
    /// 在这种持续重排下会失效（实测 frame 停在 (0, -30)，screen 为 nil），
    /// 于是菜单被定位到屏幕最右侧而不是图标下方。
    /// 改成「点击 → 临时挂 menu → performClick → 摘掉」，系统每次都会按当下
    /// 真实的按钮位置重新计算，位置就钉在图标正下方了。
    private var menu: NSMenu!

    private var iconOnly: Bool {
        get { UserDefaults.standard.bool(forKey: "iconOnly") }
        set { UserDefaults.standard.set(newValue, forKey: "iconOnly") }
    }

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeft

        buildMenu()
        refresh()
        render(force: true)

        let t = Timer.scheduledTimer(timeInterval: tickInterval, target: self,
                                     selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.current.add(t, forMode: .common)
        timer = t

        // 排障用：PROMAC_MENUBAR_DEBUG=1 时把状态项的实际位置打在 stderr
        if ProcessInfo.processInfo.environment["PROMAC_MENUBAR_DEBUG"] == "1" {
            for delay in [1.5, 6.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.debugDump()
                }
            }
        }
    }

    private func debugDump() {
        guard let button = statusItem.button else {
            FileHandle.standardError.write(Data("menubar: 没有 button\n".utf8))
            return
        }
        let bf = button.frame
        let wf = button.window?.frame ?? .zero
        let onScreen = button.window?.isVisible ?? false
        let title = button.title
        let scr = button.window?.screen?.localizedName ?? "?"
        let line = "menubar: state=\(state) title=\(title) button=\(bf) window=\(wf) visible=\(onScreen) screen=\(scr)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    // MARK: 菜单

    private func buildMenu() {
        let menu = NSMenu()

        headerItem = NSMenuItem(title: "Proma 状态：—", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        detailItem.isEnabled = false
        menu.addItem(detailItem)

        menu.addItem(.separator())

        pauseItem = NSMenuItem(title: "暂停灯光联动", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        iconOnlyItem = NSMenuItem(title: "菜单栏只显示圆点", action: #selector(toggleIconOnly), keyEquivalent: "")
        iconOnlyItem.target = self
        menu.addItem(iconOnlyItem)

        menu.addItem(.separator())

        let reload = NSMenuItem(title: "重载灯光桥接", action: #selector(reloadBridge), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)

        let logs = NSMenuItem(title: "打开日志目录", action: #selector(openLogs), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出状态栏", action: #selector(quitSelf), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        self.menu = menu

        // 不设置 statusItem.menu，改由点击事件手动弹（见 menu 属性注释）
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        // 弹之前先把最新状态和菜单项文字刷新一遍，免得显示上一轮的旧值
        refresh()
        menu.update()
        statusItem.menu = menu
        sender.highlight(true)
        sender.performClick(nil)
        statusItem.menu = nil
        sender.highlight(false)
    }

    // MARK: 刷新

    @objc private func tick() {
        blinkVisible.toggle()
        refresh()
        render()
    }

    private func refresh() {
        let snap = readSnapshot()
        state = snap.state
        detail = snap.detail
        updated = snap.updated
        updateMenuTitles()
    }

    private func render(force: Bool = false) {
        // 菜单打开期间不改按钮标题：宽度一变，菜单可能跟着漂
        if !force && statusItem.menu != nil { return }
        let st = style(for: state)
        let key = "\(state)|\(iconOnly)|\(blinkVisible)"
        if !force && key == lastTitleKey { return }
        lastTitleKey = key

        let visible = st.blink ? blinkVisible : true

        // 文字用 button.title（系统自动跟菜单栏明暗走），颜色只体现在圆点上。
        // 之前用 attributedTitle 同时管颜色，结果深色菜单栏上 labelColor 被算成黑色，
        // 文字几乎看不见——只剩圆点。拆开后就两种都正常了。
        statusItem.button?.image = dotImage(color: st.color, hollow: st.hollow)
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.title = iconOnly ? "" : " " + st.short
        statusItem.button?.alphaValue = visible ? 1.0 : 0.3
        statusItem.button?.toolTip = tooltip(for: st)
    }

    /// 把状态画成一个实心/空心小圆点。非 template，颜色才会保留。
    private func dotImage(color: NSColor, hollow: Bool) -> NSImage {
        let d: CGFloat = 9
        let img = NSImage(size: NSSize(width: d, height: d))
        img.lockFocus()
        let rect = NSRect(x: 0.75, y: 0.75, width: d - 1.5, height: d - 1.5)
        let path = NSBezierPath(ovalIn: rect)
        if hollow {
            color.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        } else {
            color.setFill()
            path.fill()
        }
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    private func tooltip(for st: Style) -> String {
        var lines = ["Proma：\(st.full)"]
        if !detail.isEmpty { lines.append(detail) }
        if let updated {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            lines.append("更新于 \(f.string(from: updated))")
        }
        if state == "offline" {
            lines.append("灯光桥接可能没有运行，菜单里可以重载")
        }
        return lines.joined(separator: "\n")
    }

    private func updateMenuTitles() {
        let st = style(for: state)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let when = updated.map { " · " + f.string(from: $0) } ?? ""
        headerItem.title = "Proma 状态：\(st.full)\(when)"

        if detail.isEmpty {
            detailItem.isHidden = true
        } else {
            detailItem.isHidden = false
            let clipped = detail.count > 48 ? String(detail.prefix(48)) + "…" : detail
            detailItem.title = "  " + clipped
        }

        let paused = FileManager.default.fileExists(atPath: pausePath)
        pauseItem.state = paused ? .on : .off
        iconOnlyItem.state = iconOnly ? .on : .off
    }

    // MARK: 动作

    @objc private func togglePause() {
        let fm = FileManager.default
        if fm.fileExists(atPath: pausePath) {
            try? fm.removeItem(atPath: pausePath)
        } else {
            try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
            fm.createFile(atPath: pausePath, contents: Data())
        }
        updateMenuTitles()
    }

    @objc private func toggleIconOnly() {
        iconOnly.toggle()
        updateMenuTitles()
        render(force: true)
    }

    @objc private func reloadBridge() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "gui/\(getuid())/com.proma.vibekey-bridge"]
        try? p.run()
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logDir))
    }

    @objc private func quitSelf() {
        NSApp.terminate(nil)
    }
}

// MARK: - 入口

let app = NSApplication.shared
let controller = StatusBarController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
