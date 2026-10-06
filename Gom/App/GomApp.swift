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
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let queue = DownloadQueue(store: .appSupport)
    private var server: BridgeServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.ensureToken()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        queue.onCompleted = { record in
            let content = UNMutableNotificationContent()
            content.title = "Download complete"
            content.body = record.filename ?? record.url.absoluteString
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: nil))
        }
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
                    queue.add(url: add.url, headers: add.headers, filename: add.filename, directory: AppSettings.downloadDirectory)
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

    private func showBridgeError(_ error: any Error) {
        let alert = NSAlert()
        alert.messageText = "Gom can't listen on port \(AppSettings.port)"
        alert.informativeText = "The browser extension won't work until this is fixed. Change the port in Settings and relaunch.\n\n\(error.localizedDescription)"
        alert.runModal()
    }
}
