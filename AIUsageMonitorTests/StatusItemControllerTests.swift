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
        let titles = menu.items.map { $0.isSeparatorItem ? "separator" : $0.title }

        XCTAssertEqual(titles, [
            "Refresh Now",
            "Open AI Usage…",
            "separator",
            "Pause Alerts for 1 Hour",
            "Launch at Login",
            "separator",
            "Quit AI Usage"
        ])

        XCTAssertEqual(menu.items[0].keyEquivalent, "r")
        XCTAssertEqual(menu.items[0].keyEquivalentModifierMask, [.command])
        XCTAssertEqual(menu.items[4].state, .on)
        XCTAssertEqual(menu.items[6].keyEquivalent, "q")
        XCTAssertEqual(menu.items[6].keyEquivalentModifierMask, [.command])
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

    private func makeStore() -> UsageMonitorStore {
        UsageMonitorStore(
            dependencies: AppCompositionRoot.fixture(snapshot: UsageMonitorFixtures.criticalSnapshot),
            initialSnapshot: UsageMonitorFixtures.criticalSnapshot
        )
    }
}
