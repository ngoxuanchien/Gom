import GomCore
import SwiftUI

struct ContentView: View {
    let queue: DownloadQueue
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                TextEditor(text: $input)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .frame(height: 44)
                    .overlay(alignment: .topLeading) {
                        if input.isEmpty {
                            Text("Paste links, one per line…")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Links to download")
                Button("Add", systemImage: "arrow.down.circle.fill") { addLinks() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(parseURLList(input).isEmpty)
                    .help("Add links (⌘↩)")
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            .padding()
            Divider()
            List(queue.items) { item in
                DownloadRow(item: item, speed: queue.speeds[item.id], queue: queue)
                    .listRowBackground(queue.highlighted == item.id ? Color.accentColor.opacity(0.15) : nil)
            }
            .overlay {
                if queue.items.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "tray.and.arrow.down",
                        description: Text("Paste links above, drop them here, or download from the browser.")
                    )
                }
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
        queue.add(url: url, directory: AppSettings.downloadDirectory, categories: AppSettings.sortByType ? AppSettings.categories : nil)
    }
}
