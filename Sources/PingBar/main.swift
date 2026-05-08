import AppKit
import Foundation
import PingBarCore
import ServiceManagement

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
private final class PingBarController: NSObject, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor: PingMonitor
    private let menu = NSMenu()
    private let launchAtLoginItem = NSMenuItem(
        title: "Lancer au demarrage",
        action: #selector(toggleLaunchAtLogin),
        keyEquivalent: ""
    )
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
        menu.delegate = self

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

        launchAtLoginItem.target = self
        launchAtLoginItem.image = symbol("poweron")

        let quitItem = NSMenuItem(
            title: "Quitter PingBar",
            action: #selector(quit),
            keyEquivalent: ""
        )
        quitItem.target = self
        quitItem.image = symbol("power")

        menu.addItem(targetItem)
        menu.addItem(intervalItem)
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateIntervalMenu()
        updateLaunchAtLoginMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateIntervalMenu()
        updateLaunchAtLoginMenu()
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
        NSApp.activate(ignoringOtherApps: true)

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = monitor.host

        let alert = NSAlert()
        alert.messageText = "Changer la cible"
        alert.informativeText = "Entrez une IPv4 ou un nom de domaine."
        alert.accessoryView = input
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Annuler")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        guard let host = PingParser.sanitizedHost(from: input.stringValue) else {
            NSSound.beep()
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

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp

        do {
            switch service.status {
            case .enabled:
                try service.unregister()

            case .notRegistered:
                try service.register()

            case .requiresApproval:
                showAlert(
                    title: "Autorisation requise",
                    message: "macOS demande une validation dans Reglages Systeme > General > Ouverture."
                )

            case .notFound:
                showAlert(
                    title: "App introuvable",
                    message: "Lancez PingBar depuis le bundle PingBar.app pour activer le demarrage automatique."
                )

            @unknown default:
                showAlert(
                    title: "Etat inconnu",
                    message: "macOS a retourne un etat inattendu pour le demarrage automatique."
                )
            }
        } catch {
            showAlert(title: "Demarrage automatique impossible", message: error.localizedDescription)
        }

        updateLaunchAtLoginMenu()
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

    private func updateLaunchAtLoginMenu() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginItem.state = .on
            launchAtLoginItem.isEnabled = true
            launchAtLoginItem.title = "Lancer au demarrage"

        case .requiresApproval:
            launchAtLoginItem.state = .mixed
            launchAtLoginItem.isEnabled = true
            launchAtLoginItem.title = "Lancer au demarrage"

        case .notRegistered:
            launchAtLoginItem.state = .off
            launchAtLoginItem.isEnabled = true
            launchAtLoginItem.title = "Lancer au demarrage"

        case .notFound:
            launchAtLoginItem.state = .off
            launchAtLoginItem.isEnabled = false
            launchAtLoginItem.title = "Lancer au demarrage"

        @unknown default:
            launchAtLoginItem.state = .off
            launchAtLoginItem.isEnabled = true
            launchAtLoginItem.title = "Lancer au demarrage"
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

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
