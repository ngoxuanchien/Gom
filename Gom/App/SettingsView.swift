import AppKit
import GomCore
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @AppStorage("downloadDirectory") private var directoryPath = ""
    @AppStorage("sortByType") private var sortByType = true
    @AppStorage("notifications") private var notifications = true
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
        // Re-checked when the user comes back from System Settings.
        .task { await checkNotifications() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await checkNotifications() }
        }
        .frame(width: 560)
    }

    private func checkNotifications() async {
        notificationsDenied = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }
}
