import AppKit
import SwiftUI

/// `ClaudeSwitcher --snapshot out.png` renders the menu panel with live data to a PNG
/// and exits. Useful for checking the UI without clicking the menu bar.
enum Snapshot {
    static var outputPath: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func run(model: AppModel, to path: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            let host = NSHostingView(rootView: MenuPanel().environmentObject(model))
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
            window.backgroundColor = .windowBackgroundColor
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}
