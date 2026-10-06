import AppKit
import GomCore
import SwiftUI
import UserNotifications

@main
struct GomApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Gom", id: "main") {
            ContentView(queue: appDelegate.queue)
        }
        MenuBarExtra {
            MenuBarView(queue: appDelegate.queue)
        } label: {
            MenuBarLabel(queue: appDelegate.queue)
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let queue = DownloadQueue(store: .appSupport)
    private var server: BridgeServer?

    /// Set before launch finishes so a click on a notification that launched Gom is delivered.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.ensureToken()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        queue.onFinished = Self.notify
        startBridge()
    }

    /// Keep running with no window so the extension can still hand over downloads.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await queue.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func startBridge() {
        let queue = queue
        do {
            let server = try BridgeServer(port: UInt16(clamping: AppSettings.port), token: AppSettings.token) { add in
                Task { @MainActor in
                    Self.showMainWindow()
                    Self.chooseFolder(for: add) { directory in
                        queue.add(url: add.url, headers: add.headers, filename: add.filename, directory: directory)
                    }
                }
            }
            self.server = server
            Task {
                do {
                    _ = try await server.start()
                } catch {
                    showBridgeError(error)
                }
            }
        } catch {
            showBridgeError(error)
        }
    }

    private static func notify(_ record: DownloadRecord) {
        guard AppSettings.notifications else { return }
        let name = record.filename ?? record.url.absoluteString
        let content = UNMutableNotificationContent()
        switch record.state {
        case .completed:
            content.title = "Download complete"
            content.body = name
            if let file = record.fileURL { content.userInfo = ["path": file.path(percentEncoded: false)] }
        case .failed(let error):
            content.title = "Download failed"
            content.body = "\(name) — \(error)"
        default:
            return
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: nil))
    }

    static func showMainWindow() {
        // Plain activate() is cooperative and the browser in front won't yield, so force it.
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        } else {
            // The window was closed: a reopen event makes SwiftUI recreate it, like clicking the Dock icon.
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }

    /// Asks where to save a download from the extension. Cancelling drops the download.
    private static func chooseFolder(for add: AddRequest, then save: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        // Start in the file's category folder; it must exist for the panel to open there.
        let directory = AppSettings.directory(for: add.filename ?? add.url.lastPathComponent)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        panel.directoryURL = directory
        panel.prompt = "Save Here"
        panel.message = "Choose where to save \(add.filename ?? add.url.lastPathComponent)"
        panel.begin { response in
            if response == .OK, let url = panel.url { save(url) }
        }
    }

    private func showBridgeError(_ error: any Error) {
        let alert = NSAlert()
        alert.messageText = "Gom can't listen on port \(AppSettings.port)"
        alert.informativeText = "The browser extension won't work until this is fixed. Change the port in Settings and relaunch.\n\n\(error.localizedDescription)"
        alert.runModal()
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Success reveals the file in Finder; failure brings Gom forward so the user can retry.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let path = response.notification.request.content.userInfo["path"] as? String
        await MainActor.run {
            if let path {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
            } else {
                Self.showMainWindow()
            }
        }
    }
}
