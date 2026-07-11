import AppKit
import Combine
import SwiftUI

enum StatusItemClickAction: Equatable {
    case togglePopover
    case showContextMenu
    case ignore
}

enum StatusItemClickRouter {
    static func action(for event: NSEvent?) -> StatusItemClickAction {
        guard let event else {
            return .togglePopover
        }

        switch event.type {
        case .leftMouseUp:
            return .togglePopover
        case .rightMouseUp:
            return .showContextMenu
        default:
            return .ignore
        }
    }
}

enum StatusContextMenuFactory {
    static func makeMenu(target: AnyObject?, launchAtLogin: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(menuItem(
            title: "Refresh Now",
            action: #selector(StatusItemController.refreshFromMenu(_:)),
            keyEquivalent: "r",
            target: target
        ))
        menu.addItem(menuItem(
            title: "Open AI Usage…",
            action: #selector(StatusItemController.openUsageFromMenu(_:)),
            target: target
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            title: "Pause Alerts for 1 Hour",
            action: #selector(StatusItemController.pauseAlertsFromMenu(_:)),
            target: target
        ))

        let launchItem = menuItem(
            title: "Launch at Login",
            action: #selector(StatusItemController.toggleLaunchAtLoginFromMenu(_:)),
            target: target
        )
        launchItem.state = launchAtLogin ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())
        menu.addItem(menuItem(
            title: "Quit AI Usage",
            action: #selector(StatusItemController.quitFromMenu(_:)),
            keyEquivalent: "q",
            target: target
        ))

        return menu
    }

    private static func menuItem(
        title: String,
        action: Selector,
        keyEquivalent: String = "",
        target: AnyObject?
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        item.keyEquivalentModifierMask = keyEquivalent.isEmpty ? [] : [.command]
        item.isEnabled = true
        return item
    }
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: UsageMonitorStore
    private let statusBar: NSStatusBar
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let now: () -> Date
    private var cancellables: Set<AnyCancellable> = []

    init(
        store: UsageMonitorStore,
        statusBar: NSStatusBar = .system,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.statusBar = statusBar
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.now = now
        super.init()

        configureButton()
        configurePopover()
        observeStore()
        updateStatusButton(with: store.snapshot)
    }

    deinit {
        statusBar.removeStatusItem(statusItem)
    }

    @objc func statusButtonActivated(_ sender: Any?) {
        switch StatusItemClickRouter.action(for: NSApp.currentEvent) {
        case .togglePopover:
            togglePopover()
        case .showContextMenu:
            showContextMenu()
        case .ignore:
            break
        }
    }

    @objc func refreshFromMenu(_ sender: NSMenuItem) {
        run(.refresh)
    }

    @objc func openUsageFromMenu(_ sender: NSMenuItem) {
        run(.backFromMeterDetail)
        showPopover()
    }

    @objc func pauseAlertsFromMenu(_ sender: NSMenuItem) {
        run(.pauseAlerts(until: now().addingTimeInterval(60 * 60)))
    }

    @objc func toggleLaunchAtLoginFromMenu(_ sender: NSMenuItem) {
        run(.setLaunchAtLogin(!store.settings.launchAtLogin))
    }

    @objc func quitFromMenu(_ sender: NSMenuItem) {
        run(.quit)
    }

    private func configureButton() {
        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(statusButtonActivated(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 11
        button.identifier = NSUserInterfaceItemIdentifier("status-item-button")
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(
            width: UsagePopoverMetrics.contentWidth,
            height: UsagePopoverMetrics.contentHeight
        )
        popover.contentViewController = NSHostingController(rootView: UsagePopoverView(store: store))
        popover.delegate = self
    }

    private func observeStore() {
        store.$snapshot
            .sink { [weak self] snapshot in
                self?.updateStatusButton(with: snapshot)
            }
            .store(in: &cancellables)
    }

    private func updateStatusButton(with snapshot: CombinedUsageSnapshot) {
        guard let button = statusItem.button else {
            return
        }

        let presentation = UsagePresentation.statusItem(for: snapshot)
        statusItem.length = presentation.showsCriticalCapsule ? 68 : 60
        button.image = StatusItemGaugeRenderer.image(
            utilization: presentation.utilization ?? 0,
            color: presentation.iconColor
        )
        button.attributedTitle = NSAttributedString(
            string: presentation.percentText,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: presentation.textColor
            ]
        )
        button.layer?.backgroundColor = presentation.backgroundColor?.deviceRGBColor.cgColor
        button.toolTip = presentation.accessibilityLabel
        button.setAccessibilityLabel(presentation.accessibilityLabel)
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showContextMenu() {
        let menu = StatusContextMenuFactory.makeMenu(
            target: self,
            launchAtLogin: store.settings.launchAtLogin
        )
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func run(_ command: AppIntentCommand) {
        Task { @MainActor in
            try? await store.handle(command)
        }
    }
}

enum StatusItemGaugeRenderer {
    static func image(utilization: Double, color: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()

        let center = NSPoint(x: 9, y: 3.5)
        let radius: CGFloat = 7
        let strokeColor = color.deviceRGBColor
        strokeColor.setStroke()

        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 200,
            endAngle: -20,
            clockwise: false
        )
        arc.lineWidth = 1.8
        arc.lineCapStyle = .round
        arc.stroke()

        let angle = UsagePresentation.needleAngleDegrees(for: utilization)
        let radians = (angle + 90) * .pi / 180
        let needleEnd = NSPoint(
            x: center.x + cos(radians) * 5.2,
            y: center.y + sin(radians) * 5.2
        )
        let needle = NSBezierPath()
        needle.move(to: center)
        needle.line(to: needleEnd)
        needle.lineWidth = 1.4
        needle.lineCapStyle = .round
        needle.stroke()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
