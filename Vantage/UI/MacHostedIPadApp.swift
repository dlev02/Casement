#if os(iOS)
import SwiftUI

/// The iPad app running on an Apple silicon Mac ("Designed for iPad", e.g. a TestFlight install
/// on the Mac). The native Mac app (`MacRootView`) is a different build; this is the iPad's
/// screens in a Mac window, so a few iPad habits need softening there.
enum MacHostedIPadApp {
    static let isRunning = ProcessInfo.processInfo.isiOSAppOnMac
}

/// The device list's bar when the iPad app runs on a Mac. The window's title bar already says
/// "Casement", so the bar drops its large title (which also stops it jumping to the window's
/// edge when the search field takes focus), and the bar keeps no background of its own, so it
/// doesn't show up as a lighter band under the title bar when the pointer comes near.
struct MacHostedListBar: ViewModifier {
    func body(content: Content) -> some View {
        if MacHostedIPadApp.isRunning {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        } else {
            content
        }
    }
}
#endif
