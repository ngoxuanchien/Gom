import AppKit
import GomCore
import SwiftUI

struct SettingsView: View {
    @AppStorage("downloadDirectory") private var directoryPath = ""
    @AppStorage("sortByType") private var sortByType = true
    @AppStorage("notifications") private var notifications = true
    @AppStorage("port") private var port = AppSettings.defaultPort
    @AppStorage("token") private var token = ""
    @State private var categories = AppSettings.categories
    @State private var choosingFolder = false

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
        .frame(width: 560)
    }
}
