import AppKit

/// 所有可调配置，UserDefaults 持久化。读取走内存缓存，写入即落盘。
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            K.intensity: 0.85,
            K.dim: 0.3,
            K.material: 0,
            K.stripWidth: 0.0,
            K.doubleOption: false,
            K.autoExternal: false,
            K.panicMute: false,
            K.rememberState: true,
            K.focusOn: false,
            K.stripOn: false,
            K.whitelist: [String](),
            K.focusScope: 0,
            K.hoverReveal: true,
            K.topLevelBlur: false,
        ])
    }

    private enum K {
        static let intensity = "intensity"
        static let dim = "dim"
        static let material = "material"
        static let stripWidth = "stripWidth"
        static let doubleOption = "doubleOption"
        static let autoExternal = "autoExternal"
        static let panicMute = "panicMute"
        static let rememberState = "rememberState"
        static let focusOn = "focusOn"
        static let stripOn = "stripOn"
        static let whitelist = "whitelist"
        static let focusScope = "focusScope"
        static let hoverReveal = "hoverReveal"
        static let topLevelBlur = "topLevelBlur"
    }

    /// 聚焦模式下，非工作屏用顶层模糊（盖住菜单栏、程序坞、通知弹窗）。只在两块以上屏幕时生效。
    var topLevelBlur: Bool { get { d.bool(forKey: K.topLevelBlur) } set { d.set(newValue, forKey: K.topLevelBlur) } }

    /// 顶层模糊是否实际生效
    var topLevelBlurEffective: Bool { topLevelBlur && NSScreen.screens.count > 1 }

    /// 鼠标悬停在台前调度区域时透视（渐隐遮罩），移开后恢复
    var hoverReveal: Bool { get { d.bool(forKey: K.hoverReveal) } set { d.set(newValue, forKey: K.hoverReveal) } }

    /// 聚焦范围，见 FocusScope
    var focusScope: Int {
        get { d.integer(forKey: K.focusScope) }
        set { d.set(newValue, forKey: K.focusScope) }
    }

    /// 模糊强度 0.1...1（毛玻璃层的不透明度）
    var intensity: Double {
        get { d.double(forKey: K.intensity) }
        set { d.set(min(1, max(0.1, newValue)), forKey: K.intensity) }
    }

    /// 暗度 0...0.8（叠加黑色的不透明度）
    var dim: Double {
        get { d.double(forKey: K.dim) }
        set { d.set(min(0.8, max(0, newValue)), forKey: K.dim) }
    }

    /// 材质预设下标，见 MaterialPreset.all
    var material: Int {
        get { min(max(0, d.integer(forKey: K.material)), MaterialPreset.all.count - 1) }
        set { d.set(newValue, forKey: K.material) }
    }

    /// 缩略图遮罩宽度；0 表示自动检测
    var stripWidth: Double {
        get { d.double(forKey: K.stripWidth) }
        set { d.set(newValue, forKey: K.stripWidth) }
    }

    var doubleOption: Bool { get { d.bool(forKey: K.doubleOption) } set { d.set(newValue, forKey: K.doubleOption) } }
    var autoExternal: Bool { get { d.bool(forKey: K.autoExternal) } set { d.set(newValue, forKey: K.autoExternal) } }
    var panicMute: Bool { get { d.bool(forKey: K.panicMute) } set { d.set(newValue, forKey: K.panicMute) } }
    var rememberState: Bool { get { d.bool(forKey: K.rememberState) } set { d.set(newValue, forKey: K.rememberState) } }
    var focusOn: Bool { get { d.bool(forKey: K.focusOn) } set { d.set(newValue, forKey: K.focusOn) } }
    var stripOn: Bool { get { d.bool(forKey: K.stripOn) } set { d.set(newValue, forKey: K.stripOn) } }

    /// 白名单（bundle id）：这些应用在前台时暂停模糊
    var whitelist: [String] {
        get { d.stringArray(forKey: K.whitelist) ?? [] }
        set { d.set(newValue, forKey: K.whitelist) }
    }
}

/// 公开 API 下的材质预设：不同材质的模糊感和底色不同。
/// tint 是叠在毛玻璃上的着色（不透明度由“暗度”控制），用动态颜色随系统深浅色切换。
struct MaterialPreset {
    let name: String
    let material: NSVisualEffectView.Material
    let appearance: NSAppearance.Name?
    let tint: NSColor

    /// 深色模式压暗、浅色模式用柔和的暖灰，避免大面积高亮白色刺眼
    static let softTint = NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)
            : NSColor(srgbRed: 0.42, green: 0.40, blue: 0.37, alpha: 1)
    }

    static let all: [MaterialPreset] = [
        MaterialPreset(name: "护眼柔和（跟随深浅色）", material: .underWindowBackground, appearance: nil, tint: softTint),
        MaterialPreset(name: "深色磨砂", material: .hudWindow, appearance: .darkAqua, tint: .black),
        MaterialPreset(name: "浅色磨砂", material: .fullScreenUI, appearance: .aqua, tint: softTint),
        MaterialPreset(name: "深色厚玻璃", material: .fullScreenUI, appearance: .darkAqua, tint: .black),
        MaterialPreset(name: "轻薄玻璃", material: .popover, appearance: nil, tint: softTint),
    ]
}

/// 多显示器下聚焦模式如何决定“工作屏”：工作屏只保留当前窗口清晰，其他屏幕整块模糊
enum FocusScope: Int, CaseIterable {
    case followMouse = 0, followFocus

    static var current: FocusScope { FocusScope(rawValue: Settings.shared.focusScope) ?? .followMouse }

    var name: String {
        switch self {
        case .followMouse: return "跟随鼠标"
        case .followFocus: return "跟随焦点窗口"
        }
    }

    var detail: String {
        switch self {
        case .followMouse: return "鼠标所在屏幕清晰，其他屏幕模糊"
        case .followFocus: return "焦点窗口所在屏幕清晰，其他屏幕模糊"
        }
    }
}

// MARK: - 自定义快捷键存储
//
// 保存在 UserDefaults 的 "shortcuts" 字典里：{ 动作键名: [keyCode, mods] }
// 没有记录 = 用默认值；记录为空数组 = 用户清空了（不注册）。

extension Settings {
    private static let shortcutsKey = "shortcuts"

    private var shortcutDict: [String: [Int]] {
        get { UserDefaults.standard.dictionary(forKey: Self.shortcutsKey) as? [String: [Int]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.shortcutsKey) }
    }

    func shortcut(for a: HotKeys.Action) -> Shortcut? {
        guard let v = shortcutDict[a.key] else { return a.defaultShortcut }
        guard v.count == 2 else { return nil }
        return Shortcut(keyCode: UInt32(v[0]), mods: UInt32(v[1]))
    }

    /// 设置快捷键；nil = 清空（不使用快捷键）
    func setShortcut(_ s: Shortcut?, for a: HotKeys.Action) {
        var dict = shortcutDict
        dict[a.key] = s.map { [Int($0.keyCode), Int($0.mods)] } ?? []
        shortcutDict = dict
    }

    func resetShortcuts() {
        UserDefaults.standard.removeObject(forKey: Self.shortcutsKey)
    }

    /// 旧版本只能选修饰键预设；升级时把它换算成每个动作的具体快捷键，保持原来的按法
    func migrateModifierPreset() {
        let d = UserDefaults.standard
        guard d.object(forKey: "modifierPreset") != nil else { return }
        let presets: [UInt32] = [
            Shortcut.control | Shortcut.option | Shortcut.cmd,
            Shortcut.control | Shortcut.option | Shortcut.shift,
            Shortcut.control | Shortcut.shift | Shortcut.cmd,
            Shortcut.control | Shortcut.option | Shortcut.shift | Shortcut.cmd,
        ]
        let i = d.integer(forKey: "modifierPreset")
        d.removeObject(forKey: "modifierPreset")
        guard i > 0, i < presets.count, d.object(forKey: Self.shortcutsKey) == nil else { return }
        for a in HotKeys.Action.allCases where a != .quit {
            setShortcut(Shortcut(keyCode: a.defaultShortcut.keyCode, mods: presets[i]), for: a)
        }
    }
}
