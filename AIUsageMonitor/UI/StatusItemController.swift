import AppKit
import Combine
import SwiftUI

enum StatusItemClickAction: Equatable {
    case togglePopover
    case showContextMenu
}

final class StatusItemEventView: NSView {
    var onAction: (StatusItemClickAction) -> Void

    init(onAction: @escaping (StatusItemClickAction) -> Void) {
        self.onAction = onAction
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("status-item-event-view")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {}

    override func rightMouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        onAction(.togglePopover)
    }

    override func rightMouseUp(with event: NSEvent) {
        onAction(.showContextMenu)
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
protocol StatusContextMenuPresenting {
    func present(_ menu: NSMenu, from statusItem: NSStatusItem)
}

@MainActor
final class AppKitStatusContextMenuPresenter: StatusContextMenuPresenting {
    typealias MenuActivation = @MainActor (NSStatusItem) -> Void

    private let activateMenu: MenuActivation

    init(activateMenu: @escaping MenuActivation = { statusItem in
        statusItem.button?.performClick(nil)
    }) {
        self.activateMenu = activateMenu
    }

    func present(_ menu: NSMenu, from statusItem: NSStatusItem) {
        statusItem.menu = menu
        defer { statusItem.menu = nil }
        activateMenu(statusItem)
    }
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: UsageMonitorStore
    private let statusBar: NSStatusBar
    private(set) var statusItem: NSStatusItem
    private(set) var popover: NSPopover
    private(set) var eventView: StatusItemEventView?
    private let popoverConfiguration: UsagePopoverConfiguration
    private let contextMenuPresenter: any StatusContextMenuPresenting
    private var cancellables: Set<AnyCancellable> = []
    private var intrinsicSizeObserver: UsagePopoverIntrinsicSizeObserver?

    init(
        store: UsageMonitorStore,
        statusBar: NSStatusBar = .system,
        popoverConfiguration: UsagePopoverConfiguration = .production,
        contextMenuPresenter: (any StatusContextMenuPresenting)? = nil
    ) {
        self.store = store
        self.statusBar = statusBar
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.popoverConfiguration = popoverConfiguration
        self.contextMenuPresenter = contextMenuPresenter ?? AppKitStatusContextMenuPresenter()
        super.init()

        configureButton()
        configurePopover()
        observeStore()
        updateStatusButton(with: store.snapshot)
    }

    deinit {
        MainActor.assumeIsolated {
            statusBar.removeStatusItem(statusItem)
        }
    }

    func handleStatusItemAction(_ action: StatusItemClickAction) {
        switch action {
        case .togglePopover:
            togglePopover()
        case .showContextMenu:
            showContextMenu()
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
        run(.pauseAlertsForOneHour)
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

        let eventView = StatusItemEventView { [weak self] action in
            self?.handleStatusItemAction(action)
        }
        eventView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(eventView, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            eventView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            eventView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            eventView.topAnchor.constraint(equalTo: button.topAnchor),
            eventView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        self.eventView = eventView

        button.imagePosition = .imageLeading
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 11
        button.identifier = NSUserInterfaceItemIdentifier("status-item-button")
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        let hostingController = UsagePopoverHostFactory.makeHostingController(
            store: store,
            configuration: popoverConfiguration
        )
        popover.contentViewController = hostingController
        intrinsicSizeObserver = UsagePopoverIntrinsicSizeObserver(
            store: store,
            hostingController: hostingController
        ) { [weak popover] contentSize in
            popover?.contentSize = contentSize
        }
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
        contextMenuPresenter.present(menu, from: statusItem)
    }

    private func run(_ command: AppIntentCommand) {
        Task { @MainActor in
            try? await store.handle(command)
        }
    }
}
