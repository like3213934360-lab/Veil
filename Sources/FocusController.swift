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
            self.focusChanged()
        }
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.focusChanged()
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != selfPid {
            observe(pid: front.processIdentifier)
        }
    }

    // MARK: 开关

    func setActive(_ on: Bool, style: VeilStyle) {
        active = on
        if on {
            veils.sync()
            veils.apply(style, animated: false)
            reorder(fadeIn: true)
        } else {
            pendingReorder?.cancel()
            veils.hide()
        }
    }

    func apply(_ style: VeilStyle, animated: Bool) { veils.apply(style, animated: animated) }

    func screensChanged() {
        guard active else { return }
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
            if self.active, !self.suspended, NSScreen.screens.count > 1,
               Settings.shared.focusScope != FocusScope.all.rawValue, let f,
               self.screenIndex(of: f, in: NSScreen.screens) != self.lastFocusScreen {
                self.reorder()
            }
            self.onGeometryChange?(f)
        }
        geometryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.033, execute: work)
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
    }

    /// 按“聚焦范围”设置，把每块屏幕的遮罩排到合适的窗口下方（或收起）。
    /// 已经显示的遮罩只做重排，不做透明度动画，避免闪动。
    func reorder(fadeIn: Bool = false) {
        guard active, !suspended else { return }
        let target = focusedWindowID()
        let screens = NSScreen.screens
        let scope = FocusScope(rawValue: Settings.shared.focusScope) ?? .focusedScreen
        let windows = onScreenWindows()
        let focusScreen = target.flatMap { id in windows.first { $0.id == id } }.map { screenIndex(of: $0.rect, in: screens) }
        lastFocusScreen = focusScreen
        /// 铺满整块屏幕的窗口（全屏应用）：遮罩无法排到它下面，而且整块屏幕只有它，直接不遮
        func coversScreen(_ id: Int?, _ i: Int) -> Bool {
            guard let id, i < screens.count, let r = windows.first(where: { $0.id == id })?.rect else { return false }
            let f = screens[i].frame
            return r.minX <= f.minX + 1 && r.minY <= f.minY + 1 && r.maxX >= f.maxX - 1 && r.maxY >= f.maxY - 1
        }

        for (i, w) in veils.windows.enumerated() {
            var below = target
            if i == focusScreen, coversScreen(target, i) { w.hide(); continue }
            if target != nil, let focusScreen, i != focusScreen, i < screens.count {
                switch scope {
                case .focusedScreen:
                    w.hide()
                    continue
                case .perScreen:
                    // 这块屏幕上最靠前的普通窗口保持清晰；没有窗口时只模糊桌面
                    if let top = windows.first(where: { screenIndex(of: $0.rect, in: screens) == i }) {
                        if coversScreen(top.id, i) { w.hide(); continue }
                        below = top.id
                    }
                case .all:
                    break
                }
            }
            let order: (VeilWindow) -> Void = { w in
                if let below { w.order(.below, relativeTo: below) } else { w.orderFrontRegardless() }
            }
            if w.wantsVisible && !fadeIn {
                order(w)
            } else {
                w.show(order: order)
            }
        }
    }

    private struct WinInfo { let id: Int; let rect: CGRect }

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
            out.append(WinInfo(id: id, rect: Coords.toCocoa(CGRect(x: x, y: y, width: wd, height: ht))))
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
        guard active else { return }
        if s { veils.hide(duration: duration) } else { reorder(fadeIn: true) }
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
