import AppKit

// 入口：纯 AppKit，后台运行，不显示程序坞图标
let app = NSApplication.shared
let core = VeilCore()
app.delegate = core
app.setActivationPolicy(.accessory)
app.run()
