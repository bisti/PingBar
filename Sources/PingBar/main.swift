import AppKit
import Foundation
import PingBarCore

private let defaultHost = "1.1.1.1"
private let hostDefaultsKey = "PingBarHost"

private enum PingStatus: Sendable {
    case measuring
    case success(milliseconds: Double)
    case timeout
    case failure(message: String)
}

private struct PingResult: Sendable {
    let host: String
    let date: Date
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

@MainActor
private final class PingMonitor: NSObject {
    var onUpdate: ((PingResult) -> Void)?

    private(set) var host: String
    private let interval: TimeInterval
    private var timer: Timer?
    private var isRunning = false
    private var needsRefresh = false

    init(host: String, interval: TimeInterval = 5) {
        self.host = host
        self.interval = interval
    }

    func start() {
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

        refresh()
    }

    func updateHost(_ host: String) {
        self.host = host
        refresh()
    }

    func refresh() {
        guard !isRunning else {
            needsRefresh = true
            return
        }

        isRunning = true
        let measuredHost = host
        onUpdate?(PingResult(host: measuredHost, date: Date(), status: .measuring))

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
            onUpdate?(PingResult(host: measuredHost, date: Date(), status: status))
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
    private let hostItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    override init() {
        let savedHost = defaults.string(forKey: hostDefaultsKey).flatMap(PingParser.sanitizedHost)
        monitor = PingMonitor(host: savedHost ?? defaultHost)
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
        button.toolTip = "PingBar"
    }

    private func configureMenu() {
        menu.autoenablesItems = false

        hostItem.isEnabled = false
        lastItem.isEnabled = false
        stateItem.isEnabled = false

        let refreshItem = NSMenuItem(
            title: "Rafraichir maintenant",
            action: #selector(refreshNow),
            keyEquivalent: "r"
        )
        refreshItem.target = self

        let targetItem = NSMenuItem(
            title: "Changer la cible...",
            action: #selector(changeTarget),
            keyEquivalent: ","
        )
        targetItem.target = self

        let quitItem = NSMenuItem(
            title: "Quitter PingBar",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self

        menu.addItem(hostItem)
        menu.addItem(lastItem)
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(refreshItem)
        menu.addItem(targetItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func render(_ result: PingResult) {
        hostItem.title = "Cible: \(result.host)"

        switch result.status {
        case .measuring:
            statusItem.button?.title = "Ping ..."
            lastItem.title = "Dernier ping: mesure en cours"
            stateItem.title = "Etat: mesure"
            statusItem.button?.toolTip = "Ping vers \(result.host)"

        case .success(let milliseconds):
            let latency = formatLatency(milliseconds)
            statusItem.button?.title = latency
            lastItem.title = "Dernier ping: \(latency)"
            stateItem.title = "Etat: \(quality(for: milliseconds))"
            statusItem.button?.toolTip = "Ping vers \(result.host): \(latency)"

        case .timeout:
            statusItem.button?.title = "Timeout"
            lastItem.title = "Dernier ping: timeout"
            stateItem.title = "Etat: pas de reponse"
            statusItem.button?.toolTip = "Ping vers \(result.host): timeout"

        case .failure(let message):
            statusItem.button?.title = "Ping ERR"
            lastItem.title = "Dernier ping: erreur"
            stateItem.title = "Etat: \(message)"
            statusItem.button?.toolTip = "Ping vers \(result.host): \(message)"
        }
    }

    @objc private func refreshNow() {
        monitor.refresh()
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func formatLatency(_ milliseconds: Double) -> String {
        if milliseconds < 10 {
            return String(format: "%.1f ms", milliseconds)
        }

        return "\(Int(milliseconds.rounded())) ms"
    }

    private func quality(for milliseconds: Double) -> String {
        switch milliseconds {
        case ..<60:
            return "bon"
        case ..<120:
            return "moyen"
        default:
            return "eleve"
        }
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
