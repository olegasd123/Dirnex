import AppKit

// Programmatic entry point — no storyboard, no MainMenu.xib.
// Dirnex is keyboard-first and its UI is built in code (AppKit panels with
// SwiftUI chrome), so we own the app lifecycle explicitly from here.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
