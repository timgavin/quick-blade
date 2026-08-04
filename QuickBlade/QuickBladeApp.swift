import SwiftUI

@main
struct QuickBladeApp: App {
    var body: some Scene {
        // Single window — this is a launch-once host, not a document app.
        // Hidden titlebar: the header shows the app name, and a visible titlebar
        // makes the space above the logo unmatchable with the bottom padding.
        Window("Quick Blade", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}
