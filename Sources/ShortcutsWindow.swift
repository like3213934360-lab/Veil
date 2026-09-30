import AppKit
import Carbon.HIToolbox

/// 自定义快捷键窗口：每个动作一行，点击右侧按钮后直接按下新的组合键即可。
/// 按 ⎋ 取消录制，按 ⌫ 清空该快捷键。
final class ShortcutsWindow: NSObject, NSWindowDelegate {
    private unowned let core: VeilCore
    private var window: NSWindow?
    private var recorders: [HotKeys.Action: ShortcutRecorder] = [:]
    private let status = NSTextField(labelWithString: "")

    init(core: VeilCore) {
        self.core = core
        super.init()
    }

    func show() {
        if window == nil { build() }
        reloadAll()
        // 本程序是后台应用，需要主动激活才能接收键盘输入
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 10),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Veil 快捷键"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.level = .modalPanel // 高于遮罩，开着模糊时也能操作

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        rows.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let tip = NSTextField(wrappingLabelWithString: "点击右侧按钮，然后按下新的组合键。⎋ 取消录制，⌫ 清空。\nWindows 键盘上的 Win 键就是 ⌘。")
        tip.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tip.textColor = .secondaryLabelColor
        tip.preferredMaxLayoutWidth = 420
        rows.addArrangedSubview(tip)

        for a in HotKeys.Action.allCases {
            let label = NSTextField(labelWithString: a.title)
            label.widthAnchor.constraint(equalToConstant: 230).isActive = true
            if a == .quit { label.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }

            let rec = ShortcutRecorder()
            rec.onRecordStart = { [weak self] in self?.core.hotKeys.unregisterAll() }
            rec.onRecordEnd = { [weak self] in self?.core.shortcutsChanged(); self?.updateStatus() }
            rec.onChange = { [weak self] sc in self?.set(sc, for: a) }
            rec.widthAnchor.constraint(equalToConstant: 170).isActive = true
            recorders[a] = rec

            let row = NSStackView(views: [label, rec])
            row.spacing = 12
            rows.addArrangedSubview(row)
        }

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .systemRed
        status.preferredMaxLayoutWidth = 420
        status.lineBreakMode = .byWordWrapping
        rows.addArrangedSubview(status)

        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetDefaults))
        let done = NSButton(title: "完成", target: self, action: #selector(close))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [reset, NSView(), done])
        buttons.widthAnchor.constraint(equalToConstant: 420).isActive = true
        rows.addArrangedSubview(buttons)

        w.contentView = rows
        w.setContentSize(rows.fittingSize)
        window = w
    }

    private func set(_ sc: Shortcut?, for a: HotKeys.Action) {
        // 和其他动作重复时，把对方清空，保证每个组合只对应一个动作
        if let sc {
            for other in HotKeys.Action.allCases where other != a && other.shortcut == sc {
                Settings.shared.setShortcut(nil, for: other)
            }
        }
        Settings.shared.setShortcut(sc, for: a)
        reloadAll()
    }

    private func reloadAll() {
        for (a, r) in recorders { r.shortcut = a.shortcut }
        updateStatus()
    }

    private func updateStatus() {
        var lines: [String] = []
        let failed = core.hotKeys.failed
        if !failed.isEmpty {
            lines.append("被其他应用占用，未生效：" + failed.map { HotKeys.label($0) }.joined(separator: "、"))
        }
        let overriding = HotKeys.Action.allCases.filter { $0.shortcut?.overridesAppShortcuts == true }
        if !overriding.isEmpty {
            lines.append("提示：" + overriding.map { HotKeys.label($0) }.joined(separator: "、")
                         + " 只用了 ⌘，会覆盖其他应用里相同的快捷键（例如浏览器 ⌘1 切换标签页）。")
        }
        if HotKeys.Action.quit.shortcut == nil {
            lines.append("强制退出没有快捷键：Veil 出问题时只能用终端 pkill -x Veil 退出。")
        }
        status.stringValue = lines.joined(separator: "\n")
        status.textColor = failed.isEmpty ? .secondaryLabelColor : .systemRed
        status.isHidden = lines.isEmpty
        if let w = window, let v = w.contentView { w.setContentSize(v.fittingSize) }
    }

    @objc private func resetDefaults() {
        Settings.shared.resetShortcuts()
        core.shortcutsChanged()
        reloadAll()
    }

    @objc private func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        recorders.values.forEach { $0.cancelRecording() }
        core.shortcutsChanged()
    }
}

/// 快捷键录制按钮
final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut? { didSet { refreshTitle() } }
    var onChange: ((Shortcut?) -> Void)?
    var onRecordStart: (() -> Void)?
    var onRecordEnd: (() -> Void)?
    private var monitor: Any?
    private var recording = false { didSet { refreshTitle() } }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refreshTitle() {
        if recording {
            title = "请按下组合键…"
        } else {
            title = shortcut?.display ?? "未设置"
        }
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    @objc private func clicked() {
        recording ? cancelRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        onRecordStart?()
        // 本地监听：窗口是 key 时拦截按键，不让它们传到别处
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            guard let self, self.recording else { return e }
            self.handle(e)
            return nil
        }
    }

    private func handle(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(e.keyCode) {
        case kVK_Escape where mods.isEmpty:
            cancelRecording()
        case kVK_Delete where mods.isEmpty, kVK_ForwardDelete where mods.isEmpty:
            onChange?(nil)
            cancelRecording()
        default:
            let sc = Shortcut(event: e)
            guard sc.isValid else { NSSound.beep(); return } // 需要至少一个修饰键
            onChange?(sc)
            cancelRecording()
        }
    }

    func cancelRecording() {
        guard recording else { return }
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        onRecordEnd?()
    }
}
