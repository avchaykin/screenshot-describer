import AppKit
import Foundation
import UserNotifications

enum AppState {
    case idle
    case processing
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var menu = NSMenu()
    private var selectedFolderItem = NSMenuItem(title: "Working folder: not set", action: nil, keyEquivalent: "")
    private var launchAtLoginItem = NSMenuItem(title: "Launch at login", action: nil, keyEquivalent: "")

    private var state: AppState = .idle {
        didSet { updateStatusIcon() }
    }

    private var watcherTimer: Timer?
    private var knownFiles: Set<String> = []
    private var processingQueue: [URL] = []
    private var isProcessing = false

    private let defaults = UserDefaults.standard
    private let folderDefaultsKey = "workingFolderPath"

    private let launchAgentLabel = "com.avchaykin.screenshot-describer"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupNotifications()
        setupMenu()
        restoreFolder()
        updateStatusIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcherTimer?.invalidate()
    }

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                print("Notification authorization error: \(error.localizedDescription)")
            }
            print("Notifications granted: \(granted)")
        }
    }

    private func setupMenu() {
        statusItem.button?.toolTip = "screenshot-describer"

        selectedFolderItem.isEnabled = false
        menu.addItem(selectedFolderItem)
        menu.addItem(NSMenuItem.separator())

        let chooseFolder = NSMenuItem(title: "Choose working folder…", action: #selector(selectFolder), keyEquivalent: "")
        chooseFolder.target = self
        menu.addItem(chooseFolder)

        let resetFolder = NSMenuItem(title: "Reset folder", action: #selector(resetFolderSelection), keyEquivalent: "")
        resetFolder.target = self
        menu.addItem(resetFolder)

        menu.addItem(NSMenuItem.separator())

        launchAtLoginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        refreshLaunchAtLoginMenuState()

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func updateStatusIcon() {
        switch state {
        case .idle:
            statusItem.button?.title = "🟢"
            statusItem.button?.toolTip = "screenshot-describer: idle"
        case .processing:
            statusItem.button?.title = "🟠"
            statusItem.button?.toolTip = "screenshot-describer: processing"
        }
    }

    private func restoreFolder() {
        guard let path = defaults.string(forKey: folderDefaultsKey), !path.isEmpty else {
            selectedFolderItem.title = "Working folder: not set"
            return
        }
        let folderURL = URL(fileURLWithPath: path)
        beginWatching(folderURL)
    }

    @objc private func selectFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose working folder"
        panel.prompt = "Select"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            defaults.set(url.path, forKey: folderDefaultsKey)
            beginWatching(url)
            notify(title: "Working folder updated", body: url.path)
        }
    }

    @objc private func resetFolderSelection() {
        defaults.removeObject(forKey: folderDefaultsKey)
        watcherTimer?.invalidate()
        watcherTimer = nil
        knownFiles = []
        processingQueue = []
        isProcessing = false
        state = .idle
        selectedFolderItem.title = "Working folder: not set"
        notify(title: "Working folder reset", body: "Set a folder from the menu to resume watching")
    }

    @objc private func toggleLaunchAtLogin() {
        let shouldEnable = !isLaunchAtLoginEnabled()
        if shouldEnable {
            installLaunchAgent()
            notify(title: "Launch at login enabled", body: "screenshot-describer will start after login")
        } else {
            removeLaunchAgent()
            notify(title: "Launch at login disabled", body: "screenshot-describer will not auto-start")
        }
        refreshLaunchAtLoginMenuState()
    }

    private func refreshLaunchAtLoginMenuState() {
        launchAtLoginItem.state = isLaunchAtLoginEnabled() ? .on : .off
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPlistURL().path)
    }

    private func launchAgentPlistURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    private func installLaunchAgent() {
        let plistURL = launchAgentPlistURL()
        let launchAgentsDir = plistURL.deletingLastPathComponent()

        try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        let executablePath = CommandLine.arguments.first ?? ""
        let escapedPath = executablePath.replacingOccurrences(of: "&", with: "&amp;")

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(launchAgentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(escapedPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """

        do {
            try plist.write(to: plistURL, atomically: true, encoding: .utf8)
            _ = try? Process.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["unload", plistURL.path])
            _ = try? Process.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["load", plistURL.path])
        } catch {
            notify(title: "Launch at login error", body: error.localizedDescription)
        }
    }

    private func removeLaunchAgent() {
        let plistURL = launchAgentPlistURL()
        _ = try? Process.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["unload", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func beginWatching(_ folderURL: URL) {
        watcherTimer?.invalidate()
        knownFiles = snapshotFiles(in: folderURL)
        selectedFolderItem.title = "Working folder: \(folderURL.path)"

        watcherTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scanForNewFiles(folderURL)
            }
        }
        RunLoop.main.add(watcherTimer!, forMode: .common)
    }

    private func scanForNewFiles(_ folderURL: URL) {
        let currentFiles = snapshotFiles(in: folderURL)
        let newPaths = currentFiles.subtracting(knownFiles)
        guard !newPaths.isEmpty else { return }

        knownFiles = currentFiles

        let urls = newPaths.map { URL(fileURLWithPath: $0) }.sorted { $0.path < $1.path }
        processingQueue.append(contentsOf: urls)

        notify(
            title: "New files detected",
            body: "Queued \(urls.count) file(s) from \(folderURL.lastPathComponent)"
        )

        processQueueIfNeeded()
    }

    private func processQueueIfNeeded() {
        guard !isProcessing, !processingQueue.isEmpty else { return }
        isProcessing = true
        state = .processing

        let file = processingQueue.removeFirst()
        notify(title: "Processing started", body: file.lastPathComponent)

        Task {
            try? await Task.sleep(for: .seconds(1.5))
            notify(title: "Processed", body: file.lastPathComponent)
            isProcessing = false
            if processingQueue.isEmpty {
                state = .idle
            }
            processQueueIfNeeded()
        }
    }

    private func snapshotFiles(in folderURL: URL) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: Set<String> = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                files.insert(fileURL.path)
            }
        }
        return files
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}

let app = NSApplication.shared
let delegate = AppController()
app.delegate = delegate
app.run()
