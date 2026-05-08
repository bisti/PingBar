import AppKit
import Foundation
import PingBarCore

private let defaultHost = "1.1.1.1"
private let defaultInterval: TimeInterval = 5
private let hostDefaultsKey = "PingBarHost"
private let intervalDefaultsKey = "PingBarInterval"
private let intervalOptions: [TimeInterval] = [1, 2, 5, 10, 30, 60]

private enum PingStatus: Sendable {
    case measuring
    case success(milliseconds: Double)
    case timeout
    case failure(message: String)
}

private struct PingResult: Sendable {
    let host: String
    let status: PingStatus
}

private struct PingCommand: Sendable {
    let host: String
    let timeoutMilliseconds: Int

    init(host: String, timeoutMilliseconds: Int = 1_000) {
        self.host = host
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    func run() -> PingStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = [
            "-n",
            "-c", "1",
            "-W", String(timeoutMilliseconds),
            host
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(message: error.localizedDescription)
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combinedOutput = [output, errorOutput].joined(separator: "\n")

        if let latency = PingParser.latencyMilliseconds(from: combinedOutput) {
            return .success(milliseconds: latency)
        }

        if combinedOutput.contains("100.0% packet loss")
            || combinedOutput.localizedCaseInsensitiveContains("request timeout") {
            return .timeout
        }

        let message = combinedOutput
            .split(separator: "\n")
            .first
            .map(String.init) ?? "ping failed"
        return .failure(message: message)
    }
}

private struct StatusPresentation {
    let buttonTitle: String
    let toolTip: String
}

@MainActor
private final class TargetPanelController: NSObject, NSTextFieldDelegate {
    private let panel: NSPanel
    private let input = NSTextField(string: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private var selectedHost: String?

    init(currentHost: String) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 172),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        super.init()

        panel.title = "Changer la cible"
        panel.isReleasedWhenClosed = false
        panel.center()

        buildContent(currentHost: currentHost)
    }

    func runModal() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)

        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)

        return response == .OK ? selectedHost : nil
    }

    func controlTextDidChange(_ notification: Notification) {
        errorLabel.stringValue = ""
    }

    private func buildContent(currentHost: String) {
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = contentView

        let titleLabel = NSTextField(labelWithString: "Cible du ping")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        let hintLabel = NSTextField(labelWithString: "Adresse IPv4 ou nom de domaine.")
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor

        input.stringValue = currentHost
        input.delegate = self
        input.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        input.target = self
        input.action = #selector(confirm)
        input.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed

        let cancelButton = NSButton(title: "Annuler", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded

        let confirmButton = NSButton(title: "OK", target: self, action: #selector(confirm))
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = "\r"

        let buttonStack = NSStackView(views: [cancelButton, confirmButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 8

        let stack = NSStackView(views: [titleLabel, hintLabel, input, errorLabel, buttonStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            input.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonStack.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func confirm() {
        guard let host = PingParser.sanitizedHost(from: input.stringValue) else {
            errorLabel.stringValue = "Cible invalide."
            NSSound.beep()
            return
        }

        selectedHost = host
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancel() {
        NSApp.stopModal(withCode: .cancel)
    }
}

@MainActor
private final class PingMonitor: NSObject {
    var onUpdate: ((PingResult) -> Void)?

    private(set) var host: String
    private(set) var interval: TimeInterval
    private var timer: Timer?
    private var isRunning = false
    private var needsRefresh = false
    private var hasCompletedMeasurement = false

    init(host: String, interval: TimeInterval = defaultInterval) {
        self.host = host
        self.interval = interval
    }

    func start() {
        scheduleTimer()
        refresh()
    }

    func updateHost(_ host: String) {
        if self.host != host {
            hasCompletedMeasurement = false
        }

        self.host = host
        refresh()
    }

    func updateInterval(_ interval: TimeInterval) {
        guard self.interval != interval else {
            return
        }

        self.interval = interval
        scheduleTimer()
        refresh()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(timerFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard !isRunning else {
            needsRefresh = true
            return
        }

        isRunning = true
        let measuredHost = host

        if !hasCompletedMeasurement {
            onUpdate?(PingResult(host: measuredHost, status: .measuring))
        }

        Task { [weak self, measuredHost] in
            let status = await Task.detached(priority: .utility) {
                PingCommand(host: measuredHost).run()
            }.value

            self?.finish(measuredHost: measuredHost, status: status)
        }
    }

    @objc private func timerFired(_ timer: Timer) {
        refresh()
    }

    private func finish(measuredHost: String, status: PingStatus) {
        isRunning = false

        if host == measuredHost {
            hasCompletedMeasurement = true
            onUpdate?(PingResult(host: measuredHost, status: status))
        } else {
            needsRefresh = true
        }

        if needsRefresh {
            needsRefresh = false
            refresh()
        }
    }
}

@MainActor
private final class PingBarController: NSObject {
    private let defaults = UserDefaults.standard
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor: PingMonitor
    private let menu = NSMenu()
    private var intervalItems: [NSMenuItem] = []

    override init() {
        let savedHost = defaults.string(forKey: hostDefaultsKey).flatMap(PingParser.sanitizedHost)
        let savedInterval = Self.savedInterval(from: defaults)
        monitor = PingMonitor(host: savedHost ?? defaultHost, interval: savedInterval)
        super.init()
    }

    func start() {
        configureStatusItem()
        configureMenu()

        monitor.onUpdate = { [weak self] result in
            self?.render(result)
        }

        monitor.start()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.title = "Ping ..."
        button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        button.image = nil
        button.contentTintColor = nil
        button.toolTip = "PingBar"
    }

    private func configureMenu() {
        menu.autoenablesItems = false

        let targetItem = NSMenuItem(
            title: "Changer la cible...",
            action: #selector(changeTarget),
            keyEquivalent: ""
        )
        targetItem.target = self
        targetItem.image = symbol("target")

        let intervalItem = NSMenuItem(title: "Intervalle", action: nil, keyEquivalent: "")
        intervalItem.image = symbol("timer")
        intervalItem.submenu = buildIntervalMenu()

        let quitItem = NSMenuItem(
            title: "Quitter",
            action: #selector(quit),
            keyEquivalent: ""
        )
        quitItem.target = self
        quitItem.image = symbol("power")

        menu.addItem(targetItem)
        menu.addItem(intervalItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateIntervalMenu()
    }

    private func render(_ result: PingResult) {
        let presentation = presentation(for: result)

        applyStatusButton(presentation)
    }

    private func applyStatusButton(_ presentation: StatusPresentation) {
        guard let button = statusItem.button else {
            return
        }

        button.title = presentation.buttonTitle
        button.image = nil
        button.contentTintColor = nil
        button.toolTip = presentation.toolTip
    }

    private func presentation(for result: PingResult) -> StatusPresentation {
        switch result.status {
        case .measuring:
            return StatusPresentation(
                buttonTitle: "Ping ...",
                toolTip: "Ping vers \(result.host)"
            )

        case .success(let milliseconds):
            let latency = formatLatency(milliseconds)
            return StatusPresentation(
                buttonTitle: latency,
                toolTip: "Ping vers \(result.host): \(latency)"
            )

        case .timeout:
            return StatusPresentation(
                buttonTitle: "Timeout",
                toolTip: "Ping vers \(result.host): timeout"
            )

        case .failure(let message):
            return StatusPresentation(
                buttonTitle: "Ping ERR",
                toolTip: "Ping vers \(result.host): \(message)"
            )
        }
    }

    @objc private func changeTarget() {
        let panel = TargetPanelController(currentHost: monitor.host)
        guard let host = panel.runModal() else {
            return
        }

        defaults.set(host, forKey: hostDefaultsKey)
        monitor.updateHost(host)
    }

    @objc private func changeInterval(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else {
            return
        }

        let interval = value.doubleValue
        defaults.set(interval, forKey: intervalDefaultsKey)
        monitor.updateInterval(interval)
        updateIntervalMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func formatLatency(_ milliseconds: Double) -> String {
        if milliseconds < 10 {
            return String(format: "%.1f ms", milliseconds)
        }

        return "\(Int(milliseconds.rounded())) ms"
    }

    private func buildIntervalMenu() -> NSMenu {
        let menu = NSMenu()
        intervalItems = intervalOptions.map { interval in
            let item = NSMenuItem(
                title: intervalTitle(interval),
                action: #selector(changeInterval(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: interval)
            menu.addItem(item)
            return item
        }
        return menu
    }

    private func updateIntervalMenu() {
        intervalItems.forEach { item in
            guard let value = item.representedObject as? NSNumber else {
                return
            }

            item.state = value.doubleValue == monitor.interval ? .on : .off
        }
    }

    private static func savedInterval(from defaults: UserDefaults) -> TimeInterval {
        let value = defaults.double(forKey: intervalDefaultsKey)
        guard intervalOptions.contains(value) else {
            return defaultInterval
        }

        return value
    }

    private func intervalTitle(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return seconds == 1 ? "1 seconde" : "\(seconds) secondes"
    }

    private func symbol(_ name: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }

        image.isTemplate = true
        return image
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PingBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let controller = PingBarController()
        controller.start()
        self.controller = controller
    }
}

private let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
