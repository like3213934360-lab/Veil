import AppKit
import Carbon.HIToolbox

/// Carbon 全局快捷键：系统只在按下/松开时唤醒本进程，平时零开销，不需要辅助功能权限。
final class HotKeys {
    enum Action: UInt32, CaseIterable {
        case focus = 1, strip, panic, stronger, weaker

        var keyCode: UInt32 {
            switch self {
            case .focus: return UInt32(kVK_ANSI_F)
            case .strip: return UInt32(kVK_ANSI_S)
            case .panic: return UInt32(kVK_ANSI_B)
            case .stronger: return UInt32(kVK_UpArrow)
            case .weaker: return UInt32(kVK_DownArrow)
            }
        }

        var keyLabel: String {
            switch self {
            case .focus: return "F"
            case .strip: return "S"
            case .panic: return "B"
            case .stronger: return "↑"
            case .weaker: return "↓"
            }
        }
    }

    /// (动作, 是否按下)
    var handler: ((Action, Bool) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var down: Set<UInt32> = []
    /// 注册失败（被占用）的动作
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
            let me = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            me.dispatch(id: hk.id, pressed: pressed)
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), cb, types.count, &types,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    private func dispatch(id: UInt32, pressed: Bool) {
        guard let action = Action(rawValue: id) else { return }
        // 过滤按住时可能出现的重复按下
        if pressed {
            guard !down.contains(id) || action == .stronger || action == .weaker else { return }
            down.insert(id)
        } else {
            down.remove(id)
        }
        handler?(action, pressed)
    }

    /// 按当前修饰键预设（重新）注册全部快捷键
    func register() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        failed.removeAll()
        down.removeAll()
        let mods = ModifierPreset.current.carbon
        for a in Action.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5645_494C), id: a.rawValue) // 'VEIL'
            let st = RegisterEventHotKey(a.keyCode, mods, id, GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref) } else { failed.append(a) }
        }
    }

    static func label(_ a: Action) -> String { ModifierPreset.current.symbol + a.keyLabel }
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
