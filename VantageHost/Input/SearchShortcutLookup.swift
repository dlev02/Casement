import AppKit

extension SearchShortcut {
    /// Where ⌘Space should go instead of being typed: Raycast's URL when Spotlight has given the
    /// shortcut up and Raycast is running; nil to send the keystroke (Spotlight, Alfred, and other
    /// system or Carbon hot keys answer it).
    nonisolated static func launcherURL() -> URL? {
        let hotKeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        guard !spotlightOwnsCommandSpace(hotKeys),
              !NSRunningApplication.runningApplications(withBundleIdentifier: raycastBundleID).isEmpty else { return nil }
        return URL(string: raycastURL)
    }
}
