import AppKit
import GomCore
import Observation

/// Finds yt-dlp and ffmpeg, and installs them with Homebrew when the user agrees.
@MainActor
@Observable
final class VideoSetup {
    private(set) var tools = VideoTools()
    private(set) var ytDlpVersion: String?
    private(set) var installing = false
    private var located = false
    private var prompting = false
    private let queue: DownloadQueue

    init(queue: DownloadQueue) { self.queue = queue }

    /// Looks the tools up again and hands them to the queue.
    func refresh() async {
        let shell = URL(filePath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        let path = try? await runProcess(shell, ["-lc", "echo $PATH"]).output.split(separator: "\n").last.map(String.init)
        tools = VideoTools.locate(in: toolDirectories(loginShellPATH: path))
        queue.videoTools = tools
        if let ytDlp = tools.ytDlp {
            ytDlpVersion = try? await runProcess(ytDlp, ["--version"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            ytDlpVersion = nil
        }
        located = true
        if tools.ytDlp != nil && tools.ffmpeg != nil { queue.retryMissingTools() }   // deno is optional
    }

    /// Called after a video is added and from Settings: asks to install whatever is missing.
    func offerInstallIfNeeded() async {
        if !located { await refresh() }
        guard !tools.missing.isEmpty, !installing, !prompting else { return }
        prompting = true
        defer { prompting = false }
        let alert = NSAlert()
        alert.messageText = "Video downloads need \(tools.missing.joined(separator: " and "))"
        if tools.brew != nil {
            alert.informativeText = "Gom can install them with Homebrew. Videos waiting for them start once it's done."
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                installing = true
                Task { await install() }
            }
        } else {
            alert.informativeText = "Install Homebrew, then run this in Terminal:\n\nbrew install \(tools.missing.joined(separator: " "))"
            alert.addButton(withTitle: "Get Homebrew")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "https://brew.sh")!) }
        }
    }

    private func install() async {
        guard let brew = tools.brew, !tools.missing.isEmpty else { installing = false; return }
        defer { installing = false }
        do {
            let result = try await runProcess(brew, ["install"] + tools.missing)
            if result.status != 0 {
                showInstallError(result.output.split(separator: "\n").suffix(8).joined(separator: "\n"))
            }
        } catch {
            showInstallError(error.localizedDescription)
        }
        await refresh()
    }

    private func showInstallError(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = "Homebrew couldn't install the video tools"
        alert.informativeText = detail
        alert.runModal()
    }
}
