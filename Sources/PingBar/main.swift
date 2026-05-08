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

private struct StatusPresentation {
    let buttonTitle: String
    let summaryTitle: String
    let detail: String
    let color: NSColor
    let symbolName: String
    let toolTip: String
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
private final class StatusDotView: NSView {
    var color: NSColor = .systemGray {
        didSet {
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 10, height: 10)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }
}

@MainActor
private final class PingSummaryView: NSView {
    private let dotView = StatusDotView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    private let appLabel = NSTextField(labelWithString: "PingBar")
    private let latencyLabel = NSTextField(labelWithString: "Ping ...")
    private let detailLabel = NSTextField(labelWithString: "Mesure en cours")
    private let hostLabel = NSTextField(labelWithString: "Cible: 1.1.1.1")
    private let updatedLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(result: PingResult, presentation: StatusPresentation, updatedAt: String) {
        dotView.color = presentation.color
        latencyLabel.stringValue = presentation.summaryTitle
        latencyLabel.textColor = presentation.color
        detailLabel.stringValue = presentation.detail
        hostLabel.stringValue = "Cible: \(result.host)"
        updatedLabel.stringValue = "Derniere mesure: \(updatedAt)"
    }

    private func buildView() {
        appLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        appLabel.textColor = .secondaryLabelColor

        latencyLabel.font = .monospacedDigitSystemFont(ofSize: 25, weight: .bold)
        latencyLabel.lineBreakMode = .byTruncatingTail
        latencyLabel.maximumNumberOfLines = 1

        detailLabel.font = .systemFont(ofSize: 13, weight: .medium)
        detailLabel.textColor = .labelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1

        hostLabel.font = .systemFont(ofSize: 12)
        hostLabel.textColor = .secondaryLabelColor
        hostLabel.lineBreakMode = .byTruncatingTail
        hostLabel.maximumNumberOfLines = 1

        updatedLabel.font = .systemFont(ofSize: 11)
        updatedLabel.textColor = .tertiaryLabelColor
        updatedLabel.lineBreakMode = .byTruncatingTail
        updatedLabel.maximumNumberOfLines = 1

        let headerStack = NSStackView(views: [dotView, appLabel])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 7

        let stack = NSStackView(views: [headerStack, latencyLabel, detailLabel, hostLabel, updatedLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            dotView.widthAnchor.constraint(equalToConstant: 10),
            dotView.heightAnchor.constraint(equalToConstant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11)
        ])
    }
}

@MainActor
private final class PingBarController: NSObject {
    private let defaults = UserDefaults.standard
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor: PingMonitor
    private let menu = NSMenu()
    private let summaryItem = NSMenuItem()
    private let summaryView = PingSummaryView(frame: NSRect(x: 0, y: 0, width: 280, height: 108))
    private let hostItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

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

        button.attributedTitle = menuBarTitle("Ping ...", color: .systemBlue)
        button.image = symbol("dot.radiowaves.left.and.right")
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .systemBlue
        button.toolTip = "PingBar"
    }

    private func configureMenu() {
        menu.autoenablesItems = false

        summaryItem.view = summaryView

        hostItem.isEnabled = false
        lastItem.isEnabled = false
        stateItem.isEnabled = false
        hostItem.image = symbol("globe")
        lastItem.image = symbol("clock")
        stateItem.image = symbol("circle.fill")

        let refreshItem = NSMenuItem(
            title: "Rafraichir maintenant",
            action: #selector(refreshNow),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        refreshItem.image = symbol("arrow.clockwise")

        let targetItem = NSMenuItem(
            title: "Changer la cible...",
            action: #selector(changeTarget),
            keyEquivalent: ","
        )
        targetItem.target = self
        targetItem.image = symbol("target")

        let quitItem = NSMenuItem(
            title: "Quitter PingBar",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.image = symbol("power")

        menu.addItem(summaryItem)
        menu.addItem(.separator())
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
        let presentation = presentation(for: result)
        let updatedAt = timeFormatter.string(from: result.date)

        applyStatusButton(presentation)
        summaryView.update(result: result, presentation: presentation, updatedAt: updatedAt)

        hostItem.title = "Cible: \(result.host)"
        lastItem.title = "Derniere mesure: \(updatedAt)"
        stateItem.title = presentation.detail
        stateItem.image = symbol(presentation.symbolName)
    }

    private func applyStatusButton(_ presentation: StatusPresentation) {
        guard let button = statusItem.button else {
            return
        }

        button.attributedTitle = menuBarTitle(presentation.buttonTitle, color: presentation.color)
        button.image = symbol(presentation.symbolName)
        button.contentTintColor = presentation.color
        button.toolTip = presentation.toolTip
    }

    private func presentation(for result: PingResult) -> StatusPresentation {
        switch result.status {
        case .measuring:
            return StatusPresentation(
                buttonTitle: "Ping ...",
                summaryTitle: "Ping ...",
                detail: "Mesure en cours",
                color: .systemBlue,
                symbolName: "dot.radiowaves.left.and.right",
                toolTip: "Ping vers \(result.host)"
            )

        case .success(let milliseconds):
            let latency = formatLatency(milliseconds)
            let quality = quality(for: milliseconds)
            return StatusPresentation(
                buttonTitle: latency,
                summaryTitle: latency,
                detail: "Qualite: \(quality.label)",
                color: quality.color,
                symbolName: quality.symbolName,
                toolTip: "Ping vers \(result.host): \(latency)"
            )

        case .timeout:
            return StatusPresentation(
                buttonTitle: "Timeout",
                summaryTitle: "Timeout",
                detail: "Pas de reponse",
                color: .systemRed,
                symbolName: "exclamationmark.triangle.fill",
                toolTip: "Ping vers \(result.host): timeout"
            )

        case .failure(let message):
            return StatusPresentation(
                buttonTitle: "Ping ERR",
                summaryTitle: "Ping ERR",
                detail: message,
                color: .systemRed,
                symbolName: "xmark.octagon.fill",
                toolTip: "Ping vers \(result.host): \(message)"
            )
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

    private func quality(for milliseconds: Double) -> (label: String, color: NSColor, symbolName: String) {
        switch milliseconds {
        case ..<60:
            return ("Bon", .systemGreen, "checkmark.circle.fill")
        case ..<120:
            return ("Moyen", .systemOrange, "exclamationmark.circle.fill")
        default:
            return ("Eleve", .systemRed, "exclamationmark.triangle.fill")
        }
    }

    private func menuBarTitle(_ title: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: color
            ]
        )
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
