import AppKit

/// 台前调度缩略图遮罩：在缩略图条上方盖一层毛玻璃（不挡鼠标，仍可点击切换）。
/// 位置只在事件发生时计算（切换应用、屏幕变化、开关），无轮询。
final class StageStripController {
    /// 盖住 WindowManager 的缩略图（layer 0）和缩略图上的应用图标（layer 8）
    /// 缩略图条只存在于桌面空间：遮罩也只属于当前桌面空间，切换到全屏应用时随桌面滑走，不会盖上去
    private lazy var veils = ScreenVeils(level: .aboveStageIcons, spaceMode: .currentSpace) { [weak self] screen in
        self?.stripRect(on: screen)
    }
    private(set) var active = false
    private(set) var suspended = false
    private var cachedStrips: [CGRect] = []

    static var stageManagerEnabled: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
    }

    /// 上一次布局结果（每块屏幕的遮罩矩形，nil 表示隐藏），用于跳过无变化的刷新
    private var lastLayout: [NSRect?] = []

    func setActive(_ on: Bool, style: VeilStyle) {
        active = on
        lastLayout = []
        if on {
            veils.apply(style, animated: false)
            refresh(style: style, fadeIn: true)
        } else {
            veils.hide()
        }
        updateHoverMonitor()
    }

    func apply(_ style: VeilStyle, animated: Bool) { veils.apply(style, animated: animated) }

    func suspend(_ s: Bool, duration: TimeInterval = Motion.fadeOut) {
        guard s != suspended else { return }
        suspended = s
        guard active else { return }
        if s { veils.hide(duration: duration); lastLayout = [] } else { refresh(style: nil, fadeIn: true) }
        updateHoverMonitor()
    }

    // MARK: 悬停透视

    /// 只在遮罩显示且开启了“悬停透视”时监听鼠标移动；处理函数只做一次矩形判断，开销极低
    private var mouseMonitor: Any?
    private var leaveWork: [Int: DispatchWorkItem] = [:]

    func updateHoverMonitor() {
        let need = active && !suspended && Settings.shared.hoverReveal
        if need, mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                self?.mouseMoved()
            }
            mouseMoved()
        } else if !need, let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
            leaveWork.values.forEach { $0.cancel() }
            leaveWork.removeAll()
            veils.windows.forEach { $0.setRevealed(false, duration: 0) }
        }
    }

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        for (i, w) in veils.windows.enumerated() {
            // 左右各放宽几像素，鼠标贴着屏幕边缘时也算进入
            let inside = w.wantsVisible && w.isOnActiveSpace && w.frame.insetBy(dx: -6, dy: 0).contains(p)
            if inside {
                leaveWork[i]?.cancel()
                leaveWork[i] = nil
                w.setRevealed(true, duration: Motion.revealIn)
            } else if w.revealed, leaveWork[i] == nil {
                // 离开后稍等再恢复模糊，避免鼠标在边缘来回时闪烁
                let work = DispatchWorkItem { [weak self, weak w] in
                    self?.leaveWork[i] = nil
                    w?.setRevealed(false, duration: Motion.revealOut)
                }
                leaveWork[i] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Motion.revealLeaveDelay, execute: work)
            }
        }
    }

    /// 重新定位（焦点变化 / 屏幕变化时调用）。缩略图条消失时（台前调度关闭）自动收起。
    /// 布局与上次相同时直接返回，不做任何窗口操作。
    /// 焦点窗口的位置（Cocoa 坐标）：遮罩会让出这块区域，避免盖住正在用的窗口
    var avoidRect: CGRect?

    /// 窗口移动/缩放时调用：不重新扫描缩略图，只按新的窗口位置裁剪遮罩
    func windowMoved(_ rect: CGRect?) {
        guard active, !suspended else { return }
        if rect != avoidRect {
            avoidRect = rect
            // 拖动中：短动画紧跟窗口边缘
            relayout(fadeIn: false, force: false, animation: Motion.follow)
        }
        // 窗口盖到缩略图区域时，台前调度会把缩略图条滑走（或滑回来），
        // 等动画结束后重新扫描一次缩略图位置（拖动期间只保留最后一次）
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(animation: Motion.settle) }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    private var settleWork: DispatchWorkItem?

    /// animation > 0 时，已显示的遮罩平滑移动到新位置（切换应用、缩略图条重排等）
    func refresh(style: VeilStyle? = nil, fadeIn: Bool = false, force: Bool = false, animation: TimeInterval = Motion.settle) {
        guard active, !suspended else { return }
        if let style { veils.apply(style, animated: false) }
        cachedStrips = Self.stageManagerEnabled ? Self.thumbnailRects() : []
        relayout(fadeIn: fadeIn, force: force, animation: animation)
    }

    private func relayout(fadeIn: Bool, force: Bool, animation: TimeInterval = 0) {
        let enabled = Self.stageManagerEnabled
        let screens = NSScreen.screens
        let layout: [NSRect?] = screens.map { s in
            guard enabled, var r = stripRect(on: s), r.width > 0 else { return nil }
            r = clip(r, avoiding: avoidRect)
            return r.width >= 24 ? r.integral : nil
        }
        if !force, !fadeIn, layout == lastLayout, veils.windows.count == screens.count { return }
        let changed = layout != lastLayout
        lastLayout = layout
        // 用和缩略图遮罩相同的动画时长同步聚焦遮罩，过渡过程中也不会出现缝隙
        defer { if changed { onLayoutChange?(fadeIn ? 0 : animation) } }
        veils.sync(resize: false)
        for (i, rect) in layout.enumerated() where i < veils.windows.count {
            let w = veils.windows[i]
            if let rect {
                w.fit(rect, animated: animation > 0 && !fadeIn, duration: animation)
                if !w.wantsVisible || fadeIn { w.show() } else { w.orderFrontRegardless() }
            } else if !w.isParkedInOtherSpace {
                // 留在桌面空间里的遮罩不收起：切回桌面时直接出现，不用重新淡入
                w.hide()
            }
        }
    }

    // MARK: 定位

    /// 缩略图遮罩的位置变了（聚焦遮罩据此同步让位，保证两块严丝合缝）
    var onLayoutChange: ((TimeInterval) -> Void)?

    /// 每块屏幕上缩略图遮罩所占的竖列，给聚焦模式让位用。
    /// 遮罩显示中时，直接返回遮罩的目标位置（唯一数据源，两块遮罩的边界永远是同一个值）；
    /// 未显示时才自己计算。没有缩略图条的屏幕返回 nil。
    func stripColumns() -> [NSRect?] {
        if active, !suspended, lastLayout.count == NSScreen.screens.count { return lastLayout }
        guard Self.stageManagerEnabled else { return NSScreen.screens.map { _ in nil } }
        cachedStrips = Self.thumbnailRects()
        return NSScreen.screens.map { s in
            guard let r = stripRect(on: s, allowFallback: false), r.width > 0 else { return nil }
            return r
        }
    }

    /// 某块屏幕上的遮罩区域（Cocoa 坐标）。
    /// 自动模式：根据 WindowManager 缩略图窗口判断在屏幕左侧还是右侧，遮住整条竖列；
    /// 找不到缩略图时退回固定宽度（程序坞在左边时缩略图条在右边）。
    private func stripRect(on screen: NSScreen, allowFallback: Bool = true) -> NSRect? {
        let vf = screen.visibleFrame
        let full = screen.frame
        let manual = Settings.shared.stripWidth
        let pad: CGFloat = 16

        // 缩略图条只会出现在固定的一侧：程序坞在左边时在右侧，否则在左侧。
        // 只认“中心点在本屏幕内、且靠近这一侧边缘”的缩略图。
        // 这样可以排除：
        //  - 切换动画途中飞过屏幕中部的缩略图；
        //  - 窗口占满相邻屏幕时，台前调度把缩略图推出那块屏幕边缘藏起来，
        //    坐标恰好落进本屏幕另一侧（例如左屏右边缘推出 -> 落在右屏左边缘）。
        let side: Side = Self.dockOnLeft ? .right : .left
        let edge = full.width / 4
        let mine = cachedStrips.filter {
            let c = CGPoint(x: $0.midX, y: $0.midY)
            guard full.contains(c) else { return false }
            return side == .left ? (c.x - full.minX < edge) : (full.maxX - c.x < edge)
        }
        var width: CGFloat
        if !mine.isEmpty {
            let u = mine.reduce(mine[0]) { $0.union($1) }
            width = side == .left ? (u.maxX - vf.minX + pad) : (vf.maxX - u.minX + pad)
        } else if !allowFallback || !cachedStrips.isEmpty || Self.windowManagerRunning {
            // 这块屏幕上没有缩略图：要么缩略图条在别的屏幕，要么被当前窗口挤走、系统已经把它藏起来了。
            // 两种情况都没东西可遮，不再退回固定宽度（否则会凭空盖住窗口边缘）
            return nil
        } else {
            width = 200
        }
        if manual > 0 { width = CGFloat(manual) }
        width = min(max(width, 60), vf.width / 3)
        let x = side == .left ? vf.minX : vf.maxX - width
        // 竖列铺满整块屏幕高度（包括菜单栏下方和程序坞区域），
        // 否则和聚焦遮罩拼接时，菜单栏那一小段会露出没模糊的桌面
        return NSRect(x: x, y: full.minY, width: width, height: full.height)
    }

    /// 从遮罩里裁掉与窗口重叠的部分（保留靠屏幕边缘的那一侧）
    private func clip(_ r: NSRect, avoiding win: CGRect?) -> NSRect {
        guard let win, r.intersects(win) else { return r }
        var out = r
        if r.midX > win.midX {
            // 遮罩在窗口右侧：左边界退到窗口右边
            out.origin.x = max(r.minX, win.maxX)
            out.size.width = r.maxX - out.minX
        } else {
            out.size.width = max(0, min(r.maxX, win.minX) - r.minX)
        }
        return out
    }

    private enum Side { case left, right }

    /// 台前调度的 WindowManager 进程在运行，说明缩略图检测可用，不需要退回固定区域
    private static var windowManagerRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").isEmpty
    }

    private static var dockOnLeft: Bool {
        UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") == "left"
    }

    /// WindowManager 进程在 layer 0 上的小窗口 = 台前调度缩略图。返回 Cocoa 坐标。
    /// “小”按所在屏幕的比例判断（不超过屏幕宽度的 1/4、高度的 1/3），适配任意分辨率；
    /// 同时排除 WindowManager 铺满屏幕的背景层。
    private static func thumbnailRects() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        let screens = NSScreen.screens
        var out: [CGRect] = []
        for w in list {
            guard (w[kCGWindowOwnerName as String] as? String) == "WindowManager",
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"],
                  wd > 8, ht > 8 else { continue }
            let r = Coords.toCocoa(CGRect(x: x, y: y, width: wd, height: ht))
            let center = CGPoint(x: r.midX, y: r.midY)
            guard let screen = screens.first(where: { $0.frame.contains(center) }) ?? screens.first,
                  wd <= screen.frame.width / 4, ht <= screen.frame.height / 3 else { continue }
            out.append(r)
        }
        return out
    }
}
