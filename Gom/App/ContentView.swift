import GomCore
import SwiftUI

struct ContentView: View {
    let queue: DownloadQueue
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                TextEditor(text: $input)
                    .font(.body.monospaced())
                    .frame(height: 54)
                    .overlay(alignment: .topLeading) {
                        if input.isEmpty {
                            Text("Paste links, one per line…")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Links to download")
                Button("Add") { addLinks() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(parseURLList(input).isEmpty)
            }
            .padding()
            Divider()
            List(queue.items) { item in
                DownloadRow(item: item, speed: queue.speeds[item.id], queue: queue)
                    .listRowBackground(queue.highlighted == item.id ? Color.accentColor.opacity(0.15) : nil)
            }
            .dropDestination(for: URL.self) { urls, _ in
                let valid = urls.filter(isDownloadableURL)
                valid.forEach(add)
                return !valid.isEmpty
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    private func addLinks() {
        parseURLList(input).forEach(add)
        input = ""
    }

    private func add(_ url: URL) {
        queue.add(url: url, directory: AppSettings.downloadDirectory)
    }
}
