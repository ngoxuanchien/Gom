import AppKit
import GomCore
import SwiftUI
import UserNotifications

struct SettingsView: View {
    let queue: DownloadQueue
    let videoSetup: VideoSetup
    @AppStorage("downloadDirectory") private var directoryPath = ""
    @AppStorage("sortByType") private var sortByType = true
    @AppStorage("notifications") private var notifications = true
    @AppStorage("speedLimitKB") private var speedLimitKB = 0
    @AppStorage("videoQuality") private var videoQuality = VideoQuality.best
    @AppStorage("port") private var port = AppSettings.defaultPort
    @AppStorage("token") private var token = ""
    @State private var categories = AppSettings.categories
    @State private var choosingFolder = false
    @State private var notificationsDenied = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Save to") {
                    HStack {
                        Label(directoryPath.isEmpty ? URL.downloadsDirectory.path(percentEncoded: false) : directoryPath, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { choosingFolder = true }
                    }
                }
                LabeledContent("Speed limit") {
                    HStack {
                        TextField("Speed limit", value: $speedLimitKB, format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("KB/s")
                    }
                }
                Toggle("Sort into folders by file type", isOn: $sortByType)
                Toggle("Show notifications", isOn: $notifications)
                if notifications && notificationsDenied {
                    LabeledContent("Notifications are off for Gom in System Settings.") {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Speed limit caps all downloads together. 0 = unlimited.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach($categories) { $category in
                    HStack {
                        TextField("Folder", text: $category.folder)
                            .frame(width: 120)
                        TextField("Extensions", text: $category.extensions)
                        Button("Remove", systemImage: "minus.circle") {
                            categories.removeAll { $0.id == category.id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                    .labelsHidden()
                }
                HStack {
                    Button("Add Folder", systemImage: "plus") {
                        categories.append(FileCategory(folder: "", extensions: ""))
                    }
                    Spacer()
                    Button("Restore Defaults") { categories = defaultFileCategories }
                }
            } header: {
                Text("Folders by File Type")
            } footer: {
                Text("Extensions are separated by spaces or commas. Other files stay in the top folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!sortByType)
            Section {
                Picker("Quality", selection: $videoQuality) {
                    ForEach(VideoQuality.allCases, id: \.self) { Text($0.label) }
                }
                LabeledContent("yt-dlp") { toolStatus(videoSetup.tools.ytDlp, version: videoSetup.ytDlpVersion) }
                LabeledContent("ffmpeg") { toolStatus(videoSetup.tools.ffmpeg, version: nil) }
                LabeledContent("deno") { toolStatus(videoSetup.tools.deno, version: nil) }
                if !videoSetup.tools.missing.isEmpty {
                    HStack {
                        Spacer()
                        if videoSetup.installing {
                            ProgressView().controlSize(.small)
                            Text("Installing…").foregroundStyle(.secondary)
                        } else {
                            Button("Install") { Task { await videoSetup.offerInstallIfNeeded() } }
                        }
                    }
                }
            } header: {
                Text("Video")
            } footer: {
                Text("Links to YouTube, Vimeo and other video sites download with yt-dlp at this quality. In the browser, right-click a page and choose Download video with Gom.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Port", value: $port, format: .number.grouping(.never))
                LabeledContent("Token") {
                    HStack {
                        Text(token)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Copy", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(token, forType: .string)
                        }
                    }
                }
            } header: {
                Text("Browser Extension")
            } footer: {
                Text("Paste the token into the Gom extension. Port changes take effect after relaunching Gom.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { directoryPath = url.path(percentEncoded: false) }
        }
        .onChange(of: categories) { AppSettings.categories = $1 }
        .onChange(of: speedLimitKB) {
            if $1 < 0 { speedLimitKB = 0 }
            queue.bandwidthLimit = max(0, $1) * 1000
        }
        // Re-checked when the user comes back from System Settings.
        .task { await checkNotifications() }
        .task { await videoSetup.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await checkNotifications() }
        }
        .frame(width: 560)
    }

    private func checkNotifications() async {
        notificationsDenied = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    private func toolStatus(_ url: URL?, version: String?) -> some View {
        Text(url.map { [version, $0.deletingLastPathComponent().path(percentEncoded: false)].compactMap { $0 }.joined(separator: " – ") } ?? "Not installed")
            .foregroundStyle(url == nil ? .red : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
