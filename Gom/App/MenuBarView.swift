import AppKit
import GomCore
import SwiftUI

struct MenuBarLabel: View {
    let queue: DownloadQueue

    var body: some View {
        let downloading = queue.items.filter { $0.state == .downloading }.count
        if downloading > 0 {
            // Skip the speed until there's a sample; the formatter spells 0 as "Zero KB".
            let speed = Int64(queue.speeds.values.reduce(0, +))
            let title = speed > 0 ? "\(downloading) · \(ByteCountFormatter.string(fromByteCount: speed, countStyle: .file))/s" : "\(downloading)"
            Label(title, systemImage: "arrow.down.circle")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "arrow.down.circle")
        }
    }
}

struct MenuBarView: View {
    let queue: DownloadQueue

    private var active: [DownloadRecord] {
        queue.items.filter { [.downloading, .queued, .paused].contains($0.state) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if active.isEmpty {
                Text("No active downloads")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(active) { item in
                            DownloadRow(item: item, speed: queue.speeds[item.id], queue: queue)
                                .padding(.horizontal, 12)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)   // a bare ScrollView collapses to zero height in the popover
            }
            Divider()
            HStack {
                Button("Pause All", systemImage: "pause.fill") { queue.pauseAll() }
                    .disabled(!active.contains { $0.state != .paused })
                Button("Resume All", systemImage: "play.fill") { queue.resumeAll() }
                    .disabled(!active.contains { $0.state == .paused })
                Spacer()
                Button("Open Gom") { AppDelegate.showMainWindow() }
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(10)
        }
        .frame(width: 380)
    }
}
