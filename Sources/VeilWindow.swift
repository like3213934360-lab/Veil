import AppKit

/// 模糊样式：强度（毛玻璃不透明度）、暗度、材质
struct VeilStyle: Equatable {
    var intensity: Double
    var dim: Double
    var material: Int

    static var current: VeilStyle {
        let s = Settings.shared
        return VeilStyle(intensity: s.intensity, dim: s.dim, material: s.material)
    }
}

/// 坐标换算：CG/AX 用“主屏左上角为原点、y 向下”，Cocoa 用“主屏左下角为原点、y 向上”。
/// 主屏 = 原点为 (0,0) 的那块屏幕（带菜单栏），不一定是 NSScreen.screens.first。
enum Coords {
    static var primaryHeight: CGFloat {
        let screens = NSScreen.screens
        return (screens.first { $0.frame.origin == .zero } ?? screens.first)?.frame.height ?? 0
    }

    /// CG 矩形（左上原点）-> Cocoa 矩形（左下原点）
    static func toCocoa(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.minY - r.height, width: r.width, height: r.height)
    }
}

enum Motion {
    /// 尊重系统“减少动态效果”
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func duration(_ d: TimeInterval) -> TimeInterval { reduced ? 0 : d }

    // 所有动画时长集中在这里调整（秒）
    static let fadeIn: TimeInterval = 0.16       // 遮罩出现
    static let fadeOut: TimeInterval = 0.12      // 遮罩消失
    static let style: TimeInterval = 0.12        // 强度/暗度/材质变化
    static let follow: TimeInterval = 0.06       // 拖动窗口时遮罩跟随
    static let settle: TimeInterval = 0.14       // 缩略图条重排后遮罩对齐
    static let revealIn: TimeInterval = 0.1      // 悬停透视：变透明
    static let revealOut: TimeInterval = 0.16    // 悬停透视：恢复模糊
    static let revealLeaveDelay: TimeInterval = 0.06 // 鼠标离开后多久开始恢复
}

/// 遮罩窗口：无边框、透明、不接收鼠标、不抢焦点。
/// 模糊由 WindowServer 通过 NSVisualEffectView(.behindWindow) 在 GPU 上完成；
/// 暗度用纯 CALayer 背景色实现，没有任何位图 backing store。
final class VeilWindow: NSWindow {
    private let effect = NSVisualEffectView()
    private let tintView = TintView()
    private var style: VeilStyle?
    /// 动画代数：防止旧的“隐藏完成回调”把新显示的窗口收起
    private var generation = 0
    private(set) var wantsVisible = false

    init(frame: NSRect, level: NSWindow.Level) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        alphaValue = 0

        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]

        effect.frame = root.bounds
        effect.autoresizingMask = [.width, .height]
        effect.blendingMode = .behindWindow
        effect.state = .active // 本程序永远不是活跃应用，必须强制 active
        root.addSubview(effect)

        tintView.frame = root.bounds
        tintView.autoresizingMask = [.width, .height]
        tintView.alphaValue = 0
        root.addSubview(tintView)

        contentView = root
        apply(.current, animated: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 应用样式；animated 时 0.15s 平滑过渡
    func apply(_ s: VeilStyle, animated: Bool) {
        guard s != style else { return }
        let preset = MaterialPreset.all[min(max(0, s.material), MaterialPreset.all.count - 1)]
        if style?.material != s.material {
            effect.material = preset.material
            effect.appearance = preset.appearance.flatMap { NSAppearance(named: $0) }
            tintView.appearance = effect.appearance
            tintView.tint = preset.tint
        }
        let dur = animated ? Motion.duration(Motion.style) : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = dur
            ctx.allowsImplicitAnimation = dur > 0
            (dur > 0 ? effect.animator() : effect).alphaValue = s.intensity
            (dur > 0 ? tintView.animator() : tintView).alphaValue = s.dim
        }
        style = s
    }

    /// 淡入显示。ordering 由调用方传入（例如排在某窗口下方）。
    /// 用稍长的缓入缓出，避免整屏亮度突变刺眼。
    func show(duration: TimeInterval = Motion.fadeIn, order: (VeilWindow) -> Void = { $0.orderFrontRegardless() }) {
        generation += 1
        wantsVisible = true
        order(self)
        let target: CGFloat = revealed ? 0 : 1
        let dur = Motion.duration(duration)
        if dur == 0 { alphaValue = target; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = dur
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = target
        }
    }

    /// 悬停透视：窗口保持在屏幕上，只把透明度渐变到 0（鼠标移开后再渐变回来）
    private(set) var revealed = false

    func setRevealed(_ on: Bool, duration: TimeInterval) {
        guard on != revealed else { return }
        revealed = on
        guard wantsVisible else { return }
        let target: CGFloat = on ? 0 : 1
        let dur = Motion.duration(duration)
        if dur == 0 { alphaValue = target; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = dur
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = target
        }
    }

    /// 淡出，完成后 orderOut，让 WindowServer 不再为它做合成（GPU 开销归零）
    func hide(duration: TimeInterval = Motion.fadeOut) {
        guard wantsVisible || isVisible else { return }
        generation += 1
        wantsVisible = false
        let gen = generation
        let dur = Motion.duration(duration)
        if dur == 0 { alphaValue = 0; orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = dur
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == gen else { return }
            self.orderOut(nil)
        })
    }

    /// 目标位置（动画进行中 frame 还是中间值，用它判断是否需要再动）
    private var targetFrame: NSRect?

    /// 调整位置大小。animated 时用短时缓动“追”到目标：
    /// 拖动过程中新目标不断到来，每次都从当前中间位置平滑接上，看起来是连续跟随而不是跳变。
    func fit(_ rect: NSRect, animated: Bool = false, duration: TimeInterval = Motion.follow) {
        guard rect != (targetFrame ?? frame) else { return }
        targetFrame = rect
        let dur = Motion.duration(duration)
        // 不可见时直接到位，避免显示时从旧位置滑过来
        guard animated, dur > 0, wantsVisible, isVisible else {
            setFrame(rect, display: false)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = dur
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            animator().setFrame(rect, display: true)
        }
    }
}

/// 着色层：纯 layer 背景色，系统深浅色切换时 updateLayer 自动重新解析动态颜色
final class TintView: NSView {
    var tint: NSColor = .black { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        var c: CGColor = NSColor.black.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { c = self.tint.cgColor }
        layer?.backgroundColor = c
    }
}

/// 一组“每块屏幕一个”的遮罩，屏幕变化时按需重建
final class ScreenVeils {
    private(set) var windows: [VeilWindow] = []
    private let level: NSWindow.Level
    private let rectFor: (NSScreen) -> NSRect?

    init(level: NSWindow.Level, rect: @escaping (NSScreen) -> NSRect? = { $0.frame }) {
        self.level = level
        self.rectFor = rect
    }

    /// 同步到当前屏幕布局；返回每个窗口对应的矩形是否有效
    /// resize=false：只补齐/删除窗口，不改已有窗口位置（由调用方负责，可能带动画）
    func sync(resize: Bool = true) {
        let screens = NSScreen.screens
        while windows.count > screens.count { windows.removeLast().orderOut(nil) }
        for (i, screen) in screens.enumerated() {
            let rect = rectFor(screen) ?? .zero
            if i < windows.count {
                if resize { windows[i].fit(rect) }
            } else {
                windows.append(VeilWindow(frame: rect, level: level))
            }
        }
    }

    func apply(_ s: VeilStyle, animated: Bool) { windows.forEach { $0.apply(s, animated: animated) } }
    func hide(duration: TimeInterval = Motion.fadeOut) { windows.forEach { $0.hide(duration: duration) } }
    var isShown: Bool { windows.contains { $0.wantsVisible } }
}
