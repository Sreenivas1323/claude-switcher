import SwiftUI

@main
struct ClaudeSwitcherApp: App {
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        if let path = Snapshot.outputPath { Snapshot.run(model: model, to: path) }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Icon plus the active account's tightest limit, e.g. "✳ 42%".
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let id = model.activeID, let usage = model.usage[id] {
            let pct = Int(AppModel.effective(usage).rounded())
            Image(systemName: pct >= 90 ? "exclamationmark.circle" : "sparkle")
            Text("\(pct)%")
        } else {
            Image(systemName: "sparkle")
        }
    }
}
