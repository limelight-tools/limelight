import AppKit

let app = NSApplication.shared
let delegate = AppDelegate(config: AppConfig.fromCommandLine())
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
