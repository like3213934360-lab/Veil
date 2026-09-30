import AppKit
import Carbon.HIToolbox

// MARK: - 快捷键数据

/// 一个快捷键：虚拟键码 + Carbon 修饰键掩码
struct Shortcut: Equatable {
    var keyCode: UInt32
    var mods: UInt32

    // Carbon: cmdKey=0x100, shiftKey=0x200, optionKey=0x800, controlKey=0x1000
    static let cmd: UInt32 = 0x100, shift: UInt32 = 0x200, option: UInt32 = 0x800, control: UInt32 = 0x1000

    init(keyCode: UInt32, mods: UInt32) {
        self.keyCode = keyCode
        self.mods = mods
    }

    init(_ keyCode: Int, _ mods: UInt32) { self.init(keyCode: UInt32(keyCode), mods: mods) }

    /// 从键盘事件构造（录制快捷键时用）
    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        mods = Self.carbonMods(event.modifierFlags)
    }

    static func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= cmd }
        if f.contains(.shift) { m |= shift }
        if f.contains(.option) { m |= option }
        if f.contains(.control) { m |= control }
        return m
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if mods & Self.cmd != 0 { f.insert(.command) }
        if mods & Self.shift != 0 { f.insert(.shift) }
        if mods & Self.option != 0 { f.insert(.option) }
        if mods & Self.control != 0 { f.insert(.control) }
        return f
    }

    /// 显示文字，例如 “⌃⌥⌘F”（修饰键按系统顺序 ⌃⌥⇧⌘）
    var display: String {
        var s = ""
        if mods & Self.control != 0 { s += "⌃" }
        if mods & Self.option != 0 { s += "⌥" }
        if mods & Self.shift != 0 { s += "⇧" }
        if mods & Self.cmd != 0 { s += "⌘" }
        return s + KeyNames.label(keyCode)
    }

    /// 只用 ⌘（或 ⇧⌘）的组合：很可能和其他应用的菜单快捷键重名，注册后会覆盖它们
    var overridesAppShortcuts: Bool {
        mods & Self.cmd != 0 && mods & (Self.option | Self.control) == 0
    }

    /// 是否可以作为全局快捷键：至少一个修饰键，或者是 F1–F20 这类功能键
    var isValid: Bool { mods != 0 || KeyNames.isFunctionKey(keyCode) }
}

/// 虚拟键码 -> 显示文字 / 菜单 keyEquivalent。字母数字按当前键盘布局翻译。
enum KeyNames {
    private static let special: [Int: (String, String)] = [
        kVK_Return: ("↩", "\r"), kVK_Tab: ("⇥", "\t"), kVK_Space: ("Space", " "),
        kVK_Delete: ("⌫", "\u{8}"), kVK_Escape: ("⎋", "\u{1b}"),
        kVK_ForwardDelete: ("⌦", fk(NSDeleteFunctionKey)),
        kVK_LeftArrow: ("←", fk(NSLeftArrowFunctionKey)), kVK_RightArrow: ("→", fk(NSRightArrowFunctionKey)),
        kVK_UpArrow: ("↑", fk(NSUpArrowFunctionKey)), kVK_DownArrow: ("↓", fk(NSDownArrowFunctionKey)),
        kVK_Home: ("↖", fk(NSHomeFunctionKey)), kVK_End: ("↘", fk(NSEndFunctionKey)),
        kVK_PageUp: ("⇞", fk(NSPageUpFunctionKey)), kVK_PageDown: ("⇟", fk(NSPageDownFunctionKey)),
        kVK_F1: ("F1", fk(NSF1FunctionKey)), kVK_F2: ("F2", fk(NSF2FunctionKey)), kVK_F3: ("F3", fk(NSF3FunctionKey)),
        kVK_F4: ("F4", fk(NSF4FunctionKey)), kVK_F5: ("F5", fk(NSF5FunctionKey)), kVK_F6: ("F6", fk(NSF6FunctionKey)),
        kVK_F7: ("F7", fk(NSF7FunctionKey)), kVK_F8: ("F8", fk(NSF8FunctionKey)), kVK_F9: ("F9", fk(NSF9FunctionKey)),
        kVK_F10: ("F10", fk(NSF10FunctionKey)), kVK_F11: ("F11", fk(NSF11FunctionKey)), kVK_F12: ("F12", fk(NSF12FunctionKey)),
        kVK_F13: ("F13", fk(NSF13FunctionKey)), kVK_F14: ("F14", fk(NSF14FunctionKey)), kVK_F15: ("F15", fk(NSF15FunctionKey)),
        kVK_F16: ("F16", fk(NSF16FunctionKey)), kVK_F17: ("F17", fk(NSF17FunctionKey)), kVK_F18: ("F18", fk(NSF18FunctionKey)),
        kVK_F19: ("F19", fk(NSF19FunctionKey)), kVK_F20: ("F20", fk(NSF20FunctionKey)),
    ]

    private static func fk(_ c: Int) -> String { String(UnicodeScalar(UInt16(c)).map(Character.init) ?? " ") }

    static func isFunctionKey(_ code: UInt32) -> Bool {
        let f: [Int] = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return f.contains(Int(code))
    }

    static func label(_ code: UInt32) -> String {
        if let s = special[Int(code)] { return s.0 }
        return translate(code)?.uppercased() ?? "#\(code)"
    }

    /// 菜单项右侧显示用的 keyEquivalent
    static func keyEquivalent(_ code: UInt32) -> String? {
        if let s = special[Int(code)] { return s.1 }
        return translate(code)?.lowercased()
    }

    /// 用当前 ASCII 键盘布局把键码翻译成字符（中文输入法下也能得到正确的字母）
    private static func translate(_ code: UInt32) -> String? {
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let st = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &len, &chars)
        }
        guard st == noErr, len > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: len).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

// MARK: - 全局快捷键

/// Carbon 全局快捷键：系统只在按下/松开时唤醒本进程，平时零开销，不需要辅助功能权限。
/// 每个动作的快捷键都可以自定义（见 ShortcutsWindow），也可以清空（不注册）。
final class HotKeys {
    enum Action: UInt32, CaseIterable {
        case focus = 1, strip, panic, stronger, weaker, quit

        var title: String {
            switch self {
            case .focus: return "开关聚焦模式（按住偷看）"
            case .strip: return "开关缩略图模糊"
            case .panic: return "紧急隐私（全屏模糊）"
            case .stronger: return "增强模糊"
            case .weaker: return "减弱模糊"
            case .quit: return "强制退出 Veil"
            }
        }

        /// 保存用的键名（不随枚举顺序变化）
        var key: String {
            switch self {
            case .focus: return "focus"
            case .strip: return "strip"
            case .panic: return "panic"
            case .stronger: return "stronger"
            case .weaker: return "weaker"
            case .quit: return "quit"
            }
        }

        var defaultShortcut: Shortcut {
            let hyper = Shortcut.control | Shortcut.option | Shortcut.cmd
            switch self {
            case .focus: return Shortcut(kVK_ANSI_F, hyper)
            case .strip: return Shortcut(kVK_ANSI_S, hyper)
            case .panic: return Shortcut(kVK_ANSI_B, hyper)
            case .stronger: return Shortcut(kVK_UpArrow, hyper)
            case .weaker: return Shortcut(kVK_DownArrow, hyper)
            // Windows 键盘的 Win 键在 Mac 上就是 ⌘，所以 Win+1 = ⌘1
            case .quit: return Shortcut(kVK_ANSI_1, Shortcut.cmd)
            }
        }

        /// 当前生效的快捷键；nil 表示已清空
        var shortcut: Shortcut? { Settings.shared.shortcut(for: self) }
    }

    /// (动作, 是否按下)
    var handler: ((Action, Bool) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var down: Set<UInt32> = []
    /// 注册失败（被其他应用独占）的动作
    private(set) var failed: [Action] = []

    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let cb: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            // 强制退出：直接在回调里结束进程，不经过任何其他逻辑，其他功能出问题时也能退出
            if pressed, hk.id == Action.quit.rawValue {
                HotKeys.emergencyExit()
            }
            let me = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            me.dispatch(id: hk.id, pressed: pressed)
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), cb, types.count, &types,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    /// 立即结束进程。所有遮罩窗口随进程一起由系统移除。
    static func emergencyExit() -> Never {
        VeilCore.restoreMuteBeforeExit?()
        exit(0)
    }

    private func dispatch(id: UInt32, pressed: Bool) {
        guard let action = Action(rawValue: id) else { return }
        // 过滤按住时可能出现的重复按下（调强度允许连发）
        if pressed {
            guard !down.contains(id) || action == .stronger || action == .weaker else { return }
            down.insert(id)
        } else {
            down.remove(id)
        }
        handler?(action, pressed)
    }

    /// 按当前设置（重新）注册全部快捷键
    func register() {
        unregisterAll()
        failed.removeAll()
        for a in Action.allCases {
            guard let sc = a.shortcut else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5645_494C), id: a.rawValue) // 'VEIL'
            let st = RegisterEventHotKey(sc.keyCode, sc.mods, id, GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref) } else { failed.append(a) }
        }
    }

    /// 暂时注销全部快捷键（录制新快捷键时，避免按键被自己拦截）
    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        down.removeAll()
    }

    static func label(_ a: Action) -> String { a.shortcut?.display ?? "未设置" }
}

/// 连按两下右 Option 触发（可选）。只监听 flagsChanged，需要辅助功能权限。
final class DoubleOptionTap {
    private var monitor: Any?
    private var lastTap: TimeInterval = 0
    private var pressedAt: TimeInterval = 0
    private var dirty = false
    var onDoubleTap: (() -> Void)?

    var enabled: Bool = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled {
                monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
                    self?.handle(e)
                }
            } else if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }
    }

    private func handle(_ e: NSEvent) {
        if e.type == .keyDown { dirty = true; return } // Option 被用作组合键时不算
        let rightOption = UInt16(kVK_RightOption)
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard e.keyCode == rightOption else { dirty = true; return }
        let now = e.timestamp
        if mods.contains(.option) {
            // 按下：必须只有 Option
            dirty = mods != .option
            pressedAt = now
        } else {
            // 松开：短按才算一次 tap
            guard !dirty, now - pressedAt < 0.3 else { lastTap = 0; return }
            if now - lastTap < 0.35 {
                lastTap = 0
                onDoubleTap?()
            } else {
                lastTap = now
            }
        }
    }
}
