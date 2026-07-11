import AppKit
import SwiftUI
import XCTest
@testable import AIUsageMonitor

@MainActor
final class StatusItemControllerTests: XCTestCase {
    func testProductionEventViewDeliversLeftAndRightMouseUpThroughDistinctOverrides() throws {
        var actions: [StatusItemClickAction] = []
        let eventView = StatusItemEventView { actions.append($0) }

        eventView.mouseUp(with: try mouseEvent(.leftMouseUp))
        eventView.rightMouseUp(with: try mouseEvent(.rightMouseUp))

        XCTAssertEqual(actions, [.togglePopover, .showContextMenu])
    }

    func testInstalledRightMouseUpPresentsExactMenuOnceThroughInjectedPresenter() throws {
        let presenter = SpyStatusContextMenuPresenter()
        let controller = StatusItemController(
            store: makeStore(),
            contextMenuPresenter: presenter
        )
        let eventView = try XCTUnwrap(controller.eventView)

        eventView.mouseUp(with: try mouseEvent(.leftMouseUp))
        XCTAssertTrue(presenter.calls.isEmpty, "Left click must not present the context menu")
        controller.popover.performClose(nil)

        eventView.rightMouseUp(with: try mouseEvent(.rightMouseUp))

        XCTAssertEqual(presenter.calls.count, 1)
        let call = try XCTUnwrap(presenter.calls.first)
        XCTAssertTrue(call.statusItem === controller.statusItem)
        assertContextMenu(call.menu, launchAtLogin: false, target: controller)
    }

    func testProductionPresenterAttachesMenuDuringActivationAndAlwaysClearsIt() {
        let statusBar = NSStatusBar.system
        let statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(title: "Context Menu Proof")
        var activationCount = 0
        defer { statusBar.removeStatusItem(statusItem) }

        let presenter = AppKitStatusContextMenuPresenter { presentedStatusItem in
            activationCount += 1
            XCTAssertTrue(presentedStatusItem === statusItem)
            XCTAssertTrue(presentedStatusItem.menu === menu)
        }

        presenter.present(menu, from: statusItem)

        XCTAssertEqual(activationCount, 1)
        XCTAssertNil(statusItem.menu)
    }

    func testControllerInstallsProductionEventViewOnRealStatusButton() throws {
        let controller = StatusItemController(store: makeStore())
        let eventView = try XCTUnwrap(controller.eventView)
        let button = try XCTUnwrap(eventView.superview as? NSStatusBarButton)

        XCTAssertTrue(button.subviews.contains { $0 === eventView })
        XCTAssertEqual(eventView.identifier?.rawValue, "status-item-event-view")
        XCTAssertEqual(eventView.constraints.count, 0)
        XCTAssertEqual(button.constraints.filter { $0.firstItem as? NSView === eventView || $0.secondItem as? NSView === eventView }.count, 4)
    }

    func testProductionPopoverUsesSharedTypedHostAtFixedContentSize() throws {
        let configuration = UsagePopoverConfiguration.populatedFixture
        let controller = StatusItemController(
            store: makeStore(),
            popoverConfiguration: configuration
        )
        let host = try XCTUnwrap(controller.popover.contentViewController as? NSHostingController<UsagePopoverView>)

        XCTAssertEqual(controller.popover.contentSize.width, UsagePopoverMetrics.contentWidth)
        XCTAssertEqual(controller.popover.contentSize.height, UsagePopoverMetrics.contentHeight)
        XCTAssertEqual(host.rootView.configuration, configuration)
    }

    func testContextMenuOrderShortcutsAndLaunchCheckmark() {
        let menu = StatusContextMenuFactory.makeMenu(target: nil, launchAtLogin: true)

        assertContextMenu(menu, launchAtLogin: true, target: nil)
    }

    func testContextMenuLaunchCheckmarkReflectsDisabledState() {
        let menu = StatusContextMenuFactory.makeMenu(target: nil, launchAtLogin: false)

        XCTAssertEqual(menu.items[4].title, "Launch at Login")
        XCTAssertEqual(menu.items[4].state, .off)
    }

    private func mouseEvent(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ))
    }

    private func assertContextMenu(
        _ menu: NSMenu,
        launchAtLogin: Bool,
        target: AnyObject?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(menu.autoenablesItems, file: file, line: line)
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "separator" : $0.title }, [
            "Refresh Now",
            "Open AI Usage…",
            "separator",
            "Pause Alerts for 1 Hour",
            "Launch at Login",
            "separator",
            "Quit AI Usage"
        ], file: file, line: line)
        XCTAssertEqual(menu.items[0].action, #selector(StatusItemController.refreshFromMenu(_:)), file: file, line: line)
        XCTAssertEqual(menu.items[1].action, #selector(StatusItemController.openUsageFromMenu(_:)), file: file, line: line)
        XCTAssertEqual(menu.items[3].action, #selector(StatusItemController.pauseAlertsFromMenu(_:)), file: file, line: line)
        XCTAssertEqual(menu.items[4].action, #selector(StatusItemController.toggleLaunchAtLoginFromMenu(_:)), file: file, line: line)
        XCTAssertEqual(menu.items[6].action, #selector(StatusItemController.quitFromMenu(_:)), file: file, line: line)
        XCTAssertEqual(menu.items[0].keyEquivalent, "r", file: file, line: line)
        XCTAssertEqual(menu.items[0].keyEquivalentModifierMask, [.command], file: file, line: line)
        XCTAssertEqual(menu.items[4].state, launchAtLogin ? .on : .off, file: file, line: line)
        XCTAssertEqual(menu.items[6].keyEquivalent, "q", file: file, line: line)
        XCTAssertEqual(menu.items[6].keyEquivalentModifierMask, [.command], file: file, line: line)
        XCTAssertTrue(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.isEnabled }, file: file, line: line)

        for item in menu.items where !item.isSeparatorItem {
            if let target {
                XCTAssertTrue(item.target === target, file: file, line: line)
            } else {
                XCTAssertNil(item.target, file: file, line: line)
            }
        }
    }

    private func makeStore() -> UsageMonitorStore {
        UsageMonitorStore(
            dependencies: AppCompositionRoot.fixture(snapshot: UsageMonitorFixtures.criticalSnapshot),
            initialSnapshot: UsageMonitorFixtures.criticalSnapshot
        )
    }
}

@MainActor
private final class SpyStatusContextMenuPresenter: StatusContextMenuPresenting {
    struct Call {
        var menu: NSMenu
        var statusItem: NSStatusItem
    }

    private(set) var calls: [Call] = []

    func present(_ menu: NSMenu, from statusItem: NSStatusItem) {
        calls.append(Call(menu: menu, statusItem: statusItem))
    }
}
