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
//
// 闪烁与内发光
// -----------
// 麦克风灯在 confirm / error 时会「闪 6 下 → 亮 2.5 秒」循环（见 vibekit-led
// pulse-loop：每 250ms 交替 hi/lo 共 6 组，然后保持 hi 停 gap）。
// 状态栏不再用整块 alpha 抖，而是给圆点画一圈同色内发光（光晕），并按
// **同一个节奏**闪：bridge 把脉冲起点 pulseAt 和参数写进 status.json，
// 菜单栏用 (now - pulseAt) 取模算出当前处于第几个半拍，因此和灯是同步的，
// 不是各闪各的。拿不到 pulseAt（老版本桥 / 手动 --publish）时用本地时钟兜底。

import AppKit
import Foundation

// MARK: - 路径与常量

private let logDir = ("~/Library/Logs/PromaVibeKey" as NSString).expandingTildeInPath
private let statusPath = (logDir as NSString).appendingPathComponent("status.json")
private let pausePath = (logDir as NSString).appendingPathComponent("pause")

/// status.json 的 at 字段超过这个秒数没更新，就当桥接进程没在跑
private let staleAfter: TimeInterval = 20
/// DateFormatter 构造很贵，缓存一个复用（每 0.5 秒都要格式化时间）
private let hhmmss: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()
/// JSONDecoder 同理
private let jsonDecoder = JSONDecoder()
/// 状态轮询间隔（只读 JSON，不参与动画）
private let tickInterval: TimeInterval = 0.5
/// 发光动画帧间隔。灯的半拍是 250ms，20fps 足够让明暗切换看起来干净
private let animInterval: TimeInterval = 1.0 / 12.0
/// 「定位我」窗口期显示的文字与时长
private let locateLabel = "◀ 我 ▶"
private let locateSeconds: TimeInterval = 30

/// 兜底脉冲参数（与 bridge.py 的默认值一致）
private let fallbackPulseMs = 250
private let fallbackBurst = 6
private let fallbackGap = 2500

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
    // 脉冲同步信息，仅 confirm / error 时存在
    let pulseAt: Double?      // 灯开始脉冲的毫秒时间戳
    let pulseMs: Int?         // 每半拍毫秒数
    let pulseBurst: Int?      // 每组闪几下
    let pulseGap: Int?        // 组间停顿毫秒
}

/// 灯的脉冲节奏。周期 = 闪的那段 + 停顿的那段。
private struct PulseInfo {
    var start: Date
    var ms: Int
    var burst: Int
    var gap: Int

    var blinkSpanMs: Int { burst * 2 * ms }
    var periodMs: Int { blinkSpanMs + gap }
}

private struct Snapshot {
    var state: String
    var detail: String
    var updated: Date?
    var stale: Bool
    var pulse: PulseInfo?
}

private func readSnapshot() -> Snapshot {
    guard let data = FileManager.default.contents(atPath: statusPath) else {
        return Snapshot(state: "offline", detail: "还没有 status.json", updated: nil, stale: true, pulse: nil)
    }
    guard let file = try? jsonDecoder.decode(StatusFile.self, from: data) else {
        return Snapshot(state: "offline", detail: "status.json 解析失败", updated: nil, stale: true, pulse: nil)
    }
    let atMs = file.at ?? 0
    let date = Date(timeIntervalSince1970: atMs / 1000)
    let age = Date().timeIntervalSince(date)
    let stale = age > staleAfter

    // 只有桥明确给了 pulseAt 才认；参数缺项用默认值补齐
    var pulse: PulseInfo?
    if let pAt = file.pulseAt, pAt > 0 {
        pulse = PulseInfo(
            start: Date(timeIntervalSince1970: pAt / 1000),
            ms: max(60, file.pulseMs ?? fallbackPulseMs),
            burst: max(1, file.pulseBurst ?? fallbackBurst),
            gap: max(0, file.pulseGap ?? fallbackGap)
        )
    }

    return Snapshot(
        state: stale ? "offline" : file.state,
        detail: file.detail ?? "",
        updated: date,
        stale: stale,
        pulse: stale ? nil : pulse
    )
}

// MARK: - 下沿外发光
//
// 状态项本身的 frame 就是菜单栏高度，画在按钮里的东西不可能溢出到菜单栏下方——
// 那里不是它的绘制区域。所以真正「整条下沿往外发光」只能用一个独立的透明窗口：
// 无边框、非激活、忽略鼠标、层级在普通窗口之上、跟随所有 Space，
// 每帧贴到状态项下方，画一条横向两端柔和淡出的竖向渐变光带。
// 它只在需要提醒/干活时出现，睡眠和空闲状态下完全不占屏幕。

private final class GlowView: NSView {
    var color: NSColor = .systemPurple
    var intensity: CGFloat = 0

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard intensity > 0.01,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds

        // 竖向：贴着菜单栏下沿最亮，往下迅速衰减
        let cs = [
            color.withAlphaComponent(0.60 * intensity).cgColor,
            color.withAlphaComponent(0.24 * intensity).cgColor,
            color.withAlphaComponent(0.00).cgColor,
        ] as CFArray
        guard let vg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: cs, locations: [0.0, 0.34, 1.0]) else { return }

        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.drawLinearGradient(vg,
                               start: CGPoint(x: 0, y: b.maxY),
                               end: CGPoint(x: 0, y: b.minY),
                               options: [])

        // 横向：用 destinationIn 乘一个两端淡出的遮罩，避免光带被硬切出直角
        ctx.setBlendMode(.destinationIn)
        let ms = [
            NSColor(white: 1, alpha: 0).cgColor,
            NSColor(white: 1, alpha: 1).cgColor,
            NSColor(white: 1, alpha: 1).cgColor,
            NSColor(white: 1, alpha: 0).cgColor,
        ] as CFArray
        if let mg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: ms, locations: [0.0, 0.16, 0.84, 1.0]) {
            ctx.drawLinearGradient(mg,
                                   start: CGPoint(x: b.minX, y: 0),
                                   end: CGPoint(x: b.maxX, y: 0),
                                   options: [])
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

// MARK: - 菜单栏控制器

final class StatusBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var animTimer: Timer?

    private var headerItem: NSMenuItem!
    private var detailItem: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var iconOnlyItem: NSMenuItem!
    private var glowItem: NSMenuItem!

    // 下沿外发光的独立窗口
    private var glowPanel: NSPanel?
    private var glowView: GlowView?
    private var lastGlowKey = ""

    // 固定宽度：变长状态项一旦长度变化，菜单栏要把整组图标重新排一遍，
    // 每 250ms 闪一次就等于每秒重排几次，实测能吃掉 8% CPU。
    // 我们的标签都是两个字，宽度算一次定死，闪灯只换图片不动布局。
    private var labelLength: CGFloat = 72
    private var iconLength: CGFloat = 28
    private var locateLength: CGFloat = 92

    // 「在收纳栏里定位我」：把状态项变成一个显眼的跳动标记，方便在 Barbee 之类
    // 收纳工具的面板里一眼认出哪一个是这盏灯。窗口期结束自动恢复。
    private var locateUntil: Date?
    private var locateTimer: Timer?
    private var locateBlink = false
    private var locateItem: NSMenuItem!
    private var lastLocateRequest = 0

    // 上一帧的“视觉签名”，没变就整帧跳过
    private var lastFrameKey = ""

    private var state = "offline"
    private var detail = ""
    private var updated: Date?
    private var lastTitleKey = ""
    private var lastImageKey = ""
    private var pulse: PulseInfo?

    // 圆点用 CALayer 承载：闪烁交给 Core Animation 在渲染服务器里跑，
    // 不换 button.image。实测每次赋值 button.image 都触发状态项整组重排，
    // 每秒 4 次就到 7% CPU；改用图层动画后降到 0.2%。
    private var dotLayer: CALayer?
    private var dotPlaceholder: NSImage?
    private var lastDotContentsKey = ""
    private var lastDotKey = ""

    /// 菜单**平时不挂在 statusItem 上**，只在点击那一刻临时挂上。
    ///
    /// 原因：`statusItem.menu` 常驻时，菜单位置靠系统根据状态项窗口 frame 现算。
    /// 我们的按钮宽度每 0.5 秒会因为状态文字变化而重设，窗口 frame 的缓存
    /// 在这种持续重排下会失效（实测 frame 停在 (0, -30)，screen 为 nil），
    /// 于是菜单被定位到屏幕最右侧而不是图标下方。
    /// 改成「点击 → 临时挂 menu → performClick → 摘掉」，系统每次都会按当下
    /// 真实的按钮位置重新计算，位置就钉在图标正下方了。
    /// 同理，发光动画只改图片不改标题，按钮宽度恒定，菜单也不会跟着漂。
    private var menu: NSMenu!

    private var iconOnly: Bool {
        get { UserDefaults.standard.bool(forKey: "iconOnly") }
        set { UserDefaults.standard.set(newValue, forKey: "iconOnly") }
    }

    /// 下沿外发光开关。默认开；觉得碍眼可以在菜单里关掉
    private var glowEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "glowEnabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "glowEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "glowEnabled"); applyGlow() }
    }

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeft
        // 圆点画布固定 20×20，不要让它参与缩放测量
        statusItem.button?.imageScaling = .scaleNone
        statusItem.button?.alignment = .center

        buildMenu()
        measureLengths()
        installDotLayer()
        lastLocateRequest = UserDefaults.standard.integer(forKey: "locateRequest")
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

    /// 用状态项自己按钮的字体量出「最长标签」的宽度，避免换字时被裁
    private func measureLengths() {
        guard let btn = statusItem.button else { return }
        let font = btn.font ?? NSFont.systemFont(ofSize: 13)
        let dotWidth: CGFloat = 20        // 圆点画布宽度
        var widest: CGFloat = 0
        for st in ["空闲", "思考", "工作", "确认", "报错", "收尾", "暂停", "离线"] {
            let w = (" " + st as NSString).size(withAttributes: [.font: font]).width
            widest = max(widest, w)
        }
        labelLength = ceil(dotWidth + widest) + 10
        iconLength = dotWidth + 8
        // 定位标签更长，单独量，避免窗口期被裁
        let locateW = (" " + locateLabel as NSString).size(withAttributes: [.font: font]).width
        locateLength = ceil(dotWidth + locateW) + 10
    }

    private func applyLength() {
        if isLocating { statusItem.length = locateLength; return }
        statusItem.length = iconOnly ? iconLength : labelLength
    }

    private var isLocating: Bool {
        guard let until = locateUntil else { return false }
        return Date() < until
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
        let phase = pulsePhase()
        let line = "menubar: state=\(state) title=\(title) pulse=\(pulse != nil ? "yes" : "no") "
            + "on=\(phase.on) glow=\(String(format: "%.2f", phase.glow)) "
            + "button=\(bf) window=\(wf) visible=\(onScreen) screen=\(scr)\n"
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

        glowItem = NSMenuItem(title: "下沿外发光", action: #selector(toggleGlow), keyEquivalent: "")
        glowItem.target = self
        menu.addItem(glowItem)

        locateItem = NSMenuItem(title: "在收纳栏里定位我（闪 30 秒）",
                                action: #selector(startLocate), keyEquivalent: "")
        locateItem.target = self
        menu.addItem(locateItem)

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
        reviveIfHidden()
        refresh()
        render()
        // 外部也能触发定位（defaults write com.proma.vibekey-menubar locateRequest -int <时间戳>），
        // 方便脚本化，也方便在收纳面板里怀疑“哪个是我”时用命令再闪一发
        let req = UserDefaults.standard.integer(forKey: "locateRequest")
        if req > lastLocateRequest {
            lastLocateRequest = req
            if req > 1 { startLocate() }
        }
    }

    private func refresh() {
        let snap = readSnapshot()
        state = snap.state
        detail = snap.detail
        updated = snap.updated

        let shouldPulse = style(for: state).blink
        if shouldPulse {
            if let p = snap.pulse {
                pulse = p                       // 桥给的绝对起点，和灯同步
            } else if pulse == nil {
                pulse = PulseInfo(start: Date(), ms: fallbackPulseMs,
                                  burst: fallbackBurst, gap: fallbackGap)
            }
        } else {
            pulse = nil
        }

        updateAnimation()
        updateMenuTitles()
    }

    /// 只有需要闪的时候才开动画定时器，闲着不占 CPU
    private func updateAnimation() {
        if pulse != nil {
            guard animTimer == nil else { return }
            let t = Timer.scheduledTimer(timeInterval: animInterval, target: self,
                                         selector: #selector(animTick), userInfo: nil, repeats: true)
            RunLoop.current.add(t, forMode: .common)
            animTimer = t
        } else if let t = animTimer {
            t.invalidate()
            animTimer = nil
        }
    }

    @objc private func animTick() {
        // 菜单打开时不重绘，免得菜单跟着动
        if statusItem.menu != nil { return }
        // 亮/暗切换只有每 250ms 一次，中间帧算出来一模一样 → 直接跳过，
        // 否则 20fps 白烧 CPU（实测能到 18%）
        let ph = pulsePhase()
        let level = Int((ph.glow * 12).rounded())
        let sig = "\(state)|\(ph.on)|\(level)"
        guard sig != lastFrameKey else { return }
        lastFrameKey = sig
        applyDot()
        applyGlow()
    }

    /// 当前应该亮还是暗、发光多强。返回 (是否亮拍, 0–1 的发光强度)
    private func pulsePhase(now: Date = Date()) -> (on: Bool, glow: CGFloat) {
        guard let p = pulse else { return (true, 0) }
        let elapsedMs = now.timeIntervalSince(p.start) * 1000
        guard elapsedMs >= 0 else { return (true, 1) }
        let period = Double(p.periodMs)
        guard period > 0 else { return (true, 1) }
        let t = elapsedMs.truncatingRemainder(dividingBy: period)

        // 停顿段：设备把亮度停在高档，是「常亮」，不是熄灭
        if t >= Double(p.blinkSpanMs) { return (true, 1) }

        let half = Int(t) / max(p.ms, 1)
        let on = half % 2 == 0              // pulse-loop 先写 high，所以偶数半拍是亮
        return (on, on ? 1 : 0)
    }

    private func render(force: Bool = false) {
        // 菜单打开期间不改按钮标题：宽度一变，菜单可能跟着漂
        if !force && statusItem.menu != nil { return }
        // 定位期由 locateTick 独占标题，这里不要抢
        if isLocating {
            applyLength()
            applyDot()
            return
        }
        let st = style(for: state)
        let key = "\(state)|\(iconOnly)"
        if !force && key == lastTitleKey {
            applyDot()
            applyGlow()
            return
        }
        lastTitleKey = key

        // 文字用 button.title（系统自动跟菜单栏明暗走），颜色只体现在圆点上。
        // 之前用 attributedTitle 同时管颜色，结果深色菜单栏上 labelColor 被算成黑色，
        // 文字几乎看不见——只剩圆点。拆开后就两种都正常了。
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.title = iconOnly ? "" : " " + st.short
        applyLength()
        statusItem.button?.alphaValue = 1.0
        statusItem.button?.toolTip = tooltip(for: st)
        applyDot(force: true)
        // 标题刚改过，宽度可能变了：下一轮 runloop 再贴光带，拿到的是新 frame
        DispatchQueue.main.async { [weak self] in self?.applyGlow() }
    }

    /// 只更新圆点（发光强弱），不碰标题，所以按钮宽度恒定
    /// 只在按钮左侧占一个 20pt 的空位，真正的圆点画在它上面的图层里。
    /// 占位图只赋一次，之后不再碰 button.image —— 这是省下那 7% 的关键。
    private func installDotLayer() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        button.imageScaling = .scaleNone
        button.imagePosition = .imageLeft

        let ph = NSImage(size: NSSize(width: 20, height: 20))
        ph.isTemplate = false
        dotPlaceholder = ph
        button.image = ph

        let layer = CALayer()
        layer.contentsGravity = .resize
        layer.contentsScale = 2
        layer.magnificationFilter = .linear
        layer.frame = CGRect(x: 2, y: (button.bounds.height - 20) / 2, width: 20, height: 20)
        button.layer?.addSublayer(layer)
        dotLayer = layer
    }

    /// 更新圆点图层。不再走 Core Animation 关键帧：图层属性和光带都由
    /// 同一个 pulsePhase() 现算，天然同拍；改图层属性也不会触发状态项重排。
    private func applyDot(force: Bool = false) {
        guard let layer = dotLayer else { return }
        let st = style(for: state)

        // 定位期统一换成高对比靶心：不管原来是什么状态色，都变成最容易认出的形状
        let locating = isLocating
        let contentsKey = locating ? "locate" : "\(state)|\(st.hollow)"
        if force || contentsKey != lastDotContentsKey {
            lastDotContentsKey = contentsKey
            if locating {
                layer.contents = makeLocateCGImage()
            } else {
                layer.contents = makeDotCGImage(color: st.color, hollow: st.hollow,
                                                glow: st.hollow ? 0 : 1)
            }
        }
        if locating { return }

        let on = st.blink ? pulsePhase().on : true
        let opacity: Float = on ? 1.0 : 0.26
        let scale: CGFloat = on ? 1.0 : 0.72
        let key = "\(state)|\(on)"
        if !force && key == lastDotKey { return }
        lastDotKey = key

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    /// 画一颗圆点，可选一圈同色内发光（由内向外衰减的光晕）。
    /// 直接画进 2 倍像素的 CGContext：图层 contentsScale=2，位图必须给足分辨率，
    /// 否则在 Retina 上会糊。
    private func makeDotCGImage(color: NSColor, hollow: Bool, glow: CGFloat) -> CGImage? {
        let pt: CGFloat = 20
        let scale: CGFloat = 2
        let px = Int(pt * scale)
        guard let ctx = CGContext(data: nil, width: px, height: px,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setShouldAntialias(true)

        let cg = color.usingColorSpace(.sRGB) ?? color
        let core: CGFloat = hollow ? 9 : 11
        let c = CGPoint(x: pt / 2, y: pt / 2)

        // 光晕：从核心边缘往外交叠若干层半透明圆，越外越淡
        if glow > 0.01 && !hollow {
            let haloR = pt / 2 - 0.5
            let coreR = core / 2
            let steps = 14
            for k in 0..<steps {
                let frac = CGFloat(k) / CGFloat(steps - 1)
                let r = coreR + (haloR - coreR) * frac
                let a = glow * 0.24 * pow(1 - frac, 1.7)
                guard a > 0.002 else { continue }
                ctx.setFillColor(cg.withAlphaComponent(a).cgColor)
                ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
        }

        let r = core / 2
        let rect = CGRect(x: c.x - r + 0.5, y: c.y - r + 0.5, width: core - 1, height: core - 1)
        if hollow {
            ctx.setStrokeColor(cg.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: rect)
        } else {
            let coreColor = glow > 0.5
                ? (cg.blended(withFraction: 0.32, of: .white) ?? cg)
                : cg
            ctx.setFillColor(coreColor.cgColor)
            ctx.fillEllipse(in: rect)
        }

        return ctx.makeImage()
    }

    /// 定位用的靶心：红色外环 + 白色中环 + 红色实心中心。
    /// 形状和普通圆点差异极大，在很小的缩略图里也能一眼分辨。
    private func makeLocateCGImage() -> CGImage? {
        let pt: CGFloat = 20
        let scale: CGFloat = 2
        let px = Int(pt * scale)
        guard let ctx = CGContext(data: nil, width: px, height: px,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setShouldAntialias(true)

        let red = NSColor(srgbRed: 1.0, green: 0.20, blue: 0.16, alpha: 1)
        let c = CGPoint(x: pt / 2, y: pt / 2)

        // 外环
        ctx.setStrokeColor(red.cgColor)
        ctx.setLineWidth(2.6)
        ctx.strokeEllipse(in: CGRect(x: 1.4, y: 1.4, width: pt - 2.8, height: pt - 2.8))
        // 白色中环
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.4)
        ctx.strokeEllipse(in: CGRect(x: 4.4, y: 4.4, width: pt - 8.8, height: pt - 8.8))
        // 中心实心
        ctx.setFillColor(red.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 2.2, y: c.y - 2.2, width: 4.4, height: 4.4))

        return ctx.makeImage()
    }

    private func tooltip(for st: Style) -> String {
        var lines = ["Proma：\(st.full)"]
        if !detail.isEmpty { lines.append(detail) }
        if let updated {
            lines.append("更新于 \(hhmmss.string(from: updated))")
        }
        if pulse != nil {
            lines.append("与麦克风灯同频闪烁")
        }
        if state == "offline" {
            lines.append("灯光桥接可能没有运行，菜单里可以重载")
        }
        return lines.joined(separator: "\n")
    }

    private func updateMenuTitles() {
        let st = style(for: state)
        let when = updated.map { " · " + hhmmss.string(from: $0) } ?? ""
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
        glowItem.state = glowEnabled ? .on : .off
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

    // MARK: 自愈

    /// 菜单栏收纳工具（Barbee 等）或系统溢出会把项藏成「窗口高度 0」，
    /// 而且藏完不一定会把它登记回自己的清单——用户两头都看不见。
    /// 这里每轮自检：连续几轮不可见就销毁重建一次，重建的项会被当作「新项」重新走安置流程。
    private var hiddenTicks = 0
    private var lastRevive = Date.distantPast

    private func reviveIfHidden() {
        guard let win = statusItem.button?.window else {
            hiddenTicks += 1
            maybeRevive()
            return
        }
        // 高度为 0 或窗口宽高非正 = 不在菜单栏上
        let visible = win.frame.height > 1 && win.frame.width > 1 && win.isVisible
        if visible {
            hiddenTicks = 0
        } else {
            hiddenTicks += 1
            maybeRevive()
        }
    }

    private func maybeRevive() {
        // 约 3 秒不可见才动手，避免误判启动瞬间的布局过程；两次重建至少隔 20 秒
        guard hiddenTicks >= 6, Date().timeIntervalSince(lastRevive) > 20 else { return }
        lastRevive = Date()
        hiddenTicks = 0
        rebuildStatusItem()
    }

    private func rebuildStatusItem() {
        NSStatusBar.system.removeStatusItem(statusItem)
        dotLayer = nil
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "com.proma.vibekey-menubar.item"
        statusItem.button?.alignment = .center
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        measureLengths()
        installDotLayer()
        lastTitleKey = ""
        lastDotContentsKey = ""
        lastDotKey = ""
        lastGlowKey = ""
        render(force: true)
    }

    // MARK: 定位（在收纳栏里认出自己）

    @objc private func startLocate() {
        locateUntil = Date().addingTimeInterval(locateSeconds)
        locateBlink = false
        lastTitleKey = ""
        render(force: true)

        locateTimer?.invalidate()
        let t = Timer.scheduledTimer(timeInterval: 0.22, target: self,
                                     selector: #selector(locateTick), userInfo: nil, repeats: true)
        RunLoop.current.add(t, forMode: .common)
        locateTimer = t
    }

    @objc private func locateTick() {
        guard isLocating else { stopLocate(); return }
        locateBlink.toggle()
        // 定位期整条项都在跳，所以改标题（宽度已按 locateLength 预留，不会挤到别人）
        statusItem.button?.title = " " + (locateBlink ? locateLabel : "       ")
        statusItem.button?.alphaValue = locateBlink ? 1.0 : 0.35
        // 圆点同期换成醒目的靶心
        applyDot(force: true)
    }

    private func stopLocate() {
        locateTimer?.invalidate()
        locateTimer = nil
        locateUntil = nil
        locateBlink = false
        statusItem.button?.alphaValue = 1.0
        lastTitleKey = ""
        lastDotContentsKey = ""
        render(force: true)
    }

    @objc private func toggleGlow() {
        glowEnabled.toggle()
        updateMenuTitles()
    }

    // MARK: 下沿外发光

    /// 当前状态应该给多强的光带。闪灯状态跟着节拍走，干活中给一层很淡的底光，
    /// 空闲/收尾/暂停/离线一律不给——那些是“没事故”的时候，屏幕应该安静。
    private func glowIntensity() -> CGFloat {
        guard glowEnabled else { return 0 }
        let st = style(for: state)
        if st.blink {
            let ph = pulsePhase()
            return ph.on ? 1.0 : 0.18
        }
        switch state {
        case "thinking", "working":
            return 0.32
        default:
            return 0
        }
    }

    private func applyGlow() {
        let intensity = glowIntensity()
        guard intensity > 0.01, let btn = statusItem.button, let win = btn.window else {
            if glowPanel?.isVisible == true { glowPanel?.orderOut(nil) }
            lastGlowKey = ""
            return
        }

        let bf = win.frame                     // 屏幕坐标（原点左下）
        // 刚启动/刚重建时窗口 frame 还不可信（实测会拿到高 0 或跑到屏幕外），
        // 这种情况宁可不画，免得在屏幕边缘留一道无主的紫光
        guard bf.height > 1, bf.width > 1,
              let screen = win.screen else {
            glowPanel?.orderOut(nil)
            return
        }
        let vf = screen.visibleFrame
        // 只在状态项确实挂在屏幕顶部（菜单栏位置）时才贴光带。
        // 全屏应用里菜单栏是自动隐藏的，状态项窗口会被挪走，此时若仍然画，
        // 屏幕顶上就会飘一条没主的紫光。
        guard bf.intersects(screen.frame),
              bf.minY > screen.frame.midY,
              bf.maxY <= screen.frame.maxY + 1 else {
            glowPanel?.orderOut(nil)
            lastGlowKey = ""
            return
        }

        let pad: CGFloat = 16
        let h: CGFloat = 18
        var frame = NSRect(x: bf.minX - pad,
                           y: bf.minY - h,          // 从菜单栏下沿往下长
                           width: bf.width + pad * 2,
                           height: h)
        // 项贴在屏幕最右侧时，光带会超出屏幕被硬切 → 夹进屏幕内
        if frame.maxX > vf.maxX { frame.origin.x = vf.maxX - frame.width }
        if frame.minX < vf.minX { frame.origin.x = vf.minX }

        if glowPanel == nil { makeGlowPanel(frame: frame) }
        guard let panel = glowPanel, let view = glowView else { return }

        // 只在真正变化时重绘：否则 20fps 下每帧都触发合成，后台 App 白白吃 CPU
        let color = style(for: state).color
        let key = "\(color.description)|\(String(format: "%.2f", intensity))|\(frame)"
        if key != lastGlowKey {
            lastGlowKey = key
            view.color = color
            view.intensity = intensity
            view.needsDisplay = true
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
        }

        if ProcessInfo.processInfo.environment["PROMAC_MENUBAR_DEBUG"] == "1" {
            let line = "glow: intensity=\(String(format: "%.2f", intensity)) "
                + "item=\(bf) panel=\(panel.frame) visible=\(panel.isVisible)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    private func makeGlowPanel(frame: NSRect) {
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .ignoresCycle, .fullScreenAuxiliary]

        let view = GlowView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view

        glowPanel = panel
        glowView = view
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
