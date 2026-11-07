// ClawdSnip — 常驻最前的迷你像素 Clawd 悬浮窗
//
//  · 平时：小 Clawd 在一小块地方里自己散步、吃点心、东张西望、打盹；点击会穿透，不挡字
//  · 悬停：Clawd 小跳一下、扭扭脚、红着脸露出害羞的表情，并朝屏幕上有空间的一侧弹出像素风菜单
//  · 省电：只在走路/吃东西时按 tickHz 刷新；发呆只在下次眨眼时醒，睡觉时一直不醒；
//          锁屏、显示器睡眠、截图时完全停；低电量模式下只发呆和打盹
//  · 单击 Clawd：直接框选截图（Claude 自动隐藏 → 框选 → 回到 Claude 并粘贴进输入框）
//  · 拖动 Clawd：移动位置（会记住）
//
// 想加新功能？只改下面的 buildMenu() —— 往数组里加一个 MenuItem 即可。
// 想调散步范围 / 动画帧率？改 walkSlack / tickHz。

import Cocoa
import ApplicationServices
import CoreGraphics

// MARK: - 菜单（在这里添加新功能）

@MainActor
func buildMenu() -> [MenuItem] {
    [
        MenuItem(title: "框选截图", icon: Icons.region) { $0.capture(.region) },
        MenuItem(title: "窗口截图", icon: Icons.window) { $0.capture(.window) },
        MenuItem(title: "录屏…", icon: Icons.record) { $0.showRecording() },
        MenuItem.toggle(title: "自动粘贴", icon: Icons.paste,
                        isOn: { Prefs.autoPaste }, flip: { Prefs.autoPaste.toggle() }),
        .separator,
        MenuItem(title: "设置…", icon: Icons.settings) { $0.showSettings() },
        MenuItem(title: "隐藏宠物", icon: Icons.hide) { $0.setPetVisible(false) },
        MenuItem(title: "退出", icon: Icons.quit) { _ in NSApp.terminate(nil) },
    ]
}

// MARK: - 常量与偏好

let claudeBundleID = "com.anthropic.claudefordesktop"
let idleAlpha: CGFloat = 0.85

let clawdUnit: CGFloat = 2     // 一个像素格 2pt（Retina 上正好 4 个物理像素），和 Claude 桌面版里的 Clawd 差不多大
let walkSlack: CGFloat = 10 * clawdUnit  // 散步范围：左右总共 10 格，够看出在动，又不夸张
let tickHz: Double = 8         // 动起来时的帧率；不动时不醒、不重绘
let headroom: CGFloat = clawdUnit  // 头顶只留小跳一下（1 格）的空间
let stagePad: CGFloat = 2
let artSize = NSSize(width: 18 * clawdUnit, height: 10 * clawdUnit)  // 36 × 20
let stageSize = NSSize(width: artSize.width + walkSlack + stagePad * 2,
                       height: artSize.height + headroom + stagePad * 2)

enum Palette {
    static let accent = NSColor(srgbRed: 215 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1) // Clawd 橙
    static let bg = NSColor(srgbRed: 0.106, green: 0.102, blue: 0.096, alpha: 0.97)
    static let border = NSColor(srgbRed: 0.27, green: 0.26, blue: 0.245, alpha: 1)
    static let text = NSColor(srgbRed: 0.92, green: 0.905, blue: 0.87, alpha: 1)
    static let dim = NSColor(srgbRed: 0.52, green: 0.50, blue: 0.47, alpha: 1)
    static let ink = NSColor(srgbRed: 0.10, green: 0.09, blue: 0.08, alpha: 1)
    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

enum Prefs {
    static var autoPaste: Bool {
        get { UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoPaste") }
    }
}

// MARK: - 像素小物件

enum Icons { // 菜单图标 7×7
    static let region = ["###.###", "#.....#", "#.....#", ".......", "#.....#", "#.....#", "###.###"]
    static let window = ["#######", "#######", "#.....#", "#.....#", "#.....#", "#.....#", "#######"]
    static let paste = ["..###..", "#######", "#.....#", "#.###.#", "#.....#", "#.##..#", "#######"]
    static let record = ["..###..", ".#####.", "#######", "#######", "#######", ".#####.", "..###.."]
    static let settings = ["..#.#..", ".#####.", "##...##", ".#.#.#.", "##...##", ".#####.", "..#.#.."]
    static let hide = [".......", ".#####.", "#.....#", "#..#..#", "#.....#", ".#####.", "......."]
    static let quit = ["#.....#", ".#...#.", "..#.#..", "...#...", "..#.#..", ".#...#.", "#.....#"]
}

/// Clawd 的点心
enum Food: CaseIterable {
    case cookie, fish, apple

    /// 朝右摆（Clawd 在左边吃）时的样子；朝左时镜像
    var rows: [String] {
        switch self {
        case .cookie: return [".aa.", "abaa", "aaba", ".aa."]
        case .fish: return [".aa.a", "baaaa", ".aa.a"]
        case .apple: return ["..b.", ".aa.", "aaaa", "aaaa", ".aa."]
        }
    }

    var colors: [Character: NSColor] {
        switch self {
        case .cookie: return ["a": Palette.rgb(201, 139, 79), "b": Palette.rgb(91, 58, 34)]
        case .fish: return ["a": Palette.rgb(141, 179, 217), "b": Palette.ink]
        case .apple: return ["a": Palette.rgb(214, 74, 66), "b": Palette.rgb(125, 179, 106)]
        }
    }

    var width: Int { rows[0].count }
}

// MARK: - 绘制工具

/// 半透明也正确叠加的矩形填充（NSRect.fill 是 copy 模式）
func px(_ r: NSRect) { r.fill(using: .sourceOver) }

/// 对齐到物理像素（Retina 上 0.5pt）
func snapHalf(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }

/// 四角各缺一个“像素”的矩形——像素风的圆角
func notchedFill(_ r: NSRect, notch n: CGFloat) {
    px(NSRect(x: r.minX + n, y: r.minY, width: r.width - 2 * n, height: r.height))
    px(NSRect(x: r.minX, y: r.minY + n, width: n, height: r.height - 2 * n))
    px(NSRect(x: r.maxX - n, y: r.minY + n, width: n, height: r.height - 2 * n))
}

/// 深色面板 + 1pt 边框，四角是一级像素台阶
func drawPixelFrame(_ b: NSRect) {
    let x = b.minX, y = b.minY, w = b.width, h = b.height
    Palette.bg.setFill()
    px(NSRect(x: x + 1, y: y + 2, width: w - 2, height: h - 4))
    px(NSRect(x: x + 2, y: y + 1, width: w - 4, height: 1))
    px(NSRect(x: x + 2, y: y + h - 2, width: w - 4, height: 1))
    Palette.border.setFill()
    px(NSRect(x: x + 2, y: y, width: w - 4, height: 1))
    px(NSRect(x: x + 2, y: y + h - 1, width: w - 4, height: 1))
    px(NSRect(x: x, y: y + 2, width: 1, height: h - 4))
    px(NSRect(x: x + w - 1, y: y + 2, width: 1, height: h - 4))
    for (cx, cy) in [(x + 1, y + 1), (x + w - 2, y + 1), (x + 1, y + h - 2), (x + w - 2, y + h - 2)] {
        px(NSRect(x: cx, y: cy, width: 1, height: 1))
    }
}

/// 把一行里连续相同的字符合并成一段，整段一次画出（避免像素格之间漏缝）
func runs(_ row: String) -> [(start: Int, length: Int, ch: Character)] {
    var out: [(Int, Int, Character)] = []
    for (i, ch) in row.enumerated() {
        if let last = out.last, last.2 == ch, last.0 + last.1 == i {
            out[out.count - 1].1 += 1
        } else {
            out.append((i, 1, ch))
        }
    }
    return out.map { (start: $0.0, length: $0.1, ch: $0.2) }
}

/// 画单色小图标（flipped 坐标，第一行在上）
func drawPixels(_ rows: [String], at o: NSPoint, unit u: CGFloat, color: NSColor) {
    color.setFill()
    for (r, row) in rows.enumerated() {
        for run in runs(row) where run.ch == "#" {
            px(NSRect(x: o.x + CGFloat(run.start) * u, y: o.y + CGFloat(r) * u, width: CGFloat(run.length) * u, height: u))
        }
    }
}

/// 画多色小精灵，带 1pt 深色描边（浅色、深色背景上都看得清）；cols 限定画哪些列（被咬掉的就不画）
func drawSprite(_ rows: [String], at o: NSPoint, unit u: CGFloat, colors: [Character: NSColor],
                outline: NSColor?, cols: Range<Int>? = nil) {
    func cells(_ body: (NSRect, Character) -> Void) {
        for (r, row) in rows.enumerated() {
            for run in runs(row) where run.ch != "." {
                var lo = run.start, hi = run.start + run.length
                if let cols { lo = max(lo, cols.lowerBound); hi = min(hi, cols.upperBound) }
                guard lo < hi else { continue }
                body(NSRect(x: o.x + CGFloat(lo) * u, y: o.y + CGFloat(r) * u, width: CGFloat(hi - lo) * u, height: u), run.ch)
            }
        }
    }
    if let outline {
        outline.setFill()
        cells { rect, _ in px(rect.insetBy(dx: -1, dy: -1)) }
    }
    cells { rect, ch in (colors[ch] ?? Palette.accent).setFill(); px(rect) }
}

// MARK: - Clawd 本体

/// Clawd 的脸
enum Face: Equatable {
    case normal
    case blink      // 眨眼
    case happy      // ^ ^ 吃饱了
    case sleep      // — — 打盹
    case surprised  // 被叫醒，眼睛睁大
    case shyHappy   // ^ ^ + 脸红
    case shyAway    // 红着脸看别处
    case shyXX      // > < + 脸红

    var isShy: Bool { self == .shyHappy || self == .shyAway || self == .shyXX }
    static let shyFaces: [Face] = [.shyHappy, .shyAway, .shyXX]
}

struct Pose: Equatable {
    var face: Face = .normal
    var look = 0   // -1 往左看，0 正视，1 往右看
    var legs = 0   // 0 站着；1、2 交替抬腿
}

let blushColor = Palette.rgb(247, 165, 160)

/// 画 Clawd：身体 18 列 × 5 行，每行高 2 格（还原终端里半块字符的比例）；脸按 1 格精度画。o 为左上角，flipped 坐标
func drawClawd(at o: NSPoint, unit u: CGFloat, pose: Pose, body: NSColor, eye: NSColor) {
    func dot(_ x: Int, _ y: Int, _ w: Int = 1, _ h: Int = 1) {
        px(NSRect(x: o.x + CGFloat(x) * u, y: o.y + CGFloat(y) * u, width: CGFloat(w) * u, height: CGFloat(h) * u))
    }
    // 身体和两只手各画成一整块，任何缩放下都不会出现行间细缝
    body.setFill()
    dot(3, 0, 12, 8)
    dot(1, 4, 16, 2)

    let l = pose.look
    eye.setFill()
    switch pose.face {
    case .normal, .shyAway: dot(5 + l, 2, 1, 2); dot(12 + l, 2, 1, 2)
    case .blink: dot(5 + l, 3); dot(12 + l, 3)
    case .sleep: dot(4, 3, 2, 1); dot(12, 3, 2, 1)
    case .surprised: dot(5, 1, 1, 3); dot(12, 1, 1, 3)
    case .happy, .shyHappy: dot(5, 2); dot(4, 3); dot(6, 3); dot(12, 2); dot(11, 3); dot(13, 3)
    case .shyXX: dot(4, 1); dot(5, 2); dot(4, 3); dot(13, 1); dot(12, 2); dot(13, 3)
    }
    if pose.face.isShy {
        blushColor.setFill()
        dot(3, 4, 2, 1); dot(13, 4, 2, 1)
    }

    body.setFill()
    for (i, c) in [4, 6, 11, 13].enumerated() {
        let lifted = (pose.legs == 1 && i % 2 == 0) || (pose.legs == 2 && i % 2 == 1)
        dot(c, 7, 1, lifted ? 2 : 3) // 从身体里多画一格，接缝藏在身体里
    }
}

struct Meal: Equatable {
    var food: Food
    var side: Int    // 1 = 点心在右边，-1 = 在左边
    var bitten = 0   // 已经咬掉几列
}

/// 一帧画面里的全部状态
struct Scene: Equatable {
    var offset: CGFloat = 0   // 在散步范围里的位置
    var lean: CGFloat = 0     // 咬东西时往前探
    var hop: CGFloat = 0      // 跳起的高度
    var pose = Pose()
    var meal: Meal? = nil
}

/// Clawd 的小日常：闲着 → 散步 / 吃点心 / 东张西望 / 打盹 → 闲着……
///
/// 省电的关键：advance(dt) 一次前进 dt 个 tick，并返回“下一次画面要变是几个 tick 之后”。
/// 控制器按这个值只定一次闹钟，中间完全不醒；发呆时一两秒才醒一次，睡觉时直到睡醒都不醒。
@MainActor
final class ClawdLife {
    private(set) var scene = Scene()
    private enum Act { case idle, walk, eat, look, sleep, happy, greet }
    private var act: Act = .idle
    private var t = 0
    private var until = 40
    private var blinkAt = 20, blinkOpenAt = -1
    private var stepAt = 0
    private var nextBite = 0, leanBackAt = -1
    private var lookSwitch = -1
    private var hopDownAt = -1
    private var fidgetAt = -1, fidgetLeft = 0
    private var surprisedUntil = -1
    private var shyFace: Face = .shyHappy
    private var target: CGFloat = 0
    private var eatAfterWalk = false
    private var mealSide = 1

    init() { scene.offset = snap(walkSlack / 2) }

    /// 正在走动（身体位置会变，需要顺带检查鼠标是否落在它身上）
    var isMoving: Bool { act == .walk }

    private func snap(_ x: CGFloat) -> CGFloat { (x / clawdUnit).rounded() * clawdUnit }
    private func rnd(_ r: ClosedRange<Int>) -> Int { Int.random(in: r) }
    private func begin(_ a: Act, ticks: Int) { act = a; until = t + ticks }
    /// 离现在最近的一个未来时刻还有几个 tick；没有就 10 秒后再看
    private func wake(_ times: Int...) -> Int { times.filter { $0 > t }.min().map { $0 - t } ?? Int(tickHz * 10) }

    /// 鼠标移上来 / 移开
    func hover(began: Bool, mouseOnRight: Bool) {
        if began {
            let wasAsleep = act == .sleep
            act = .greet
            scene.meal = nil
            scene.lean = 0
            shyFace = Face.shyFaces.randomElement() ?? .shyHappy
            scene.pose = Pose(face: wasAsleep ? .surprised : shyFace, look: 0, legs: 0)
            lookToward(right: mouseOnRight)
            surprisedUntil = wasAsleep ? t + 5 : -1
            scene.hop = clawdUnit
            hopDownAt = t + 2
            fidgetLeft = 4 // 害羞地扭两下脚
            fidgetAt = t + 2
            blinkOpenAt = -1
        } else {
            scene.hop = 0
            scene.pose = Pose()
            hopDownAt = -1
            fidgetLeft = 0
            surprisedUntil = -1
            begin(.idle, ticks: rnd(24...56))
        }
    }

    /// 悬停时：看别处的那种表情就躲开鼠标，其它就看着鼠标
    func lookToward(right: Bool) {
        guard act == .greet else { return }
        let toward = right ? 1 : -1
        scene.pose.look = scene.pose.face == .shyAway ? -toward : toward
    }

    func advance(_ dt: Int) -> Int {
        t += dt
        switch act {
        case .greet:
            if hopDownAt >= 0, t >= hopDownAt { scene.hop = 0; hopDownAt = -1 }
            if surprisedUntil >= 0, t >= surprisedUntil { scene.pose.face = shyFace; surprisedUntil = -1 }
            if fidgetLeft > 0, t >= fidgetAt {
                fidgetLeft -= 1
                scene.pose.legs = fidgetLeft == 0 ? 0 : (scene.pose.legs == 1 ? 2 : 1)
                fidgetAt = t + 2
            }
            return wake(hopDownAt, surprisedUntil, fidgetLeft > 0 ? fidgetAt : -1)

        case .idle:
            blinkStep()
            if t >= until { chooseNext(); return 1 }
            return wake(until, blinkAt, blinkOpenAt)

        case .walk:
            blinkStep()
            if t >= stepAt {
                let d = target - scene.offset
                if abs(d) < 0.01 {
                    scene.pose.legs = 0
                    if eatAfterWalk { startEating() } else { begin(.idle, ticks: rnd(40...96)) }
                    return 1
                }
                scene.offset = snap(scene.offset + (d > 0 ? clawdUnit : -clawdUnit))
                scene.pose.look = d > 0 ? 1 : -1
                scene.pose.legs = scene.pose.legs == 1 ? 2 : 1
                stepAt = t + 2
            }
            return wake(stepAt, blinkAt, blinkOpenAt)

        case .eat:
            guard var meal = scene.meal else { begin(.idle, ticks: 40); return 1 }
            if leanBackAt >= 0, t >= leanBackAt { scene.lean = 0; leanBackAt = -1 }
            if t >= nextBite {
                if meal.bitten >= meal.food.width {
                    scene.meal = nil
                    scene.lean = 0
                    startHappy()
                    return 1
                }
                meal.bitten += 1
                scene.meal = meal
                scene.lean = clawdUnit
                leanBackAt = t + 2
                nextBite = t + 4
            }
            return wake(nextBite, leanBackAt)

        case .look:
            if lookSwitch >= 0, t >= lookSwitch { scene.pose.look = -scene.pose.look; lookSwitch = -1 }
            if t >= until { scene.pose.look = 0; begin(.idle, ticks: rnd(32...72)); return 1 }
            return wake(lookSwitch, until)

        case .sleep:
            if t >= until { scene.pose.face = .normal; begin(.idle, ticks: rnd(40...80)); return 1 }
            return until - t // 睡着时一直不醒

        case .happy:
            if hopDownAt >= 0, t >= hopDownAt { scene.hop = 0; hopDownAt = -1 }
            if t >= until { scene.pose.face = .normal; begin(.idle, ticks: rnd(48...96)); return 1 }
            return wake(hopDownAt, until)
        }
    }

    private func blinkStep() {
        if blinkOpenAt >= 0 {
            if t >= blinkOpenAt {
                if scene.pose.face == .blink { scene.pose.face = .normal }
                blinkOpenAt = -1
                blinkAt = t + rnd(24...56)
            }
        } else if t >= blinkAt, scene.pose.face == .normal {
            scene.pose.face = .blink
            blinkOpenAt = t + 1
        }
    }

    private func chooseNext() {
        let r = Double.random(in: 0..<1)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { // 低电量：只发呆、打盹
            if r < 0.5 { begin(.idle, ticks: rnd(80...160)) } else { startSleep() }
            return
        }
        if r < 0.42 { // 散步
            var x = snap(CGFloat.random(in: 0...walkSlack))
            if abs(x - scene.offset) < clawdUnit * 3 { x = scene.offset > walkSlack / 2 ? 0 : snap(walkSlack) }
            walk(to: x, thenEat: false)
        } else if r < 0.62 { // 走到一头，转身吃点心
            let atLeft = scene.offset <= walkSlack / 2
            mealSide = atLeft ? 1 : -1
            walk(to: atLeft ? 0 : snap(walkSlack), thenEat: true)
        } else if r < 0.84 { // 东张西望
            act = .look
            scene.pose.face = .normal
            scene.pose.look = Bool.random() ? 1 : -1
            lookSwitch = t + rnd(8...14)
            until = lookSwitch + rnd(8...14)
        } else {
            startSleep()
        }
    }

    private func startSleep() {
        act = .sleep
        scene.pose = Pose(face: .sleep, look: 0, legs: 0)
        until = t + rnd(64...160)
    }

    private func walk(to x: CGFloat, thenEat: Bool) {
        target = x
        eatAfterWalk = thenEat
        act = .walk
        stepAt = t + 1
    }

    private func startEating() {
        eatAfterWalk = false
        act = .eat
        scene.pose = Pose(face: .normal, look: mealSide, legs: 0)
        scene.meal = Meal(food: Food.allCases.randomElement() ?? .cookie, side: mealSide)
        nextBite = t + 8 // 先盯着看一会儿
        leanBackAt = -1
    }

    private func startHappy() {
        act = .happy
        scene.pose.face = .happy
        scene.hop = clawdUnit
        hopDownAt = t + 2
        until = t + 14
    }
}

// MARK: - 菜单项

struct MenuItem {
    enum Kind { case action, toggle, separator }
    var kind: Kind = .action
    var title = ""
    var icon: [String] = []
    var isOn: (() -> Bool)? = nil
    var run: ((Controller) -> Void)? = nil

    init(kind: Kind = .action, title: String = "", icon: [String] = [],
         isOn: (() -> Bool)? = nil, run: ((Controller) -> Void)? = nil) {
        self.kind = kind; self.title = title; self.icon = icon; self.isOn = isOn; self.run = run
    }

    init(title: String, icon: [String], run: @escaping (Controller) -> Void) {
        self.init(kind: .action, title: title, icon: icon, run: run)
    }

    static func toggle(title: String, icon: [String], isOn: @escaping () -> Bool, flip: @escaping () -> Void) -> MenuItem {
        MenuItem(kind: .toggle, title: title, icon: icon, isOn: isOn, run: { _ in flip() })
    }

    static let separator = MenuItem(kind: .separator)
}

// MARK: - 视图

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Clawd 活动的小舞台：透明，只画 Clawd 和点心。
/// 省电：窗口透明处的鼠标事件由系统直接交给下面的 App（不经过这里），
/// 只有鼠标碰到 Clawd 身上时系统才通知这里，所以平时动鼠标不会把它叫醒。
final class StageView: NSView {
    var scene = Scene() {
        didSet {
            guard scene != oldValue else { return }
            needsDisplay = true
            if scene.offset != oldValue.offset { updateTrackingAreas() }
        }
    }
    var onClick: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onPointer: (() -> Void)?
    private(set) var dragging = false
    private var pressed = false
    private var downAt = NSPoint.zero
    private var startOrigin = NSPoint.zero

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Clawd 站着时身体的位置（不含跳起和前探），用来判断鼠标是否在它身上
    var baseArtRect: NSRect {
        NSRect(x: stagePad + scene.offset, y: stagePad + headroom, width: artSize.width, height: artSize.height)
    }

    /// 能“摸到” Clawd 的范围：比身体大一圈，铺一层肉眼看不见的底色让系统把这块当成可点区域
    var hitRect: NSRect { baseArtRect.insetBy(dx: -2, dy: -2).intersection(bounds) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: hitRect, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onPointer?() }
    override func mouseExited(with event: NSEvent) { onPointer?() }
    override func mouseMoved(with event: NSEvent) { onPointer?() }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        dragging = false
        downAt = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        let dx = p.x - downAt.x, dy = p.y - downAt.y
        if !dragging {
            guard hypot(dx, dy) >= 3 else { return }
            dragging = true
            onDragStart?()
        }
        window?.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = dragging
        pressed = false
        dragging = false
        if wasDragging { onDragEnd?() } else { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let s = scene
        NSColor(white: 0, alpha: 0.012).setFill() // 看不见，但让这块能接住鼠标
        px(hitRect)
        let base = baseArtRect
        let art = base.offsetBy(dx: s.lean * CGFloat(s.meal?.side ?? 0), dy: -s.hop)
        drawClawd(at: art.origin, unit: clawdUnit, pose: s.pose, body: Palette.accent, eye: Palette.ink)

        if let meal = s.meal {
            var rows = meal.food.rows
            if meal.side < 0 { rows = rows.map { String($0.reversed()) } }
            let cols = meal.food.width
            let w = CGFloat(cols) * clawdUnit, h = CGFloat(rows.count) * clawdUnit
            let x = meal.side > 0 ? base.maxX : base.minX - w
            let visible = meal.side > 0 ? meal.bitten..<cols : 0..<(cols - meal.bitten)
            drawSprite(rows, at: NSPoint(x: x, y: base.maxY - h), unit: clawdUnit,
                       colors: meal.food.colors, outline: Palette.ink, cols: visible)
        }
    }
}

final class MenuView: NSView {
    static let width: CGFloat = 124
    static let rowH: CGFloat = 22
    static let sepH: CGFloat = 7
    static let padV: CGFloat = 4
    static let padH: CGFloat = 4

    var items: [MenuItem] = [] { didSet { needsDisplay = true } }
    var hovered: Int? { didSet { if oldValue != hovered { needsDisplay = true } } }
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onPick: ((MenuItem) -> Void)?

    static func height(for items: [MenuItem]) -> CGFloat {
        items.reduce(padV * 2) { $0 + ($1.kind == .separator ? sepH : rowH) }
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func rowRects() -> [NSRect] {
        var y = Self.padV
        return items.map { item in
            let h = item.kind == .separator ? Self.sepH : Self.rowH
            defer { y += h }
            return NSRect(x: Self.padH, y: y, width: bounds.width - Self.padH * 2, height: h)
        }
    }

    private func index(at p: NSPoint) -> Int? {
        for (i, r) in rowRects().enumerated() where items[i].kind != .separator && r.contains(p) { return i }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?(); mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil; onExit?() }
    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        onPick?(items[i])
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawPixelFrame(bounds)
        for (i, (item, r)) in zip(items, rowRects()).enumerated() {
            if item.kind == .separator {
                Palette.border.setFill()
                var x = r.minX + 6
                while x < r.maxX - 6 { px(NSRect(x: x, y: floor(r.midY), width: 1, height: 1)); x += 3 }
                continue
            }
            let hot = hovered == i
            if hot {
                Palette.accent.setFill()
                notchedFill(r, notch: 1.5)
            }
            let fg = hot ? Palette.ink : Palette.text
            drawPixels(item.icon, at: NSPoint(x: r.minX + 7, y: floor(r.midY - 5.25)), unit: 1.5, color: fg)
            let s = NSAttributedString(string: item.title, attributes: [.font: Palette.font, .foregroundColor: fg])
            s.draw(at: NSPoint(x: r.minX + 25, y: r.midY - s.size().height / 2))
            if item.kind == .toggle, let isOn = item.isOn {
                drawSwitch(on: isOn(), right: r.maxX - 7, midY: r.midY, hot: hot)
            }
        }
    }

    private func drawSwitch(on: Bool, right: CGFloat, midY: CGFloat, hot: Bool) {
        let u: CGFloat = 1.5
        let track = NSRect(x: right - 10 * u, y: floor(midY - 3 * u), width: 10 * u, height: 6 * u)
        (on ? (hot ? Palette.ink : Palette.accent) : (hot ? Palette.ink.withAlphaComponent(0.35) : Palette.border)).setFill()
        notchedFill(track, notch: u)
        let knob = NSRect(x: on ? track.maxX - 5 * u : track.minX + u, y: track.minY + u, width: 4 * u, height: 4 * u)
        (on ? (hot ? Palette.accent : Palette.ink) : (hot ? Palette.ink : Palette.dim)).setFill()
        px(knob)
    }
}

final class ToastView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    static func attributed(_ t: String) -> NSAttributedString {
        NSAttributedString(string: t, attributes: [.font: Palette.font, .foregroundColor: Palette.text])
    }

    static func size(for t: String) -> NSSize {
        NSSize(width: ceil(attributed(t).size().width) + 22, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawPixelFrame(bounds)
        Palette.accent.setFill()
        px(NSRect(x: 7, y: floor(bounds.midY - 1.5), width: 3, height: 3))
        let s = Self.attributed(text)
        s.draw(at: NSPoint(x: 14, y: (bounds.height - s.size().height) / 2))
    }
}

// MARK: - 控制器

enum CaptureMode {
    case region, window
    var args: [String] { self == .region ? ["-i", "-x"] : ["-i", "-W", "-x"] }
}

@MainActor
final class Controller: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel!
    private var stage: StageView!
    private let life = ClawdLife()
    private var menuPanel: FloatingPanel?
    private var menuView: MenuView?
    private var toastPanel: FloatingPanel?
    private var tickTimer: Timer?
    private var pendingTicks = 0
    private var lastAdvance: CFAbsoluteTime = 0
    private var hoverWatch: Timer? // 只在悬停期间运行：确认鼠标还在 Clawd 身上
    private var hovered = false
    private var paused = false
    private var hoverGen = 0, collapseGen = 0, menuGen = 0, toastGen = 0
    private var busy = false
    private var askedAccessibility = false
    private var askedScreenRecording = false
    private let recordingUI = RecordingUI()
    private var hotKeys: GlobalHotKeys?
    private var settingsUI: SettingsUI?
    private var statusMenu: AppStatusMenu?
    private var petVisible: Bool { UserDefaults.standard.object(forKey: "petVisible") as? Bool ?? true }

    func showSettings() {
        collapse(animated: false)
        settingsUI?.show()
    }

    func setPetVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: "petVisible")
        hoverGen += 1; collapse(animated: false)
        hovered = false
        hoverWatch?.invalidate(); hoverWatch = nil
        toastGen += 1; toastPanel?.orderOut(nil)
        tickTimer?.invalidate(); tickTimer = nil
        if visible && !busy { panel.orderFrontRegardless(); wakeLife() }
        else { panel.orderOut(nil) }
    }

    private func perform(_ action: AppAction) {
        switch action {
        case .region: capture(.region)
        case .window: capture(.window)
        case .recording:
            guard !busy else { return }
            collapse(animated: false)
            recordingUI.handleShortcut()
        case .quit: NSApp.terminate(nil)
        case .togglePet: setPetVisible(!petVisible)
        }
    }

    private func configureSettings() {
        do {
            let keys = try GlobalHotKeys()
            hotKeys = keys
            keys.onAction = { [weak self] in self?.perform($0) }
            settingsUI = SettingsUI(hotKeys: keys, getVisibility: { [weak self] in self?.petVisible ?? true }, setVisibility: { [weak self] in self?.setPetVisible($0) })
            try keys.restore()
        } catch {
            DispatchQueue.main.async {
                let alert = NSAlert(); alert.messageText = "快捷键未能全部启用"
                alert.informativeText = error.localizedDescription + "\n可在菜单栏 → 设置中修改。"
                alert.runModal()
            }
        }
        let menu = AppStatusMenu()
        menu.onAction = { [weak self] in self?.perform($0) }
        menu.onSettings = { [weak self] in self?.showSettings() }
        menu.isPetVisible = { [weak self] in self?.petVisible ?? true }
        menu.shortcuts = { [weak self] in self?.hotKeys?.bindings ?? [:] }
        statusMenu = menu
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        setPetVisible(true); showSettings(); return false
    }

    func applicationWillTerminate(_ notification: Notification) { hotKeys?.shutdown() }


    func showRecording() {
        guard !busy else { return }
        collapse(animated: false)
        recordingUI.show()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        recordingUI.shouldTerminate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != me.processIdentifier }) {
            NSApp.terminate(nil) // 已经开着一个了
            return
        }

        // 不设置 ignoresMouseEvents：透明处的点击由系统直接穿透给下面的 App
        panel = makePanel(NSRect(origin: savedOrigin() ?? defaultOrigin(), size: stageSize), passThroughClear: true)
        panel.hasShadow = false // 画面一直在变，不用窗口阴影
        stage = StageView(frame: NSRect(origin: .zero, size: stageSize))
        stage.scene = life.scene
        stage.onClick = { [weak self] in self?.capture(.region) }
        stage.onDragStart = { [weak self] in self?.collapse(animated: false) }
        stage.onDragEnd = { [weak self] in self?.saveOrigin(); self?.checkHover() }
        stage.onPointer = { [weak self] in self?.checkHover() }
        panel.contentView = stage
        panel.alphaValue = idleAlpha
        if petVisible { panel.orderFrontRegardless() }

        configureSettings()
        wakeLife()

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(pause), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(resume), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(pause), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(resume), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // 录屏权限不在启动时要，等第一次截图时再要
        toast("Clawd 就位 · 悬停展开")
        if CommandLine.arguments.contains("--recording-settings") { showRecording() }
        if CommandLine.arguments.contains("--settings") { showSettings() }
    }

    @objc private func pause() { paused = true; tickTimer?.invalidate(); tickTimer = nil }
    @objc private func resume() { paused = false; wakeLife() }

    private func makePanel(_ rect: NSRect, passThroughClear: Bool = false) -> FloatingPanel {
        let p = FloatingPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        if !passThroughClear { p.ignoresMouseEvents = false } // 显式设置后整个窗口都接鼠标
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }

    // MARK: 动画与悬停

    /// 把 Clawd 的时间推进到“现在”（可顺便改它的状态），再按它要求的时间只定一个闹钟。
    /// 发呆时一两秒才醒一次，睡觉时一直睡到醒；截图、锁屏、显示器睡眠时完全不醒。
    private func wakeLife(scheduled: Bool = false, change: (() -> Void)? = nil) {
        tickTimer?.invalidate()
        tickTimer = nil
        let now = CFAbsoluteTimeGetCurrent()
        var dt = 0
        if scheduled { dt = pendingTicks }
        else if lastAdvance > 0 { dt = min(pendingTicks, max(0, Int((now - lastAdvance) * tickHz))) }
        lastAdvance = now
        guard !busy, !paused, petVisible else { return }

        var next = life.advance(dt)
        if let change { change(); next = life.advance(0) }
        stage.scene = life.scene
        if life.isMoving, !stage.dragging { checkHover() } // Clawd 自己走到鼠标底下也算

        pendingTicks = max(1, next)
        let delay = Double(pendingTicks) / tickHz
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.wakeLife(scheduled: true) }
        }
        t.tolerance = min(0.3, delay * 0.1)
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    /// Clawd 身体在屏幕上的位置
    private func clawdScreenRect() -> NSRect {
        let r = stage.baseArtRect
        let f = panel.frame
        return NSRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    }

    private func checkHover() {
        guard !busy, petVisible, panel.isVisible, !stage.dragging else { return }
        let r = clawdScreenRect().insetBy(dx: -2, dy: -2)
        let m = NSEvent.mouseLocation
        let inside = r.contains(m)
        if inside != hovered { setHovered(inside) }
        if inside {
            life.lookToward(right: m.x > r.midX)
            stage.scene = life.scene
        }
    }

    private func setHovered(_ h: Bool) {
        hovered = h
        panel.alphaValue = h ? 1 : idleAlpha
        hoverWatch?.invalidate()
        hoverWatch = nil
        if h { // 万一系统没送“离开”事件，也能在 0.25 秒内发现鼠标走了
            let w = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkHover() }
            }
            w.tolerance = 0.1
            RunLoop.main.add(w, forMode: .common)
            hoverWatch = w
        }
        let onRight = NSEvent.mouseLocation.x > clawdScreenRect().midX
        wakeLife { [weak self] in self?.life.hover(began: h, mouseOnRight: onRight) }
        if h { pointerEntered() } else { pointerExited() }
    }

    // MARK: 位置

    private func defaultOrigin() -> NSPoint {
        let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vis.maxX - stageSize.width - 6, y: vis.minY + vis.height * 0.32)
    }

    private func savedOrigin() -> NSPoint? {
        let d = UserDefaults.standard
        guard d.object(forKey: "x") != nil else { return nil }
        var p = NSPoint(x: d.double(forKey: "x"), y: d.double(forKey: "y"))
        guard let vis = NSScreen.screens.first(where: { $0.visibleFrame.intersects(NSRect(origin: p, size: stageSize)) })?
            .visibleFrame else { return nil }
        p.x = min(max(p.x, vis.minX), vis.maxX - stageSize.width)
        p.y = min(max(p.y, vis.minY), vis.maxY - stageSize.height)
        return p
    }

    private func saveOrigin() {
        UserDefaults.standard.set(Double(panel.frame.minX), forKey: "x")
        UserDefaults.standard.set(Double(panel.frame.minY), forKey: "y")
    }

    @objc private func screensChanged() {
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            panel.setFrameOrigin(defaultOrigin())
        }
    }

    /// 弹出位置：左右哪边空间大就往哪边；左右都放不下再上下
    private func placement(for size: NSSize, gap: CGFloat) -> (rect: NSRect, dx: CGFloat, dy: CGFloat) {
        let f = clawdScreenRect()
        let vis = (panel.screen ?? NSScreen.main)?.visibleFrame ?? f
        let right = vis.maxX - f.maxX, left = f.minX - vis.minX
        let above = vis.maxY - f.maxY, below = f.minY - vis.minY
        var r = NSRect(origin: .zero, size: size)
        var dx: CGFloat = 0, dy: CGFloat = 0
        if max(left, right) >= size.width + gap {
            if right >= left { r.origin.x = f.maxX + gap; dx = 1 } else { r.origin.x = f.minX - gap - size.width; dx = -1 }
            r.origin.y = below >= above ? f.maxY - size.height : f.minY // 朝空的那头展开
        } else {
            if below >= above { r.origin.y = f.minY - gap - size.height; dy = -1 } else { r.origin.y = f.maxY + gap; dy = 1 }
            r.origin.x = right >= left ? f.minX : f.maxX - size.width
        }
        r.origin.x = min(max(r.origin.x, vis.minX + 2), vis.maxX - size.width - 2)
        r.origin.y = min(max(r.origin.y, vis.minY + 2), vis.maxY - size.height - 2)
        return (r, dx, dy)
    }

    // MARK: 悬停展开菜单

    private func pointerEntered() {
        guard !busy, petVisible, !stage.dragging else { return }
        collapseGen += 1
        if menuPanel?.isVisible == true { return }
        hoverGen += 1
        let gen = hoverGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.hoverGen == gen, self.hovered else { return }
            self.expand()
        }
    }

    private func pointerExited() {
        hoverGen += 1
        collapseGen += 1
        let gen = collapseGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            guard let self, self.collapseGen == gen else { return }
            self.collapse(animated: true)
        }
    }

    private func expand() {
        guard !busy, petVisible else { return }
        let items = buildMenu()
        let size = NSSize(width: MenuView.width, height: MenuView.height(for: items))
        let (target, dx, dy) = placement(for: size, gap: 4)

        if menuPanel == nil {
            let p = makePanel(target)
            let v = MenuView(frame: NSRect(origin: .zero, size: size))
            v.onEnter = { [weak self] in self?.pointerEntered() }
            v.onExit = { [weak self] in self?.pointerExited() }
            v.onPick = { [weak self] item in self?.pick(item) }
            p.contentView = v
            menuPanel = p
            menuView = v
        }
        guard let p = menuPanel, let v = menuView else { return }
        menuGen += 1
        toastPanel?.orderOut(nil)
        v.items = items
        v.hovered = nil
        p.setFrame(target.offsetBy(dx: -dx * 5, dy: -dy * 5), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            p.animator().setFrame(target, display: true)
        }
    }

    func collapse(animated: Bool) {
        hoverGen += 1
        collapseGen += 1
        guard let p = menuPanel, p.isVisible else { return }
        menuGen += 1
        let gen = menuGen
        if !animated { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; p.animator().alphaValue = 0 }) { [weak self] in
            DispatchQueue.main.async { if self?.menuGen == gen { p.orderOut(nil) } }
        }
    }

    private func pick(_ item: MenuItem) {
        if item.kind == .toggle {
            item.run?(self) // 开关：菜单不收起，原地刷新
            menuView?.needsDisplay = true
        } else {
            collapse(animated: false)
            item.run?(self)
        }
    }

    // MARK: 提示

    func toast(_ text: String, seconds: Double = 1.8) {
        guard petVisible, menuPanel?.isVisible != true else { return }
        toastGen += 1
        let gen = toastGen
        let (rect, _, _) = placement(for: ToastView.size(for: text), gap: 4)
        let p: FloatingPanel
        if let existing = toastPanel {
            p = existing
        } else {
            p = makePanel(rect)
            p.ignoresMouseEvents = true
            p.contentView = ToastView()
            toastPanel = p
        }
        (p.contentView as? ToastView)?.text = text
        p.setFrame(rect, display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.toastGen == gen else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; p.animator().alphaValue = 0 }) { [weak self] in
                DispatchQueue.main.async { if self?.toastGen == gen { p.orderOut(nil) } }
            }
        }
    }

    // MARK: 截图

    /// 没有录屏权限时：第一次让系统弹窗询问，之后直接打开对应的系统设置页面
    private func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !askedScreenRecording {
            askedScreenRecording = true
            _ = CGRequestScreenCaptureAccess()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        toast("需要录屏权限 · 打开后重开 ClawdSnip", seconds: 3.5)
        return false
    }

    func capture(_ mode: CaptureMode) {
        guard !busy, !recordingUI.isBusy else { toast("请先完成录屏"); return }
        guard ensureScreenRecording() else { return }
        collapse(animated: false)
        if hovered { setHovered(false) }
        busy = true
        tickTimer?.invalidate() // 截图期间 Clawd 不动
        tickTimer = nil
        toastPanel?.orderOut(nil)

        let claude = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first
        let claudeWasFront = claude?.isActive ?? false
        claude?.hide() // Claude 退到最底层（隐藏）
        panel.orderOut(nil) // 自己也别出现在截图里

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClawdSnip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("snip.png")
        try? FileManager.default.removeItem(at: file)
        let args = mode.args + [file.path]

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in // 等隐藏动画走完
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                proc.arguments = args
                do { try proc.run(); proc.waitUntilExit() } catch {}
                DispatchQueue.main.async {
                    self?.finishCapture(file: file, claude: claude, claudeWasFront: claudeWasFront)
                }
            }
        }
    }

    private func finishCapture(file: URL, claude: NSRunningApplication?, claudeWasFront: Bool) {
        busy = false
        panel.alphaValue = idleAlpha
        if petVisible { panel.orderFrontRegardless() }
        wakeLife()
        checkHover()

        guard let data = try? Data(contentsOf: file), !data.isEmpty else {
            // 按了 Esc 取消：把 Claude 恢复原样
            if let claude {
                claude.unhide()
                if claudeWasFront { bringToFront(claude) }
            }
            return
        }

        let pb = NSPasteboard.general
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(data, forType: .png)
        if let tiff = NSImage(data: data)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }

        guard let claude, !claude.isTerminated else { toast("已复制到剪贴板"); return }
        claude.unhide()
        bringToFront(claude)

        guard Prefs.autoPaste else { toast("已复制 · ⌘V 粘贴"); return }
        guard AXIsProcessTrusted() else {
            if !askedAccessibility {
                askedAccessibility = true
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            toast("已复制 · ⌘V 粘贴", seconds: 2.4)
            return
        }
        pasteWhenFront(claude, tries: 0)
    }

    private func bringToFront(_ app: NSRunningApplication) {
        if let url = app.bundleURL {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            cfg.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        } else {
            app.activate(options: [])
        }
    }

    private func pasteWhenFront(_ app: NSRunningApplication, tries: Int) {
        if app.isActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                postCommandV()
                self?.toast("已粘贴到 Claude", seconds: 1.4)
            }
        } else if tries < 15 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.pasteWhenFront(app, tries: tries + 1)
            }
        } else {
            toast("已复制 · ⌘V 粘贴")
        }
    }
}

func postCommandV() {
    let src = CGEventSource(stateID: .combinedSessionState)
    let v: CGKeyCode = 9
    let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

// MARK: - 离屏渲染（打包图标 / 预览用）

final class FillView: NSView {
    var color: NSColor = .clear
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); px(bounds) }
}

func writePNG(_ view: NSView, scale: CGFloat, to path: String) -> Bool {
    let b = view.bounds
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * scale), pixelsHigh: Int(b.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
    rep.size = b.size
    view.cacheDisplay(in: b, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? data.write(to: URL(fileURLWithPath: path))) != nil
}

final class AppIconView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let s = bounds.width
        let plate = bounds.insetBy(dx: s * 0.1, dy: s * 0.1)
        Palette.ink.setFill()
        NSBezierPath(roundedRect: plate, xRadius: plate.width * 0.22, yRadius: plate.width * 0.22).fill()
        let u = plate.width * 0.72 / 18
        let o = NSPoint(x: plate.midX - 9 * u, y: plate.midY - 5 * u)
        drawClawd(at: o, unit: u, pose: Pose(), body: Palette.accent, eye: Palette.ink)
    }
}

/// 预览图：上排浅色背景、下排深色背景；依次是 散步 / 吃点心 / 害羞三种 / 吃饱 / 打盹，最后是菜单
@MainActor
func renderPreview(to path: String) -> Bool {
    func scene(_ offset: CGFloat, _ face: Face, look: Int = 0, legs: Int = 0, hop: CGFloat = 0) -> Scene {
        var s = Scene()
        s.offset = offset
        s.pose = Pose(face: face, look: look, legs: legs)
        s.hop = hop
        return s
    }
    var eat = scene(0, .normal, look: 1)
    eat.lean = clawdUnit
    eat.meal = Meal(food: .cookie, side: 1, bitten: 1)
    let scenes = [
        scene(6, .normal, look: 1, legs: 1),
        eat,
        scene(7.5, .shyHappy, hop: clawdUnit),
        scene(7.5, .shyXX, legs: 2),
        scene(7.5, .shyAway, look: -1),
        scene(9, .happy, hop: clawdUnit),
        scene(12, .sleep),
    ]

    let tileW = stageSize.width + 10, tileH = stageSize.height + 12
    let menuItems = buildMenu()
    let menuH = MenuView.height(for: menuItems)
    let W = tileW * CGFloat(scenes.count) + MenuView.width + 16, H = max(tileH * 2, menuH + 12)
    let root = FillView(frame: NSRect(x: 0, y: 0, width: W, height: H))

    let backgrounds = [NSColor(srgbRed: 0.965, green: 0.958, blue: 0.93, alpha: 1),
                       NSColor(srgbRed: 0.15, green: 0.148, blue: 0.14, alpha: 1)]
    for (row, color) in backgrounds.enumerated() {
        let band = FillView(frame: NSRect(x: 0, y: CGFloat(row) * H / 2, width: W, height: H / 2))
        band.color = color
        root.addSubview(band)
        for (i, s) in scenes.enumerated() {
            let v = StageView(frame: NSRect(x: CGFloat(i) * tileW + 6, y: (H / 2 - stageSize.height) / 2,
                                            width: stageSize.width, height: stageSize.height))
            v.scene = s
            band.addSubview(v)
        }
    }
    let m = MenuView(frame: NSRect(x: tileW * CGFloat(scenes.count) + 8, y: (H - menuH) / 2,
                                   width: MenuView.width, height: menuH))
    m.items = menuItems
    m.hovered = 0
    root.addSubview(m)
    return writePNG(root, scale: 5, to: path)
}

// MARK: - 入口

let argv = CommandLine.arguments
if argv.count >= 4, argv[1] == "--render-icon", let size = Double(argv[3]) {
    let v = AppIconView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    exit(writePNG(v, scale: 1, to: argv[2]) ? 0 : 1)
}
if argv.count >= 3, argv[1] == "--render-preview" {
    exit(MainActor.assumeIsolated { renderPreview(to: argv[2]) } ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MainActor.assumeIsolated { Controller() }
app.delegate = controller
app.run()
