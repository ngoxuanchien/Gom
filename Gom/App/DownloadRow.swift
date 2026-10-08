import AppKit
import GomCore
import SwiftUI
import UniformTypeIdentifiers

struct DownloadRow: View {
    let item: DownloadRecord
    let speed: Double?
    let queue: DownloadQueue

    var body: some View {
        HStack(spacing: 12) {
            // Mail-style dot for a finished file not opened yet; kept in the layout so rows stay aligned.
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .opacity(item.unseen == true ? 1 : 0)
                .accessibilityHidden(item.unseen != true)
                .accessibilityLabel("Not opened yet")
            Image(nsImage: fileIcon)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename ?? item.url.absoluteString)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
            }
            Spacer()
            buttons
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .queued, .downloading, .paused:
            if let total = item.totalBytes, total > 0 {
                ProgressView(value: Double(min(item.downloadedBytes, total)), total: Double(total))
            } else if item.state == .downloading {
                ProgressView().progressViewStyle(.linear)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        case .completed:
            Label("Done · \(bytes(item.totalBytes ?? item.downloadedBytes))", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
        }
    }

    private var detail: String {
        var parts: [String] = []
        switch item.state {
        case .queued:
            if item.scheduled == true {
                let start = AppSettings.scheduleWindow.start
                parts.append("Scheduled · starts \(String(format: "%02d:%02d", start / 60, start % 60))")
            } else {
                parts.append("Queued")
            }
        case .paused: parts.append("Paused")
        default: break
        }
        if let total = item.totalBytes, total > 0 {
            parts.append("\(Int(Double(item.downloadedBytes) / Double(total) * 100))%")
            parts.append("\(bytes(item.downloadedBytes)) of \(bytes(total))")
        } else if item.downloadedBytes > 0 {
            parts.append(bytes(item.downloadedBytes))
        }
        if item.state == .downloading, let speed { parts.append("\(bytes(Int64(speed)))/s") }
        if !item.resumable && !item.segments.isEmpty { parts.append("server can't resume – pausing restarts from zero") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 8) {
            switch item.state {
            case .queued, .downloading:
                iconButton("pause.fill", "Pause") { queue.pause(item.id) }
            case .paused:
                iconButton("play.fill", "Resume") { queue.resume(item.id) }
            case .failed:
                iconButton("arrow.clockwise", "Retry") { queue.resume(item.id) }
            case .completed:
                iconButton("arrow.up.forward.app", "Open") {
                    if let url = item.fileURL { open(url) }
                }
                iconButton("folder", "Show in Finder") {
                    if let url = item.fileURL {
                        queue.markSeen([item.id])
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                iconButton("trash", "Move to Trash") { queue.remove(item.id, deleteFile: true) }
            }
            iconButton("xmark", "Remove") { queue.remove(item.id, deleteFile: false) }
        }
        .buttonStyle(.borderless)
    }

    private func open(_ url: URL) {
        queue.markSeen([item.id])
        NSWorkspace.shared.open(url)
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .help(label)
            .accessibilityLabel(label)
    }

    private var fileIcon: NSImage {
        let ext = (item.filename.map { URL(filePath: $0) } ?? item.url).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// Context menu for the right-clicked row, or for every selected row when the click lands in the selection.
struct DownloadMenu: View {
    let items: [DownloadRecord]
    let queue: DownloadQueue

    var body: some View {
        let finished = items.filter { $0.state == .completed }
        if !finished.isEmpty {
            Button("Open") { Self.open(finished, queue: queue) }
        }
        if items.count == 1, let item = items.first, item.state != .completed {
            if item.scheduled == true {
                Button("Start Now") {
                    queue.setScheduled(item.id, false)
                    queue.resume(item.id)   // a paused or failed one starts too
                }
            } else {
                Button("Start in Schedule") { queue.setScheduled(item.id, true) }
            }
        }
        Button("Remove from List") { for item in items { queue.remove(item.id, deleteFile: false) } }
        if !finished.isEmpty {
            Button("Move to Trash", role: .destructive) { for item in items { queue.remove(item.id, deleteFile: true) } }
        }
    }

    static func open(_ items: [DownloadRecord], queue: DownloadQueue) {
        let finished = items.filter { $0.state == .completed && $0.fileURL != nil }
        queue.markSeen(finished.map(\.id))
        for item in finished { NSWorkspace.shared.open(item.fileURL!) }
    }
}
