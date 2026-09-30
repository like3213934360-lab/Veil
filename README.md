# Veil

**macOS 防窥模糊小工具 · A lightweight privacy blur for macOS**

[中文](#中文) | [English](#english)

---

## 中文

Veil 是一个纯原生 AppKit 编写的菜单栏小工具，用系统毛玻璃（`NSVisualEffectView`）挡住你不想让旁人看到的内容：

- **聚焦模式**：只保留当前主窗口清晰，其他窗口和桌面全部模糊。
- **台前调度缩略图模糊**：给台前调度侧边的缩略图条加一层毛玻璃，鼠标悬停时自动透视。
- **紧急隐私**：一键全屏模糊（包括当前窗口），可选同时静音。

模糊完全由 WindowServer 在 GPU 上合成，Veil 本身不读取任何屏幕画面，**不需要屏幕录制权限**。

### 特点

- 空闲时 CPU ≈ 0%，内存约 14 MB，安装包约 200 KB，无第三方依赖。
- 全部事件驱动，没有轮询定时器。
- 自适应任意屏幕尺寸、分辨率、多显示器排列，自动识别台前调度在左侧还是右侧。
- 遮罩跟随窗口移动和缩放，带平滑过渡动画；尊重系统“减少动态效果”设置。
- 深浅色自适应的“护眼柔和”材质，避免大面积刺眼亮色。

### 功能

| 功能 | 说明 |
|---|---|
| 聚焦模式 | 遮罩排在当前主窗口正下方，窗口移动/缩放无需任何处理 |
| 多屏范围 | 仅模糊主窗口所在屏幕 / 每块屏幕保留最前窗口 / 模糊所有屏幕 |
| 缩略图模糊 | 自动定位缩略图条，窗口挤占时自动让位 |
| 悬停透视 | 鼠标移到缩略图区域时渐隐，离开后恢复 |
| 按住偷看 | 按住聚焦快捷键超过 0.3 秒，临时解除模糊，松开恢复 |
| 紧急隐私 | 全屏最高层级模糊，可选静音并在恢复时还原 |
| 强度调节 | 菜单栏滑块调节强度、暗度、缩略图宽度，多种材质预设 |
| 白名单 | 指定应用在前台时自动暂停模糊（如视频播放器、Keynote） |
| 外接显示器 | 接入外接屏时自动开启聚焦模式，拔出时自动关闭 |
| 开机自启 | 基于 `SMAppService` |

### 快捷键

所有快捷键都可以在菜单 **“自定义快捷键…”** 里修改：点击按钮后直接按下新的组合键，`⎋` 取消，`⌫` 清空。

| 默认快捷键 | 作用 |
|---|---|
| `⌃⌥⌘F` | 开关聚焦模式；按住 = 偷看 |
| `⌃⌥⌘S` | 开关缩略图模糊 |
| `⌃⌥⌘B` | 紧急隐私（全屏模糊） |
| `⌃⌥⌘↑` / `⌃⌥⌘↓` | 增强 / 减弱模糊 |
| `⌘1`（Windows 键盘上是 Win+1） | **强制退出 Veil**，任何状态下都能立即退出 |
| 连按两下右 Option | 开关聚焦模式（可选，默认关闭） |

快捷键被其他应用占用时，菜单和快捷键窗口中会以红字提示。
只用 `⌘` 的组合（例如 `⌘1`）会覆盖其他应用里相同的快捷键，窗口中也会提示。

### 系统要求

- macOS 13 及以上（在 macOS 27 / Apple Silicon 上开发测试）
- 只需 Xcode Command Line Tools，不需要完整的 Xcode

### 构建与安装

```bash
git clone https://github.com/like3213934360-lab/Veil.git
cd Veil
./build.sh            # 构建到 build/Veil.app
./build.sh install    # 构建并安装到 ~/Applications，然后启动
```

### 权限

Veil 需要 **辅助功能** 权限，用来感知同一应用内的窗口切换、窗口移动和缩放：

系统设置 → 隐私与安全性 → 辅助功能 → 添加 `~/Applications/Veil.app` 并打开开关，然后重启 Veil。

> **关于重新编译后权限失效**：ad-hoc 签名每次编译都会变化，系统会把授权作废。
> `build.sh` 会优先使用专用钥匙串 `veil-signing` 中名为 “Veil Local Signing” 的自签名证书，签名身份固定后，重新编译不再需要重新授权。
> 创建方法见下方“固定签名证书”。

<details>
<summary>固定签名证书（可选）</summary>

```bash
KC=~/Library/Keychains/veil-signing.keychain-db
PW=veil-local
security create-keychain -p $PW "$KC"
security set-keychain-settings "$KC"
openssl req -x509 -newkey rsa:2048 -nodes -keyout k.pem -out c.pem -days 3650 \
  -subj "/CN=Veil Local Signing" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -legacy -inkey k.pem -in c.pem -out v.p12 -passout pass:veil -name "Veil Local Signing"
security import v.p12 -k "$KC" -P veil -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $PW "$KC"
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
rm k.pem c.pem v.p12
```

钥匙串密码可通过环境变量 `VEIL_KEYCHAIN_PASSWORD` 覆盖。
</details>

### 项目结构

```
Sources/
  main.swift                 入口，后台运行（无程序坞图标）
  VeilCore.swift             状态机：快捷键、暂停逻辑、白名单、外接屏、开机自启
  VeilWindow.swift           遮罩窗口、动画时长、坐标换算
  FocusController.swift      聚焦模式：AXObserver + CGWindowList 定位主窗口
  StageStripController.swift 台前调度缩略图遮罩与悬停透视
  HotKeys.swift              Carbon 全局快捷键（可自定义）、强制退出、连按右 Option
  ShortcutsWindow.swift      自定义快捷键窗口与录制按钮
  MenuBar.swift              菜单栏图标与菜单
  Settings.swift             配置项（UserDefaults）、材质与快捷键预设
Resources/Info.plist
build.sh
```

### 已知限制

- 全屏应用所在的屏幕不加聚焦遮罩（遮罩无法排到全屏窗口下方）。
- 录屏或共享屏幕时，对方看到的也是模糊后的画面。
- 台前调度开启“自动隐藏”时，缩略图滑出后遮罩要等下一次窗口事件才会出现。
- 查找焦点窗口 ID 使用了 `_AXUIElementGetWindow`（通过 `dlsym` 动态查找，找不到时自动退回公开 API）。

### 退出

菜单栏图标 → 退出 Veil，或终端执行 `pkill -x Veil`。

---

## English

Veil is a tiny menu bar utility written in pure native AppKit. It uses the system's frosted glass (`NSVisualEffectView`) to hide what you don't want onlookers to see:

- **Focus mode** — only the current main window stays sharp; every other window and the desktop are blurred.
- **Stage Manager strip blur** — frosts the Stage Manager thumbnail strip, and reveals it when you hover over it.
- **Panic mode** — one key blurs the whole screen (including the current window), optionally muting audio.

All blurring is composited by WindowServer on the GPU. Veil never reads screen contents, so **no Screen Recording permission is needed**.

### Highlights

- ~0% CPU when idle, ~14 MB memory, ~200 KB app bundle, zero third-party dependencies.
- Fully event-driven, no polling timers.
- Adapts to any screen size, resolution and multi-display arrangement; detects whether the Stage Manager strip is on the left or right.
- Masks follow window moves and resizes with smooth transitions; respects the system "Reduce motion" setting.
- An eye-friendly "Soft" material that adapts to light/dark mode and avoids large glaring bright areas.

### Features

| Feature | Description |
|---|---|
| Focus mode | The mask sits directly below the main window, so moving/resizing it needs no work |
| Multi-display scope | Blur only the focused screen / keep the frontmost window on each screen / blur all screens |
| Strip blur | Locates the thumbnail strip automatically and yields space when a window overlaps it |
| Hover reveal | Fades out while the pointer is over the strip, fades back when it leaves |
| Hold to peek | Hold the focus hotkey for 0.3 s to temporarily lift the blur; release to restore |
| Panic mode | Topmost full-screen blur, optional mute that is restored afterwards |
| Adjustments | Menu bar sliders for intensity, dimming and strip width; several material presets |
| Whitelist | Pause blurring while specific apps are frontmost (video players, Keynote, …) |
| External display | Auto-enable focus mode when an external display is connected, disable when removed |
| Launch at login | Via `SMAppService` |

### Hotkeys

Every hotkey can be changed from **"自定义快捷键…" (Customize Shortcuts)** in the menu: click a button and press the new combination; `⎋` cancels, `⌫` clears.

| Default hotkey | Action |
|---|---|
| `⌃⌥⌘F` | Toggle focus mode; hold = peek |
| `⌃⌥⌘S` | Toggle strip blur |
| `⌃⌥⌘B` | Panic mode (full-screen blur) |
| `⌃⌥⌘↑` / `⌃⌥⌘↓` | Stronger / weaker blur |
| `⌘1` (Win+1 on a Windows keyboard) | **Force quit Veil** — works in any state |
| Double-tap right Option | Toggle focus mode (optional, off by default) |

If a hotkey is already taken, the menu and the shortcuts window show a red warning.
Combinations using only `⌘` (such as `⌘1`) override the same shortcut in other apps; the window warns about this too.

### Requirements

- macOS 13 or later (developed and tested on macOS 27 / Apple Silicon)
- Xcode Command Line Tools only — full Xcode is not required

### Build & install

```bash
git clone https://github.com/like3213934360-lab/Veil.git
cd Veil
./build.sh            # builds build/Veil.app
./build.sh install    # builds, installs to ~/Applications and launches
```

### Permissions

Veil needs **Accessibility** permission to observe window switches within an app and window moves/resizes:

System Settings → Privacy & Security → Accessibility → add `~/Applications/Veil.app`, turn it on, then restart Veil.

> **Permission lost after rebuilding?** Ad-hoc signatures change on every build, so macOS invalidates the grant.
> `build.sh` prefers a self-signed certificate named "Veil Local Signing" in a dedicated `veil-signing` keychain. With a stable signing identity, rebuilds keep the permission.
> See "Stable signing certificate" in the Chinese section above for the setup commands (they are identical).

The keychain password can be overridden with the `VEIL_KEYCHAIN_PASSWORD` environment variable.

### Project layout

```
Sources/
  main.swift                 Entry point, runs as a background (accessory) app
  VeilCore.swift             State machine: hotkeys, suspension, whitelist, displays, login item
  VeilWindow.swift           Mask window, animation timings, coordinate conversion
  FocusController.swift      Focus mode: AXObserver + CGWindowList to find the main window
  StageStripController.swift Stage Manager strip mask and hover reveal
  HotKeys.swift              Carbon global hotkeys (customizable), force quit, double-tap right Option
  ShortcutsWindow.swift      Shortcut editor window and recorder
  MenuBar.swift              Status item and menu
  Settings.swift             Settings (UserDefaults), material and modifier presets
Resources/Info.plist
build.sh
```

### Known limitations

- Screens showing a full-screen app get no focus mask (a mask cannot be ordered below a full-screen window).
- Screen recordings and screen sharing show the blurred result too.
- With Stage Manager "auto-hide" enabled, the mask appears on the next window event after the strip slides in.
- The focused window ID is obtained via `_AXUIElementGetWindow` (resolved with `dlsym`, falling back to public APIs if unavailable).

### Quit

Menu bar icon → Quit Veil, or run `pkill -x Veil`.

---

## License

MIT
