import GomCore
import SwiftUI

struct ContentView: View {
    let queue: DownloadQueue
    let videoSetup: VideoSetup
    @State private var input = ""
    @AppStorage("scheduleNew") private var scheduleNew = false
    /// "" shows every download, `otherGroup` those matching no folder, anything else a folder name.
    @SceneStorage("category") private var category = ""
    /// Read so the sidebar redraws when the folders are edited in Settings.
    @AppStorage("fileCategories") private var categoriesData: Data?
    /// Days the user opened or closed; today starts open, older days closed.
    @State private var toggledDays: Set<Date> = []

    private let otherGroup = "\u{1}other"   // can't collide: folder names are sanitized filenames

    private var categories: [FileCategory] {
        _ = categoriesData
        return AppSettings.categories
    }

    private func group(of item: DownloadRecord) -> String {
        categoryFolder(of: item, in: categories) ?? otherGroup
    }

    private var visibleItems: [DownloadRecord] {
        (category.isEmpty ? queue.items : queue.items.filter { group(of: $0) == category }).reversed()
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            downloads
        }
        .frame(minWidth: 720, minHeight: 360)
        // A new download may not match the open folder; show everything so it isn't hidden.
        .onChange(of: queue.items.count) { old, new in
            if new > old { category = "" }
        }
    }

    private var sidebar: some View {
        let counts = Dictionary(grouping: queue.items, by: group(of:)).mapValues(\.count)
        var folders: [String] = []
        for c in categories {
            let folder = c.folder.trimmingCharacters(in: .whitespaces)
            if !folder.isEmpty, !folders.contains(sanitizeFilename(folder)) { folders.append(sanitizeFilename(folder)) }
        }
        return List(selection: $category) {
            Label("All", systemImage: "tray.full")
                .badge(queue.items.count)
                .tag("")
            Section("Folders") {
                ForEach(folders, id: \.self) { folder in
                    Label(folder, systemImage: icon(for: folder))
                        .badge(counts[folder] ?? 0)
                        .tag(folder)
                }
                Label("Other", systemImage: "questionmark.folder")
                    .badge(counts[otherGroup] ?? 0)
                    .tag(otherGroup)
            }
        }
        .navigationSplitViewColumnWidth(min: 160, ideal: 180)
    }

    private func icon(for folder: String) -> String {
        switch folder {
        case "Documents": "doc.text"
        case "Compressed": "doc.zipper"
        case "Music": "music.note"
        case "Video": "film"
        case "Programs": "shippingbox"
        case "Images": "photo"
        default: "folder"
        }
    }

    private var downloads: some View {
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
                Toggle("Schedule", isOn: $scheduleNew)
                    .help("Add links as scheduled downloads; they run in the window set in Settings")
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
            List {
                ForEach(daySections(visibleItems), id: \.day) { section in
                    Section(isExpanded: isExpanded(section.day)) {
                        ForEach(section.items) { item in
                            DownloadRow(item: item, speed: queue.speeds[item.id], queue: queue)
                                .listRowBackground(queue.highlighted == item.id ? Color.accentColor.opacity(0.15) : nil)
                        }
                    } header: {
                        // The plain list style draws no disclosure control of its own, so the header is the toggle.
                        let expanded = isExpanded(section.day)
                        Button {
                            withAnimation { expanded.wrappedValue.toggle() }
                        } label: {
                            HStack {
                                Image(systemName: "chevron.right")
                                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                                Text(dayTitle(section.day))
                                Text("\(section.items.count)").foregroundStyle(.secondary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if queue.items.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "tray.and.arrow.down",
                        description: Text("Paste links above, drop them here, or download from the browser.")
                    )
                } else if visibleItems.isEmpty {
                    ContentUnavailableView("Nothing Here", systemImage: "folder", description: Text("No downloads match this folder."))
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let valid = urls.filter(isDownloadableURL)
                addAll(valid)
                return !valid.isEmpty
            }
        }
    }

    private func isExpanded(_ day: Date) -> Binding<Bool> {
        let open = Calendar.current.isDateInToday(day)
        return Binding {
            open != toggledDays.contains(day)
        } set: { expanded in
            if expanded == open { toggledDays.remove(day) } else { toggledDays.insert(day) }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private func addLinks() {
        addAll(parseURLList(input))
        input = ""
    }

    /// Offers the tool install once per batch, not once per video link.
    private func addAll(_ urls: [URL]) {
        var anyVideo = false
        for url in urls {
            let video = isVideoPage(url) ? AppSettings.videoQuality : nil
            queue.add(url: url, directory: AppSettings.downloadDirectory, categories: AppSettings.sortByType ? AppSettings.categories : nil, video: video, scheduled: scheduleNew)
            anyVideo = anyVideo || video != nil
        }
        if anyVideo { Task { await videoSetup.offerInstallIfNeeded() } }
    }
}
