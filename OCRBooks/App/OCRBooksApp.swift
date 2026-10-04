import SwiftUI

@main
struct OCRBooksApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1150, minHeight: 720)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Abrir PDF…") {
                    state.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
