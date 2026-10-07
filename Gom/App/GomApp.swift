import AppKit
import GomCore
import SwiftUI
import UserNotifications

@main
struct GomApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Gom", id: "main") {
            ContentView(queue: appDelegate.queue, videoSetup: appDelegate.videoSetup)
        }
        MenuBarExtra {
            MenuBarView(queue: appDelegate.queue)
        } label: {
            MenuBarLabel(queue: appDelegate.queue)
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(queue: appDelegate.queue, videoSetup: appDelegate.videoSetup)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let queue = DownloadQueue(store: .appSupport, videoTools: VideoTools.locate(in: toolDirectories(loginShellPATH: nil)))
    lazy var videoSetup = VideoSetup(queue: queue)
    private var server: BridgeServer?
    private var countdown: (alert: NSAlert, verb: String, deadline: Date)?

    /// Set before launch finishes so a click on a notification that launched Gom is delivered.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.ensureToken()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        queue.onFinished = Self.notify
        queue.bandwidthLimit = max(0, AppSettings.speedLimitKB) * 1000
        queue.onScheduleFinished = { [weak self] in self?.scheduleFinished() }
        queue.scheduleWindow = AppSettings.scheduleWindow
        queue.refreshSchedule()
        // ponytail: polls every 30 s, so the window opens and closes up to 30 s late; exact timers would need DST/wake handling.
        _ = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [queue] _ in
            MainActor.assumeIsolated { queue.refreshSchedule() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [queue] _ in
            MainActor.assumeIsolated { queue.refreshSchedule() }
        }
        startBridge()
        Task { await videoSetup.refresh() }
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
        let videoSetup = videoSetup
        do {
            let server = try BridgeServer(port: UInt16(clamping: AppSettings.port), token: AppSettings.token) { add in
                Task { @MainActor in
                    Self.showMainWindow()
                    if let video = add.video {
                        // The menu item is the choice: no folder dialog. The file is sorted once yt-dlp names it.
                        queue.add(url: add.url, headers: add.headers, directory: AppSettings.downloadDirectory,
                                  categories: AppSettings.sortByType ? AppSettings.categories : nil, video: video)
                        Task { await videoSetup.offerInstallIfNeeded() }
                    } else {
                        Self.chooseFolder(for: add) { directory in
                            queue.add(url: add.url, headers: add.headers, filename: add.filename, directory: directory)
                        }
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

    /// Counts down 60 s in an alert, then quits or sleeps the Mac unless the user cancels.
    private func scheduleFinished() {
        let action = AppSettings.scheduleAction
        guard action != .none else { return }
        // A run-loop callout, not a Task or main-queue block: inside those, runModal and terminate's
        // wait for applicationShouldTerminate's reply would hold the main actor and deadlock.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated { self?.showCountdown(action) }
        }
    }

    private func showCountdown(_ action: ScheduleAction) {
        let verb = action == .quit ? "quit" : "put the Mac to sleep"
        let alert = NSAlert()
        alert.messageText = "Scheduled downloads finished"
        alert.informativeText = "Gom will \(verb) in 60 seconds."
        alert.addButton(withTitle: action == .quit ? "Quit Now" : "Sleep Now")
        alert.addButton(withTitle: "Cancel")
        countdown = (alert, verb, .now + 60)
        // A run-loop timer, not a Task: main-actor tasks don't run while runModal holds the main actor.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickCountdown() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        timer.invalidate()
        countdown = nil
        guard response == .alertFirstButtonReturn || response == .abort else { return }
        if action == .quit { NSApp.terminate(nil) } else { Self.sleepMac() }
    }

    private func tickCountdown() {
        guard let countdown else { return }
        let left = Int(countdown.deadline.timeIntervalSinceNow.rounded())
        if left <= 0 {
            NSApp.abortModal()   // unlike stopModal, works from a timer
        } else {
            countdown.alert.informativeText = "Gom will \(countdown.verb) in \(left) seconds."
        }
    }

    private static func sleepMac() {
        let pmset = Process()
        pmset.executableURL = URL(filePath: "/usr/bin/pmset")
        pmset.arguments = ["sleepnow"]
        pmset.terminationHandler = { if $0.terminationStatus != 0 { print("Gom: pmset sleepnow exited with \($0.terminationStatus)") } }
        do {
            try pmset.run()
        } catch {
            print("Gom: pmset sleepnow failed: \(error)")
        }
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
