import AppKit
import ApplicationServices

/// 聚焦模式：每块屏幕一个全屏遮罩，层级 .normal，始终排在“当前主窗口”正下方。
/// 主窗口移动/缩放时无需任何处理；只在焦点变化等事件时重排一次，无轮询。
final class FocusController {
    private let veils = ScreenVeils(level: .normal)
    private(set) var active = false
    private var axObserver: AXObserver?
    private var observedPid: pid_t = 0
    private var pendingReorder: DispatchWorkItem?
    private let selfPid = ProcessInfo.processInfo.processIdentifier

    /// 焦点变化回调（给 VeilCore 做白名单判断、刷新缩略图遮罩）
    var onFocusChange: (() -> Void)?

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let app, app.processIdentifier != self.selfPid { self.observe(pid: app.processIdentifier) }
            // 用键盘（⌘Tab、Spotlight 等）切到另一块屏幕上的应用时，工作屏跟着焦点走
            self.preferFocus = true
            self.focusChanged()
        }
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // Ctrl+←/→ 切换空间（例如切到另一个全屏应用）：工作屏跟着焦点走，
            // 并在切换动画结束后再校正一次（动画期间拿到的窗口列表可能还是旧空间的）
            self?.preferFocus = true
            self?.focusChanged()
            self?.spaceSettle()
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != selfPid {
            observe(pid: front.processIdentifier)
        }
    }

    // MARK: 开关

    func setActive(_ on: Bool, style: VeilStyle) {
        active = on
        roles = []
        if on {
            veils.sync()
            veils.apply(style, animated: false)
            reorder(fadeIn: true)
        } else {
            pendingReorder?.cancel()
            veils.hide()
        }
        updateMouseTracking()
    }

    func apply(_ style: VeilStyle, animated: Bool) { veils.apply(style, animated: animated) }

    func screensChanged() {
        updateMouseTracking()
        guard active else { return }
        roles = []
        veils.sync()
        reorder(fadeIn: true)
    }

    // MARK: 事件

    private var geometryWork: DispatchWorkItem?
    /// 上一次焦点窗口所在的屏幕下标
    private var lastFocusScreen: Int?

    /// 焦点窗口移动/缩放后的回调（缩略图遮罩据此让位），参数为窗口位置（Cocoa 坐标）
    var onGeometryChange: ((CGRect?) -> Void)?
    /// 有任何遮罩需要跟随窗口时由 Core 置为 true；否则直接忽略几何事件
    var trackGeometry = false

    /// 窗口移动/缩放：聚焦遮罩排在窗口下方，大小变化本身不需要处理；
    /// 需要处理的是：缩略图遮罩让出窗口区域、窗口被拖到另一块屏幕。
    /// 拖动期间事件很密，合并为约 30 次/秒，只读 AX 坐标。
    private func geometryChanged() {
        guard trackGeometry, geometryWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.geometryWork = nil
            let f = self.focusedWindowFrame()
            // 跟随焦点时，窗口被拖到另一块屏幕要换工作屏
            if self.active, !self.suspended, NSScreen.screens.count > 1,
               FocusScope.current == .followFocus, let f,
               self.screenIndex(of: f, in: NSScreen.screens) != self.lastFocusScreen {
                self.reorder()
            }
            self.onGeometryChange?(f)
            self.scheduleSettle()
        }
        geometryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.033, execute: work)
    }

    /// 窗口缩放/切换后，台前调度会把缩略图条滑走或滑回，等动画结束再按新的缩略图位置重排一次
    private var settleWork: DispatchWorkItem?
    func scheduleSettle() {
        guard active else { return }
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reorder() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// 当前焦点窗口的位置（Cocoa 坐标），用 AX 直接读取，比 CGWindowList 便宜
    func focusedWindowFrame() -> CGRect? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != selfPid else { return nil }
        // 没有辅助功能权限时退回 CGWindowList：只能在切换应用时更新，拖动缩放期间收不到事件
        guard AXIsProcessTrusted() else {
            let id = cgFrontWindowID(pid: front.processIdentifier)
            return onScreenWindows().first { $0.id == id }?.rect
        }
        let appEl = AXUIElementCreateApplication(front.processIdentifier)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let win = v as! AXUIElement
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return Coords.toCocoa(CGRect(origin: p, size: s))
    }

    /// 切换空间有约 0.5 秒动画，动画中取到的窗口列表还是旧空间的；动画结束后再校正几次
    private var spaceWork: [DispatchWorkItem] = []
    private func spaceSettle() {
        spaceWork.forEach { $0.cancel() }
        spaceWork = [0.35, 0.7].map { delay in
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.active else { return }
                self.preferFocus = true
                self.reorder()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
            return w
        }
    }

    private func focusChanged() {
        onFocusChange?()
        guard active else { return }
        reorder(fadeIn: false)
        // 应用激活后可能还会把自己的其他窗口提到前面，稍后再校正一次（合并为单次）
        pendingReorder?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active else { return }
            self.reorder(fadeIn: false)
        }
        pendingReorder = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        scheduleSettle()
    }

    // MARK: 布局
    //
    // 每块屏幕一个遮罩，分两种角色：
    //  - 工作屏（鼠标所在 / 焦点窗口所在，可在菜单切换）：遮罩排在“要保持清晰的窗口”正下方，
    //    并让出台前调度缩略图那一条竖列（缩略图是否模糊由“缩略图模糊”功能单独负责）。
    //  - 其他屏幕：遮罩排在所有普通窗口之上，整块模糊。

    private enum Role: Equatable { case hidden, below(Int), front }
    private var roles: [Role] = []
    /// 当前工作屏下标
    private var workScreen: Int?

    /// 每块屏幕上台前调度缩略图条的竖列（没有时为 nil），由 Core 接到 StageStripController
    var stripColumns: (() -> [NSRect?])?

    /// fitDuration：工作屏遮罩改变宽度时的动画时长（与缩略图遮罩同步，默认 Motion.settle）
    func reorder(fadeIn: Bool = false, fitDuration: TimeInterval = Motion.settle) {
        guard active, !suspended else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let columns = stripColumns?() ?? []
        func column(_ i: Int) -> NSRect? { i < columns.count ? columns[i] : nil }

        // 排除台前调度缩略图（应用窗口缩小后的替身也在 layer 0，落在缩略图竖列里）
        let windows = onScreenWindows().filter { w in
            let i = screenIndex(of: w.rect, in: screens)
            guard let col = column(i) else { return true }
            return !col.insetBy(dx: -8, dy: -8).contains(w.rect)
        }
        let target = focusedWindowID()
        let targetRect = target.flatMap { id in windows.first { $0.id == id }?.rect }
        let focusScreen = targetRect.map { screenIndex(of: $0, in: screens) }
        lastFocusScreen = focusScreen

        // 工作屏：
        //  - 跟随焦点：焦点窗口所在屏幕；
        //  - 跟随鼠标：鼠标跨到另一块屏幕时切过去；但用键盘切换应用 / 切换空间（⌃→、⌘Tab）时，
        //    以焦点为准，否则切到的全屏应用会被整块盖住。之后鼠标再跨屏，又以鼠标为准。
        let work: Int
        if screens.count > 1, FocusScope.current == .followMouse {
            if preferFocus, let focusScreen {
                work = focusScreen
            } else if preferFocus, let active = activeSpaceScreen(screens) {
                // 焦点窗口还没取到（切换动画中）：用前台应用所在的屏幕
                work = active
            } else if let w = workScreen, w < screens.count, !preferFocus {
                work = w
            } else {
                work = mouseScreenIndex(screens) ?? focusScreen ?? 0
            }
            preferFocus = false
        } else {
            work = focusScreen ?? mouseScreenIndex(screens) ?? 0
        }
        workScreen = work
        var fullscreenHere = false
        if roles.count != veils.windows.count { roles = Array(repeating: .hidden, count: veils.windows.count) }

        for (i, w) in veils.windows.enumerated() where i < screens.count {
            let screen = screens[i].frame
            var rect = screen
            let role: Role
            if i == work {
                // 保持清晰的窗口：焦点窗口在这块屏幕上就用它，否则用这块屏幕上最靠前的窗口
                let keep = (focusScreen == i ? targetRect.map { (target!, $0) } : nil)
                    ?? windows.first { screenIndex(of: $0.rect, in: screens) == i }.map { ($0.id, $0.rect) }
                // 全屏空间：整块屏幕只有这个应用（包括它的工具栏等附属窗口），不加遮罩
                fullscreenHere = isFullscreenSpace(i, windows: windows, screens: screens)
                if let keep, !Self.covers(keep.1, screen), !fullscreenHere {
                    role = .below(keep.0)
                    if let col = column(i) { rect = Self.exclude(col, from: screen) }
                } else {
                    // 没有窗口，或窗口铺满整屏（背后没东西可遮）：不加遮罩
                    role = .hidden
                }
            } else {
                role = .front
            }

            let prev = roles[i]
            // 这块屏幕正在显示全屏应用的空间（或者正在切换过去/回来）：
            // 桌面空间里的遮罩完全不动——既不收起，也不重排（重排会把它拖进全屏空间）。
            // 切回桌面时它随桌面一起滑回来，直接就是模糊好的，快速来回切换也不会闪。
            if w.spaceMode == .currentSpace, w.wantsVisible,
               w.isParkedInOtherSpace || (i == work && fullscreenHere) { continue }
            roles[i] = role
            switch role {
            case .hidden:
                w.hide()
            case .below(let id):
                if w.level != .normal { w.level = .normal }
                // 工作屏的遮罩只属于当前桌面空间：切换空间时跟着桌面一起滑动，不会盖到全屏应用上
                w.spaceMode = .currentSpace
                // 从别的角色切过来时，尺寸直接到位；同一角色下（缩略图条出现/消失）平滑过渡
                let wasBelow: Bool = { if case .below = prev { return true }; return false }()
                w.fit(rect, animated: wasBelow && fitDuration > 0, duration: fitDuration)
                if w.wantsVisible && !fadeIn {
                    w.order(.below, relativeTo: id)
                } else {
                    w.show { $0.order(.below, relativeTo: id) }
                }
            case .front:
                // 整块模糊的屏幕：至少提到缩略图应用图标之上；
                // 开了“顶层模糊”时提到最高层，连菜单栏、程序坞、通知弹窗一起盖住
                let lv: NSWindow.Level = Settings.shared.topLevelBlurEffective ? .topMost : .aboveStageIcons
                if w.level != lv { w.level = lv }
                // 整块模糊的屏幕：这块屏幕上的所有空间都要盖住
                w.spaceMode = .allSpaces
                w.fit(rect)
                if prev == .front, w.wantsVisible, !fadeIn {
                    w.orderFrontRegardless()
                } else {
                    // 变成“整块模糊”：从清晰渐变到模糊，避免整屏突然一变
                    w.show(duration: Motion.screenSwitch) { $0.orderFrontRegardless() }
                }
            }
        }
    }

    /// 窗口是否铺满整块屏幕（全屏或手动拉满）
    private static func covers(_ r: CGRect, _ screen: CGRect) -> Bool {
        r.minX <= screen.minX + 1 && r.minY <= screen.minY + 1 && r.maxX >= screen.maxX - 1 && r.maxY >= screen.maxY - 1
    }

    /// 从整屏矩形里去掉缩略图竖列（竖列贴在左边或右边）
    private static func exclude(_ col: NSRect, from screen: NSRect) -> NSRect {
        var r = screen
        if col.midX > screen.midX {
            r.size.width = max(0, col.minX - screen.minX)
        } else {
            r.origin.x = col.maxX
            r.size.width = max(0, screen.maxX - col.maxX)
        }
        return r.integral
    }

    // MARK: 跟随鼠标

    private var mouseMonitor: Any?

    /// 只在多屏 + 跟随鼠标时监听鼠标移动；处理函数只判断鼠标是否换了屏幕，开销极低
    func updateMouseTracking() {
        let need = active && !suspended && NSScreen.screens.count > 1 && FocusScope.current == .followMouse
        if need, mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            ) { [weak self] _ in self?.mouseMoved() }
        } else if !need, let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
        }
    }

    /// 下一次重排时，工作屏以焦点为准（键盘切换应用 / 切换空间之后）
    private var preferFocus = false
    /// 鼠标上一次所在的屏幕：只有鼠标真正跨屏时才按鼠标切换工作屏
    private var lastMouseScreen: Int?

    private func mouseMoved() {
        guard active, !suspended, let i = mouseScreenIndex(NSScreen.screens) else { return }
        defer { lastMouseScreen = i }
        guard i != lastMouseScreen, i != workScreen else { return }
        workScreen = i
        preferFocus = false
        reorder()
    }

    /// 前台应用最靠前窗口所在的屏幕（CGWindowList，不依赖 AX 焦点）
    private func activeSpaceScreen(_ screens: [NSScreen]) -> Int? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != selfPid,
              let id = cgFrontWindowID(pid: pid),
              let r = onScreenWindows().first(where: { $0.id == id })?.rect else { return nil }
        return screenIndex(of: r, in: screens)
    }

    private func mouseScreenIndex(_ screens: [NSScreen]) -> Int? {
        let p = NSEvent.mouseLocation
        return screens.firstIndex { NSMouseInRect(p, $0.frame, false) }
    }

    /// 菜单里切换了“顶层模糊”：非工作屏的遮罩换层级
    func topLevelChanged() { reorder() }

    /// 菜单里切换了多屏方式
    func scopeChanged() {
        updateMouseTracking()
        reorder()
    }

    private struct WinInfo { let id: Int; let rect: CGRect; let pid: pid_t }

    /// 第 i 块屏幕当前是否在显示全屏应用的空间（给缩略图遮罩用）
    func screenShowsFullscreenSpace(_ i: Int) -> Bool {
        isFullscreenSpace(i, windows: onScreenWindows(), screens: NSScreen.screens)
    }

    /// 这块屏幕当前是否处于某个应用的全屏空间：
    /// 屏幕上最靠前的窗口所属应用，有一个 AXFullScreen 的窗口落在这块屏幕上。
    /// （全屏窗口的实际尺寸可能比屏幕小，例如带刘海的屏幕会让出菜单栏高度，不能只看尺寸）
    private func isFullscreenSpace(_ i: Int, windows: [WinInfo], screens: [NSScreen]) -> Bool {
        guard AXIsProcessTrusted(),
              let top = windows.first(where: { screenIndex(of: $0.rect, in: screens) == i }) else { return false }
        let app = AXUIElementCreateApplication(top.pid)
        var ws: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ws) == .success,
              let arr = ws as? [AXUIElement] else { return false }
        for w in arr {
            var fs: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &fs) == .success,
                  (fs as? Bool) == true else { continue }
            var pv: CFTypeRef?, sv: CFTypeRef?
            var p = CGPoint.zero, s = CGSize.zero
            if AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success, let pv {
                AXValueGetValue(pv as! AXValue, .cgPoint, &p)
            }
            if AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv) == .success, let sv {
                AXValueGetValue(sv as! AXValue, .cgSize, &s)
            }
            if screenIndex(of: Coords.toCocoa(CGRect(origin: p, size: s)), in: screens) == i { return true }
        }
        return false
    }

    /// 当前屏幕上的普通窗口（从前到后），排除本程序和台前调度缩略图。Cocoa 坐标。
    private func onScreenWindows() -> [WinInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        var out: [WinInfo] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != selfPid,
                  (w[kCGWindowOwnerName as String] as? String) != "WindowManager",
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"],
                  wd > 60, ht > 60 else { continue }
            let pid = (w[kCGWindowOwnerPID as String] as? Int32) ?? 0
            out.append(WinInfo(id: id, rect: Coords.toCocoa(CGRect(x: x, y: y, width: wd, height: ht)), pid: pid))
        }
        return out
    }

    /// 窗口与哪块屏幕重叠面积最大
    func screenIndex(of rect: CGRect, in screens: [NSScreen]) -> Int {
        var best = 0
        var bestArea: CGFloat = -1
        for (i, s) in screens.enumerated() {
            let r = s.frame.intersection(rect)
            let area = r.isNull ? 0 : r.width * r.height
            if area > bestArea { bestArea = area; best = i }
        }
        return best
    }

    // MARK: 暂停（偷看 / 白名单 / 紧急模式），不改变 active

    private(set) var suspended = false

    func suspend(_ s: Bool, duration: TimeInterval = Motion.fadeOut) {
        guard s != suspended else { return }
        suspended = s
        updateMouseTracking()
        guard active else { return }
        if s { veils.hide(duration: duration); roles = [] } else { reorder(fadeIn: true) }
    }

    // MARK: 找当前主窗口

    /// 优先用辅助功能 API 取焦点窗口的精确 ID；没有权限时退回 CGWindowList（前台应用最靠前的普通窗口）
    /// 前台是本程序（刚启动、打开菜单）时，退回“最靠前的其他应用普通窗口”
    func focusedWindowID() -> Int? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != selfPid else {
            return cgFrontWindowID(pid: nil)
        }
        let pid = front.processIdentifier
        if AXIsProcessTrusted(), let id = axFocusedWindowID(pid: pid) { return id }
        return cgFrontWindowID(pid: pid) ?? cgFrontWindowID(pid: nil)
    }

    private func axFocusedWindowID(pid: pid_t) -> Int? {
        let appEl = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let win = v as! AXUIElement
        guard let getWindow = AXPrivate.getWindow else { return nil }
        var wid: CGWindowID = 0
        guard getWindow(win, &wid) == .success, wid != 0 else { return nil }
        return Int(wid)
    }

    /// pid 为 nil 时：任意非本程序、非 WindowManager 的最前普通窗口
    private func cgFrontWindowID(pid: pid_t?) -> Int? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for w in list {
            let owner = w[kCGWindowOwnerPID as String] as? Int32
            if let pid {
                guard owner == pid else { continue }
            } else {
                guard owner != selfPid, (w[kCGWindowOwnerName as String] as? String) != "WindowManager" else { continue }
            }
            guard
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Width"] ?? 0) > 60, (b["Height"] ?? 0) > 60 else { continue }
            return w[kCGWindowNumber as String] as? Int
        }
        return nil
    }

    // MARK: AXObserver：同一应用内的窗口切换

    private func observe(pid: pid_t) {
        guard pid != observedPid, AXIsProcessTrusted() else { return }
        if let old = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
            axObserver = nil
        }
        observedPid = pid
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, name, refcon in
            guard let refcon else { return }
            let me = Unmanaged<FocusController>.fromOpaque(refcon).takeUnretainedValue()
            let n = name as String
            if n == kAXWindowMovedNotification || n == kAXWindowResizedNotification {
                me.geometryChanged()
            } else {
                me.focusChanged()
            }
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                  kAXWindowMovedNotification, kAXWindowResizedNotification] {
            AXObserverAddNotification(obs, appEl, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        axObserver = obs
    }

    /// 权限刚被授予时，重新挂上观察者
    func refreshObserver() {
        observedPid = 0
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != selfPid {
            observe(pid: front.processIdentifier)
        }
    }
}

/// _AXUIElementGetWindow：AXUIElement -> CGWindowID。
/// 系统未公开但长期稳定；用 dlsym 动态查找，找不到时自动退回 CGWindowList 方案。
enum AXPrivate {
    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    static let getWindow: GetWindowFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()
}
