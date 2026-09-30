import AppKit

/// 菜单栏：图标 + 下拉菜单（开关、滑块、预设、白名单、选项）。
/// 菜单内容只在打开时（menuNeedsUpdate）重建，平时没有任何开销。
final class MenuBar: NSObject, NSMenuDelegate {
    private unowned let core: VeilCore
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    init(core: VeilCore) {
        self.core = core
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
    }

    /// 刷新图标（菜单内容在打开时重建）
    func refresh() {
        let name = core.anyActive ? "eye.slash.fill" : "eye"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Veil")
        img?.isTemplate = true
        item.button?.image = img
        item.button?.toolTip = core.anyActive ? "Veil：模糊中" : "Veil：未开启"
    }

    // MARK: 构建菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hk = core.hotKeys

        // 开关
        let focusItem = toggle("聚焦模式", on: core.focusOn, action: #selector(toggleFocus))
        focusItem.toolTip = "只保留当前主窗口清晰；按住快捷键偷看"
        setShortcut(focusItem, .focus)
        menu.addItem(focusItem)

        let stripItem = toggle("模糊台前调度缩略图", on: core.stripOn, action: #selector(toggleStrip))
        setShortcut(stripItem, .strip)
        menu.addItem(stripItem)
        if !StageStripController.stageManagerEnabled {
            menu.addItem(note("台前调度未开启"))
        }
        let hoverItem = toggle("鼠标悬停时透视缩略图", on: Settings.shared.hoverReveal, action: #selector(toggleHoverReveal))
        hoverItem.indentationLevel = 1
        menu.addItem(hoverItem)

        let panicItem = toggle("紧急隐私（全屏模糊）", on: core.panicOn, action: #selector(togglePanic))
        setShortcut(panicItem, .panic)
        menu.addItem(panicItem)

        if !hk.failed.isEmpty {
            let keys = hk.failed.map { HotKeys.label($0) }.joined(separator: "、")
            menu.addItem(note("\(keys) 被占用，请换修饰键", color: .systemRed))
        }

        // 滑块
        menu.addItem(.separator())
        let s = Settings.shared
        menu.addItem(sliderItem(title: "强度", value: s.intensity, min: 0.1, max: 1, format: { "\(Int(($0 * 100).rounded()))%" }) { [weak self] v in
            Settings.shared.intensity = v
            self?.core.applyStyle(animated: false)
        })
        menu.addItem(sliderItem(title: "暗度", value: s.dim, min: 0, max: 0.8, format: { "\(Int(($0 * 100).rounded()))%" }) { [weak self] v in
            Settings.shared.dim = v
            self?.core.applyStyle(animated: false)
        })
        menu.addItem(sliderItem(title: "缩略图宽度", value: s.stripWidth, min: 0, max: 400, format: { $0 < 1 ? "自动" : "\(Int($0))" }) { [weak self] v in
            Settings.shared.stripWidth = v < 10 ? 0 : v.rounded()
            self?.core.strip.refresh(force: true)
        })

        // 材质
        let matMenu = NSMenu()
        for (i, p) in MaterialPreset.all.enumerated() {
            let mi = NSMenuItem(title: p.name, action: #selector(pickMaterial(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.state = s.material == i ? .on : .off
            matMenu.addItem(mi)
        }
        menu.addItem(submenu("材质：\(MaterialPreset.all[s.material].name)", matMenu))

        // 多显示器聚焦范围
        if NSScreen.screens.count > 1 {
            let scopeMenu = NSMenu()
            for sc in FocusScope.allCases {
                let mi = NSMenuItem(title: sc.name, action: #selector(pickScope(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = sc.rawValue
                mi.state = s.focusScope == sc.rawValue ? .on : .off
                scopeMenu.addItem(mi)
            }
            let cur = FocusScope(rawValue: s.focusScope) ?? .focusedScreen
            menu.addItem(submenu("多屏：\(cur.name)", scopeMenu))
        }

        // 快捷键修饰键
        let modMenu = NSMenu()
        for (i, p) in ModifierPreset.all.enumerated() {
            let mi = NSMenuItem(title: "\(p.symbol) + 字母/方向键", action: #selector(pickModifier(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.state = s.modifierPreset == i ? .on : .off
            modMenu.addItem(mi)
        }
        modMenu.addItem(.separator())
        for (a, desc) in [(HotKeys.Action.focus, "开关聚焦（按住偷看）"), (.strip, "开关缩略图模糊"),
                          (.panic, "紧急隐私"), (.stronger, "增强模糊"), (.weaker, "减弱模糊")] {
            modMenu.addItem(note("\(HotKeys.label(a))  \(desc)"))
        }
        menu.addItem(submenu("快捷键：\(ModifierPreset.current.symbol)", modMenu))

        // 白名单
        menu.addItem(.separator())
        let wlMenu = NSMenu()
        if let app = core.lastFrontApp, let id = app.bundleIdentifier, !s.whitelist.contains(id) {
            let add = NSMenuItem(title: "加入“\(app.localizedName ?? id)”", action: #selector(addFrontToWhitelist), keyEquivalent: "")
            add.target = self
            wlMenu.addItem(add)
        }
        if s.whitelist.isEmpty {
            wlMenu.addItem(note("（空）这些应用在前台时暂停模糊"))
        } else {
            if wlMenu.numberOfItems > 0 { wlMenu.addItem(.separator()) }
            wlMenu.addItem(note("点击移除："))
            for id in s.whitelist {
                let mi = NSMenuItem(title: appName(id), action: #selector(removeWhitelist(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = id
                mi.state = .on
                wlMenu.addItem(mi)
            }
        }
        menu.addItem(submenu("白名单（\(s.whitelist.count)）", wlMenu))

        // 选项
        let opt = NSMenu()
        opt.addItem(toggle("连按两下右 Option 开关聚焦", on: s.doubleOption, action: #selector(toggleDoubleOption)))
        opt.addItem(toggle("接外接显示器时自动开启聚焦", on: s.autoExternal, action: #selector(toggleAutoExternal)))
        opt.addItem(toggle("紧急隐私时静音", on: s.panicMute, action: #selector(togglePanicMute)))
        opt.addItem(toggle("记住开关状态", on: s.rememberState, action: #selector(toggleRemember)))
        opt.addItem(toggle("开机自启", on: core.launchAtLogin, action: #selector(toggleLaunchAtLogin)))
        menu.addItem(submenu("选项", opt))

        let ax = core.accessibilityTrusted
        let axItem = NSMenuItem(title: ax ? "辅助功能权限：已授权" : "辅助功能权限：未授权（点击设置）",
                                action: ax ? nil : #selector(openAX), keyEquivalent: "")
        axItem.target = self
        axItem.isEnabled = !ax
        menu.addItem(axItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Veil", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: 构建辅助

    private func toggle(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.state = on ? .on : .off
        return mi
    }

    private func setShortcut(_ mi: NSMenuItem, _ a: HotKeys.Action) {
        let key: String
        switch a {
        case .focus: key = "f"
        case .strip: key = "s"
        case .panic: key = "b"
        case .stronger: key = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case .weaker: key = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        }
        guard !core.hotKeys.failed.contains(a) else { return }
        mi.keyEquivalent = key
        var m: NSEvent.ModifierFlags = []
        let c = ModifierPreset.current.carbon
        if c & 0x100 != 0 { m.insert(.command) }
        if c & 0x200 != 0 { m.insert(.shift) }
        if c & 0x800 != 0 { m.insert(.option) }
        if c & 0x1000 != 0 { m.insert(.control) }
        mi.keyEquivalentModifierMask = m
    }

    private func note(_ text: String, color: NSColor = .secondaryLabelColor) -> NSMenuItem {
        let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        mi.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color, .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
        ])
        return mi
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        sub.autoenablesItems = false
        mi.submenu = sub
        return mi
    }

    private func sliderItem(title: String, value: Double, min: Double, max: Double,
                            format: @escaping (Double) -> String,
                            onChange: @escaping (Double) -> Void) -> NSMenuItem {
        let mi = NSMenuItem()
        mi.view = SliderRow(title: title, value: value, min: min, max: max, format: format, onChange: onChange)
        return mi
    }

    private func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    // MARK: 动作

    @objc private func toggleFocus() { core.toggleFocus() }
    @objc private func toggleStrip() { core.toggleStrip() }
    @objc private func togglePanic() { core.togglePanic() }

    @objc private func pickMaterial(_ sender: NSMenuItem) {
        Settings.shared.material = sender.tag
        core.applyStyle(animated: true)
    }

    @objc private func pickScope(_ sender: NSMenuItem) {
        Settings.shared.focusScope = sender.tag
        core.focus.reorder(fadeIn: true)
    }

    @objc private func pickModifier(_ sender: NSMenuItem) { core.setModifierPreset(sender.tag) }

    @objc private func addFrontToWhitelist() {
        if let app = core.lastFrontApp { core.addToWhitelist(app) }
    }

    @objc private func removeWhitelist(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { core.removeFromWhitelist(id) }
    }

    @objc private func toggleHoverReveal() {
        Settings.shared.hoverReveal.toggle()
        core.strip.updateHoverMonitor()
    }

    @objc private func toggleDoubleOption() { core.setDoubleOption(!Settings.shared.doubleOption) }
    @objc private func toggleAutoExternal() { Settings.shared.autoExternal.toggle() }
    @objc private func togglePanicMute() { Settings.shared.panicMute.toggle() }
    @objc private func toggleRemember() { core.setRememberState(!Settings.shared.rememberState) }
    @objc private func toggleLaunchAtLogin() { core.setLaunchAtLogin(!core.launchAtLogin) }
    @objc private func openAX() { core.openAccessibilitySettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// 菜单里的一行：“标签  [滑块]  数值”
private final class SliderRow: NSView {
    private let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")
    private let format: (Double) -> String
    private let onChange: (Double) -> Void

    init(title: String, value: Double, min: Double, max: Double,
         format: @escaping (Double) -> String, onChange: @escaping (Double) -> Void) {
        self.format = format
        self.onChange = onChange
        slider = NSSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 28))

        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 20, y: 5, width: 72, height: 18)

        slider.frame = NSRect(x: 92, y: 4, width: 132, height: 20)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(changed)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 226, y: 6, width: 42, height: 16)
        valueLabel.stringValue = format(value)

        addSubview(label)
        addSubview(slider)
        addSubview(valueLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        valueLabel.stringValue = format(slider.doubleValue)
        onChange(slider.doubleValue)
    }
}
