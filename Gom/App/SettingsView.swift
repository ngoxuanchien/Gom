import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage("downloadDirectory") private var directoryPath = ""
    @AppStorage("port") private var port = AppSettings.defaultPort
    @AppStorage("token") private var token = ""
    @State private var choosingFolder = false

    var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Save to") {
                    HStack {
                        Label(directoryPath.isEmpty ? URL.downloadsDirectory.path(percentEncoded: false) : directoryPath, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { choosingFolder = true }
                    }
                }
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
        .frame(width: 480)
    }
}
