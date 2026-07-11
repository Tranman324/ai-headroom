import AppKit
import XCTest
@testable import AIUsageMonitor

final class StatusItemControllerTests: XCTestCase {
    func testLeftAndRightMouseEventsRouteToDistinctActions() throws {
        XCTAssertEqual(
            StatusItemClickRouter.action(for: try mouseEvent(.leftMouseUp)),
            .togglePopover
        )
        XCTAssertEqual(
            StatusItemClickRouter.action(for: try mouseEvent(.rightMouseUp)),
            .showContextMenu
        )
        XCTAssertEqual(
            StatusItemClickRouter.action(for: try mouseEvent(.otherMouseUp)),
            .ignore
        )
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
}
