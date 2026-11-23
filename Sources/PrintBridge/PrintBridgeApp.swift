import BrotherKit
import SwiftUI

@main
struct PrintBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        L10n.activate()
    }

    var body: some Scene {
        // Jediné okno – otevření souboru z Finderu tak nevytváří další okna.
        Window("PrintBridge", id: "main") {
            RootView()
                .environment(AppModel.shared)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(AppModel.shared)
        }
    }
}
