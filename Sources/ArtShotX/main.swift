import AppKit

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let appDelegate = AppDelegate()
    application.setActivationPolicy(.accessory)
    application.delegate = appDelegate
    withExtendedLifetime(appDelegate) { application.run() }
}
