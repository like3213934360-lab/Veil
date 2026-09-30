import AppKit
import ApplicationServices
import ServiceManagement

/// 状态机：把快捷键、菜单、系统事件汇总到一起，驱动各个遮罩控制器。
/// 全部事件驱动，没有定时器。
final class VeilCore: NSObject, NSApplicationDelegate {
    let focus = FocusController()
    let strip = StageStripController()
    let hotKeys = HotKeys()
    private let doubleTap = DoubleOptionTap()
    private let panicVeils = ScreenVeils(level: .screenSaver)
    private var menu: MenuBar!

    // MARK: 状态

    private(set) var focusOn = false
    private(set) var stripOn = false
    private(set) var panicOn = false
    private var peeking = false
    private var whitelisted = false
    /// 聚焦模式是否由“接外接显示器”自动打开（拔掉时只关闭自动打开的）
    private var autoFocused = false
    private var lastScreenCount = NSScreen.screens.count
    private var axTrusted = AXIsProcessTrusted()
    private var peekWork: DispatchWorkItem?
    private var stripSettle: DispatchWorkItem?
    private var mutedBeforePanic: Bool?
    private let selfPid = ProcessInfo.processInfo.processIdentifier

    /// 最近一个非本程序的前台应用（菜单“加入白名单”用）
    private(set) var lastFrontApp: NSRunningApplication?

    var anyActive: Bool { focusOn || stripOn || panicOn }

    // MARK: 启动

    func applicationDidFinishLaunching(_ note: Notification) {
        menu = MenuBar(core: self)

        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != selfPid {
            lastFrontApp = front
        }
        whitelisted = isWhitelisted(lastFrontApp)

        focus.onFocusChange = { [weak self] in self?.focusChanged() }
        focus.onGeometryChange = { [weak self] rect in self?.strip.windowMoved(rect) }
        focus.stripColumns = { [weak self] in self?.strip.stripColumns() ?? [] }

        hotKeys.handler = { [weak self] action, pressed in self?.hotKey(action, pressed: pressed) }
        hotKeys.register()

        doubleTap.onDoubleTap = { [weak self] in self?.toggleFocus() }
        doubleTap.enabled = Settings.shared.doubleOption

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(reduceMotionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

        let s = Settings.shared
        if s.rememberState {
            if s.focusOn { setFocus(true) }
            if s.stripOn { setStrip(true) }
        }
        if s.autoExternal, NSScreen.screens.count > 1, !focusOn {
            autoFocused = true
            setFocus(true)
        }
        menu.refresh()
    }

    func applicationWillTerminate(_ note: Notification) {
        if panicOn { restoreMute() }
    }

    // MARK: 开关

    func toggleFocus() { autoFocused = false; setFocus(!focusOn) }
    func toggleStrip() { setStrip(!stripOn) }
    func togglePanic() { setPanic(!panicOn) }

    func setFocus(_ on: Bool) {
        guard on != focusOn else { return }
        if on { requestAccessibilityIfNeeded() }
        focusOn = on
        defer { updateGeometryTracking() }
        focus.suspend(focusSuspended, duration: 0)
        focus.setActive(on, style: .current)
        syncStripActive()
        if Settings.shared.rememberState { Settings.shared.focusOn = on }
        menu?.refresh()
    }

    /// 缩略图遮罩是否实际显示：单独开了“缩略图模糊”，或者开了聚焦模式
    /// （聚焦模式本身就应该把缩略图一起模糊，鼠标悬停时透视）
    private var stripEffective: Bool { stripOn || focusOn }

    private func syncStripActive() {
        guard strip.active != stripEffective else { return }
        if stripEffective { strip.avoidRect = focus.focusedWindowFrame() }
        strip.suspend(stripSuspended, duration: 0)
        strip.setActive(stripEffective, style: .current)
    }

    /// 只在有遮罩需要跟随窗口时才处理移动/缩放事件
    private func updateGeometryTracking() {
        // 聚焦模式需要在窗口缩放后重排（台前调度会把缩略图条滑走/滑回）
        focus.trackGeometry = stripEffective
        if stripEffective { strip.avoidRect = focus.focusedWindowFrame() }
    }

    func setStrip(_ on: Bool) {
        guard on != stripOn else { return }
        stripOn = on
        if on { requestAccessibilityIfNeeded() }
        defer { updateGeometryTracking() }
        syncStripActive()
        if Settings.shared.rememberState { Settings.shared.stripOn = on }
        menu?.refresh()
    }

    func setPanic(_ on: Bool) {
        guard on != panicOn else { return }
        panicOn = on
        if on {
            panicVeils.sync()
            // 紧急模式用更重的遮挡：强度拉满、至少一定暗度
            var st = VeilStyle.current
            st.intensity = 1
            st.dim = max(st.dim, 0.35)
            panicVeils.apply(st, animated: false)
            panicVeils.windows.forEach { $0.show(duration: Motion.revealIn) }
            if Settings.shared.panicMute { mute() }
        } else {
            panicVeils.hide()
            restoreMute()
        }
        updateSuspension()
        menu?.refresh()
    }

    // MARK: 暂停（偷看 / 白名单 / 紧急）

    private var focusSuspended: Bool { peeking || whitelisted || panicOn }
    private var stripSuspended: Bool { peeking || whitelisted || panicOn }

    /// 统一计算两个控制器是否暂停；紧急模式时底下的遮罩也收起，省掉一层合成
    private func updateSuspension(duration: TimeInterval = Motion.fadeOut) {
        // 紧急模式下底层遮罩被完全盖住，瞬时切换即可
        let d = panicOn ? 0 : duration
        focus.suspend(focusSuspended, duration: d)
        strip.suspend(stripSuspended, duration: d)
    }

    // MARK: 样式

    func applyStyle(animated: Bool) {
        let st = VeilStyle.current
        focus.apply(st, animated: animated)
        strip.apply(st, animated: animated)
        if panicOn {
            var p = st
            p.intensity = 1
            p.dim = max(p.dim, 0.35)
            panicVeils.apply(p, animated: animated)
        }
    }

    func adjustIntensity(by delta: Double) {
        Settings.shared.intensity = (Settings.shared.intensity + delta).rounded(toPlaces: 2)
        applyStyle(animated: true)
        menu?.refresh()
    }

    // MARK: 快捷键

    private func hotKey(_ action: HotKeys.Action, pressed: Bool) {
        switch action {
        case .focus:
            if pressed {
                // 已经有模糊时：长按 = 偷看；短按 = 切换。都没开时：按下立即开启。
                guard focusOn || stripOn else { toggleFocus(); peekWork = nil; return }
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.peekWork = nil
                    self.peeking = true
                    self.updateSuspension(duration: Motion.revealIn)
                }
                peekWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            } else if peeking {
                peeking = false
                updateSuspension(duration: Motion.revealIn)
            } else if let work = peekWork {
                work.cancel()
                peekWork = nil
                toggleFocus()
            }
        case .strip:
            if pressed { toggleStrip() }
        case .panic:
            if pressed { togglePanic() }
        case .stronger:
            if pressed { adjustIntensity(by: 0.1) }
        case .weaker:
            if pressed { adjustIntensity(by: -0.1) }
        }
    }

    func setModifierPreset(_ i: Int) {
        Settings.shared.modifierPreset = i
        hotKeys.register()
        menu?.refresh()
    }

    // MARK: 系统事件

    private func focusChanged() {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != selfPid {
            lastFrontApp = front
        }
        checkAccessibility()
        let wl = isWhitelisted(lastFrontApp)
        if wl != whitelisted {
            whitelisted = wl
            updateSuspension()
        }
        guard stripEffective else { return }
        strip.avoidRect = focus.focusedWindowFrame()
        strip.refresh()
        // 台前调度切换应用时缩略图有动画，稍后再校正一次（合并为单次）
        stripSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.strip.refresh() }
        stripSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    @objc private func screensChanged() {
        let count = NSScreen.screens.count
        defer { lastScreenCount = count; updateGeometryTracking() }
        focus.screensChanged()
        strip.refresh(force: true)
        if panicOn {
            panicVeils.sync()
            panicVeils.windows.forEach { if !$0.wantsVisible { $0.show(duration: 0) } }
        }
        guard Settings.shared.autoExternal else { return }
        if count > 1, lastScreenCount <= 1, !focusOn {
            autoFocused = true
            setFocus(true)
        } else if count <= 1, lastScreenCount > 1, autoFocused {
            autoFocused = false
            setFocus(false)
        }
    }

    @objc private func reduceMotionChanged() { /* Motion.reduced 每次实时读取，无需处理 */ }

    // MARK: 白名单

    private func isWhitelisted(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return Settings.shared.whitelist.contains(id)
    }

    func addToWhitelist(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier else { return }
        var list = Settings.shared.whitelist
        guard !list.contains(id) else { return }
        list.append(id)
        Settings.shared.whitelist = list
        reevaluateWhitelist()
    }

    func removeFromWhitelist(_ id: String) {
        Settings.shared.whitelist.removeAll { $0 == id }
        reevaluateWhitelist()
    }

    private func reevaluateWhitelist() {
        whitelisted = isWhitelisted(lastFrontApp)
        updateSuspension()
        menu?.refresh()
    }

    // MARK: 可选功能

    func setDoubleOption(_ on: Bool) {
        Settings.shared.doubleOption = on
        if on { requestAccessibilityIfNeeded() }
        doubleTap.enabled = on
    }

    func setRememberState(_ on: Bool) {
        Settings.shared.rememberState = on
        Settings.shared.focusOn = on && focusOn
        Settings.shared.stripOn = on && stripOn
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let a = NSAlert()
            a.messageText = on ? "无法设置开机自启" : "无法取消开机自启"
            a.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    // MARK: 辅助功能权限

    var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    private var prompted = false
    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted(), !prompted else { return }
        prompted = true
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// 在应用切换事件里顺便检查：权限刚被授予时重新挂上观察者（无轮询）
    private func checkAccessibility() {
        let now = AXIsProcessTrusted()
        guard now != axTrusted else { return }
        axTrusted = now
        guard now else { return }
        focus.refreshObserver()
        if doubleTap.enabled {
            // 全局事件监听需要在授权后重新挂载
            doubleTap.enabled = false
            doubleTap.enabled = true
        }
        menu?.refresh()
    }

    func openAccessibilitySettings() {
        requestAccessibilityIfNeeded()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 静音

    private func runScript(_ src: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        return NSAppleScript(source: src)?.executeAndReturnError(&err)
    }

    private func mute() {
        mutedBeforePanic = runScript("output muted of (get volume settings)")?.booleanValue ?? false
        _ = runScript("set volume output muted true")
    }

    private func restoreMute() {
        guard let was = mutedBeforePanic else { return }
        mutedBeforePanic = nil
        if !was { _ = runScript("set volume output muted false") }
    }
}

private extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let m = pow(10, Double(p))
        return (self * m).rounded() / m
    }
}
