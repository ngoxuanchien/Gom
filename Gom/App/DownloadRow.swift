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
        .onTapGesture(count: 2) {
            if item.state == .completed, let url = item.fileURL { NSWorkspace.shared.open(url) }
        }
        .contextMenu {
            if item.state != .completed {
                if item.scheduled == true {
                    Button("Start Now") {
                        queue.setScheduled(item.id, false)
                        queue.resume(item.id)   // a paused or failed one starts too
                    }
                } else {
                    Button("Start in Schedule") { queue.setScheduled(item.id, true) }
                }
            }
            Button("Remove from List") { queue.remove(item.id, deleteFile: false) }
            if item.state == .completed {
                Button("Remove and Delete File", role: .destructive) { queue.remove(item.id, deleteFile: true) }
            }
        }
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
                iconButton("folder", "Show in Finder") {
                    if let url = item.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            iconButton("xmark", "Remove") { queue.remove(item.id, deleteFile: false) }
        }
        .buttonStyle(.borderless)
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
