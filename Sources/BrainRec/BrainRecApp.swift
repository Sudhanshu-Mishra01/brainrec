import SwiftUI

@main
struct BrainRecApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("BrainRec", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.isRecordingActive ? "record.circle.fill" : "record.circle")
                if model.isRecordingActive {
                    Text(model.elapsedString).monospacedDigit()
                }
            }
        }
    }
}
