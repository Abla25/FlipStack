import AppKit

// The app delegate owns a @MainActor model. main.swift's top-level code is not
// main-actor isolated, so hop onto the main actor explicitly for setup.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}
