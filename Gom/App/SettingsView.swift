import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage("downloadDirectory") private var directoryPath = ""
    @AppStorage("port") private var port = AppSettings.defaultPort
    @AppStorage("token") private var token = ""
    @State private var choosingFolder = false

    var body: some View {
        Form {
            LabeledContent("Download folder") {
                HStack {
                    Text(directoryPath.isEmpty ? URL.downloadsDirectory.path(percentEncoded: false) : directoryPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { choosingFolder = true }
                }
            }
            TextField("Extension port", value: $port, format: .number.grouping(.never))
            Text("Port changes take effect after relaunching Gom.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Extension token") {
                HStack {
                    Text(token)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(token, forType: .string)
                    }
                }
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { directoryPath = url.path(percentEncoded: false) }
        }
        .padding()
        .frame(width: 480)
    }
}
