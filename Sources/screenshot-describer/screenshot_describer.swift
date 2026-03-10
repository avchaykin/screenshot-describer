import AppKit
import Foundation
import UserNotifications

enum AppState {
    case idle
    case processing
}

struct AppConfig: Codable {
    var openAIAPIKey: String?
    var workingFolderPath: String?
    var csvOutputFolderPath: String?
    var prompt: String?

    enum CodingKeys: String, CodingKey {
        case openAIAPIKey = "openai_api_key"
        case workingFolderPath = "working_folder"
        case csvOutputFolderPath = "csv_output_folder"
        case prompt
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var menu = NSMenu()
    private var selectedFolderItem = NSMenuItem(title: "Working folder: not set", action: nil, keyEquivalent: "")
    private var launchAtLoginItem = NSMenuItem(title: "Launch at login", action: nil, keyEquivalent: "")
    private var apiKeyStatusItem = NSMenuItem(title: "OpenAI API key: not set", action: nil, keyEquivalent: "")

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

    private var config: AppConfig = .init()
    private var csvOutputFolderURL: URL?
    private let outputCSVFileName = "screenshot-descriptions.csv"
    private lazy var notificationsAvailable: Bool = {
        // UserNotifications API can crash when process is launched from a plain binary path (no .app bundle).
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }()
    private let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "heic", "heif"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupNotifications()
        setupMenu()
        ensureConfigFileExists()
        loadConfig()
        log("Started. Config: \(configFileURL().path)")
        restoreFolder()
        updateStatusIcon()
        refreshAPIKeyStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcherTimer?.invalidate()
    }

    private func setupNotifications() {
        guard notificationsAvailable else {
            log("Notifications disabled: running outside .app bundle")
            return
        }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.log("Notification authorization error: \(error.localizedDescription)")
                }
                self.log("Notifications granted: \(granted)")
            }
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

        apiKeyStatusItem.isEnabled = false
        menu.addItem(apiKeyStatusItem)

        let editAPIKey = NSMenuItem(title: "Edit OpenAI API key…", action: #selector(editOpenAIAPIKey), keyEquivalent: "")
        editAPIKey.target = self
        menu.addItem(editAPIKey)

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
        if let outputPath = config.csvOutputFolderPath?.trimmingCharacters(in: .whitespacesAndNewlines), !outputPath.isEmpty {
            csvOutputFolderURL = URL(fileURLWithPath: outputPath)
        } else {
            csvOutputFolderURL = nil
        }

        if let path = config.workingFolderPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            beginWatching(URL(fileURLWithPath: path))
            return
        }

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
            config.workingFolderPath = url.path
            if config.csvOutputFolderPath == nil || config.csvOutputFolderPath?.isEmpty == true {
                config.csvOutputFolderPath = url.path
                csvOutputFolderURL = url
            }
            try? saveConfig()
            beginWatching(url)
            notify(title: "Working folder updated", body: url.path)
        }
    }

    @objc private func resetFolderSelection() {
        defaults.removeObject(forKey: folderDefaultsKey)
        config.workingFolderPath = nil
        try? saveConfig()
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

    @objc private func editOpenAIAPIKey() {
        let alert = NSAlert()
        alert.messageText = "OpenAI API key"
        alert.informativeText = "Key is stored in ~/.config/screenshot-describer/config.json (openai_api_key)"
        alert.alertStyle = .informational

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "sk-..."
        field.stringValue = resolveOpenAIAPIKey()
        alert.accessoryView = field

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newKey = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try writeOpenAIAPIKey(newKey)
                refreshAPIKeyStatus()
                notify(title: "OpenAI API key saved", body: "Key updated in local config")
            } catch {
                notify(title: "API key save error", body: error.localizedDescription)
            }
        } else if response == .alertThirdButtonReturn {
            do {
                try clearOpenAIAPIKey()
                refreshAPIKeyStatus()
                notify(title: "OpenAI API key removed", body: "Local config key has been cleared")
            } catch {
                notify(title: "API key remove error", body: error.localizedDescription)
            }
        }
    }

    private func refreshAPIKeyStatus() {
        apiKeyStatusItem.title = resolveOpenAIAPIKey().isEmpty ? "OpenAI API key: not set" : "OpenAI API key: configured"
    }

    private func configDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/screenshot-describer", isDirectory: true)
    }

    private func appLogFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent("screenshot-describer.log")
    }

    private func log(_ message: String) {
        let line = "[\(isoFormatter.string(from: Date()))] \(message)"
        print(line)

        let url = appLogFileURL()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try "".write(to: url, atomically: true, encoding: .utf8)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            if let data = (line + "\n").data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            try handle.close()
        } catch {
            print("[logger-error] \(error.localizedDescription)")
        }
    }

    private func configFileURL() -> URL {
        configDirectoryURL().appendingPathComponent("config.json")
    }

    private func openAIAPIKeyFileURL() -> URL {
        configDirectoryURL().appendingPathComponent("openai_api_key")
    }

    private func ensureConfigFileExists() {
        let url = configFileURL()
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        let skeleton = AppConfig(
            openAIAPIKey: "",
            workingFolderPath: "",
            csvOutputFolderPath: "",
            prompt: defaultPrompt()
        )

        do {
            try FileManager.default.createDirectory(at: configDirectoryURL(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(skeleton)
            try data.write(to: url, options: .atomic)
        } catch {
            log("Failed to create default config: \(error.localizedDescription)")
        }
    }

    private func loadConfig() {
        let url = configFileURL()
        guard let data = try? Data(contentsOf: url) else { return }
        if let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = decoded
        }
    }

    private func saveConfig() throws {
        let dir = configDirectoryURL()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(config)
        try data.write(to: configFileURL(), options: .atomic)
    }

    private func writeOpenAIAPIKey(_ key: String) throws {
        config.openAIAPIKey = key
        try saveConfig()
    }

    private func clearOpenAIAPIKey() throws {
        config.openAIAPIKey = nil
        try saveConfig()
        let legacy = openAIAPIKeyFileURL()
        if FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.removeItem(at: legacy)
        }
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

        let urls = newPaths
            .map { URL(fileURLWithPath: $0) }
            .filter(isSupportedImage)
            .sorted { $0.path < $1.path }

        guard !urls.isEmpty else { return }

        log("[watch] detected \(urls.count) new supported file(s) in \(folderURL.path)")
        urls.forEach { log("[watch] queued: \($0.path)") }
        processingQueue.append(contentsOf: urls)

        notify(
            title: "New screenshots detected",
            body: "Queued \(urls.count) image(s) from \(folderURL.lastPathComponent)"
        )

        processQueueIfNeeded(in: folderURL)
    }

    private func processQueueIfNeeded(in folderURL: URL) {
        guard !isProcessing, !processingQueue.isEmpty else { return }
        isProcessing = true
        state = .processing

        let file = processingQueue.removeFirst()
        log("[process] start: \(file.path)")
        notify(title: "Processing started", body: file.lastPathComponent)

        Task {
            do {
                let description = try await describeImageWithOpenAI(fileURL: file)
                try appendCSVRow(in: folderURL, fileURL: file, description: description, status: "ok", error: "")
                log("[process] success: \(file.path)")
                notify(title: "Processed", body: file.lastPathComponent)
            } catch {
                let message = error.localizedDescription
                log("[process] error: \(file.path) :: \(message)")
                try? appendCSVRow(in: folderURL, fileURL: file, description: "", status: "error", error: message)
                notify(title: "Processing failed", body: "\(file.lastPathComponent): \(message)")
            }

            isProcessing = false
            if processingQueue.isEmpty {
                state = .idle
            }
            processQueueIfNeeded(in: folderURL)
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

    private func isSupportedImage(_ fileURL: URL) -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    private func describeImageWithOpenAI(fileURL: URL) async throws -> String {
        let apiKey = resolveOpenAIAPIKey()
        guard !apiKey.isEmpty else {
            throw NSError(domain: "screenshot-describer", code: 1001, userInfo: [NSLocalizedDescriptionKey: "OpenAI API key is not set (OPENAI_API_KEY or ~/.config/screenshot-describer/openai_api_key)"])
        }

        let imageData = try Data(contentsOf: fileURL)
        let mimeType = mimeTypeForExtension(fileURL.pathExtension)
        let base64 = imageData.base64EncodedString()
        let dataURL = "data:\(mimeType);base64,\(base64)"

        let requestBody: [String: Any] = [
            "model": "gpt-4o-mini",
            "input": [[
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": resolvePrompt()
                    ],
                    [
                        "type": "input_image",
                        "image_url": dataURL
                    ]
                ]
            ]]
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "screenshot-describer", code: 1002, userInfo: [NSLocalizedDescriptionKey: "No HTTP response from OpenAI"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "screenshot-describer", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "OpenAI API error \(httpResponse.statusCode): \(body)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "screenshot-describer", code: 1003, userInfo: [NSLocalizedDescriptionKey: "OpenAI response is not valid JSON"])
        }

        if let outputText = json["output_text"] as? String,
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let output = json["output"] as? [[String: Any]] {
            var chunks: [String] = []
            for item in output {
                if let content = item["content"] as? [[String: Any]] {
                    for part in content {
                        if let text = part["text"] as? String,
                           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            chunks.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }
                }
            }
            let joined = chunks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                return joined
            }
        }

        let preview = String(data: data, encoding: .utf8)?.prefix(500) ?? "<unreadable body>"
        throw NSError(domain: "screenshot-describer", code: 1003, userInfo: [NSLocalizedDescriptionKey: "OpenAI response had no text fields (output_text/output[].content[].text). Body preview: \(preview)"])
    }

    private func resolveOpenAIAPIKey() -> String {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }

        if let configured = config.openAIAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            return configured
        }

        let fileURL = openAIAPIKeyFileURL() // legacy fallback
        if let raw = try? String(contentsOf: fileURL, encoding: .utf8) {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { return key }
        }

        return ""
    }

    private func defaultPrompt() -> String {
        "Сделай краткое описание того, что изображено на скриншоте. 1-3 предложения, по делу."
    }

    private func resolvePrompt() -> String {
        if let configured = config.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            return configured
        }
        return defaultPrompt()
    }

    private func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        default: return "application/octet-stream"
        }
    }

    private func appendCSVRow(in folderURL: URL, fileURL: URL, description: String, status: String, error: String) throws {
        let targetDir = csvOutputFolderURL ?? folderURL
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let csvURL = targetDir.appendingPathComponent(outputCSVFileName)
        log("[csv] write row status=\(status) file=\(fileURL.lastPathComponent) -> \(csvURL.path)")
        if !FileManager.default.fileExists(atPath: csvURL.path) {
            let header = "timestamp_iso,file_name,file_path,status,description,error\n"
            try header.write(to: csvURL, atomically: true, encoding: .utf8)
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let row = [
            timestamp,
            fileURL.lastPathComponent,
            fileURL.path,
            status,
            description,
            error
        ].map(csvEscape).joined(separator: ",") + "\n"

        let handle = try FileHandle(forWritingTo: csvURL)
        try handle.seekToEnd()
        if let data = row.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
        try handle.close()
    }

    private func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private func notify(title: String, body: String) {
        guard notificationsAvailable else {
            log("[notify] \(title): \(body)")
            return
        }

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
