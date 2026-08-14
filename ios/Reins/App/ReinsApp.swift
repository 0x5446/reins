/// The app's entry point.

import SwiftUI

@main
struct ReinsApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Palette.accent)
                .onOpenURL { url in
                    // A pairing link opened from Messages, Mail, or the Mac's
                    // own terminal. Handling it here means the QR and the link
                    // are the same path, so there is one thing to get right.
                    model.open(url: url)
                }
                .task {
                    model.restoreLastConnection()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.enteredForeground()
            case .background, .inactive: model.enteredBackground()
            @unknown default: break
            }
        }
    }
}
