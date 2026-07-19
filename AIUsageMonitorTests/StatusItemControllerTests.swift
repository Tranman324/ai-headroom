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

    func testProductionPopoverUsesSharedTypedHostWithContentSizedHeight() throws {
        let configuration = UsagePopoverConfiguration.populatedFixture
        let controller = StatusItemController(
            store: makeStore(snapshot: UsageMonitorFixtures.noDataSnapshot),
            popoverConfiguration: configuration
        )
        let host = try XCTUnwrap(controller.popover.contentViewController as? NSHostingController<UsagePopoverView>)

        XCTAssertEqual(host.sizingOptions, .preferredContentSize)
        XCTAssertEqual(controller.popover.contentSize.width, UsagePopoverMetrics.contentWidth)
        XCTAssertGreaterThan(controller.popover.contentSize.height, 0)
        XCTAssertLessThan(controller.popover.contentSize.height, 520)
        XCTAssertEqual(host.preferredContentSize, controller.popover.contentSize)
        XCTAssertEqual(host.rootView.configuration, configuration)
    }

    func testPopoverResizesWhenNavigationContentChanges() async throws {
        let store = makeStore(snapshot: UsageMonitorFixtures.noDataSnapshot)
        let controller = StatusItemController(store: store)
        let listHeight = controller.popover.contentSize.height

        store.navigation.isSettingsPresented = true
        await Task.yield()
        await Task.yield()

        XCTAssertNotEqual(controller.popover.contentSize.height, listHeight)
        XCTAssertEqual(
            controller.popover.contentViewController?.preferredContentSize,
            controller.popover.contentSize
        )
    }

    func testFixtureWindowObservesNavigationAndStoreContentForIntrinsicResizing() async throws {
        let store = UsageMonitorStore(
            dependencies: AppCompositionRoot.fixture(snapshot: UsageMonitorFixtures.criticalSnapshot),
            initialSnapshot: UsageMonitorFixtures.noDataSnapshot
        )
        let configuration = FixtureLaunchConfiguration(
            launchMode: .fixture(.normal),
            shouldOpenFixtureWindow: true,
            shouldWriteScreenshot: false,
            shouldTerminateAfterScreenshot: false,
            startsWithHistoryExpanded: false,
            screenshotDirectory: nil
        )
        let controller = FixtureWindowController(store: store, configuration: configuration)
        let initialSize = controller.window.contentLayoutRect.size

        store.navigation.isSettingsPresented = true
        await Task.yield()
        await Task.yield()
        let settingsSize = controller.window.contentLayoutRect.size

        XCTAssertEqual(initialSize.width, UsagePopoverMetrics.contentWidth)
        XCTAssertEqual(settingsSize.width, UsagePopoverMetrics.contentWidth)
        XCTAssertNotEqual(settingsSize.height, initialSize.height)

        store.navigation.isSettingsPresented = false
        store.navigation.isHistoryExpanded = true
        await Task.yield()
        await Task.yield()
        let expandedListSize = controller.window.contentLayoutRect.size

        XCTAssertEqual(expandedListSize.width, UsagePopoverMetrics.contentWidth)
        XCTAssertNotEqual(expandedListSize.height, settingsSize.height)
        XCTAssertEqual(
            controller.window.contentViewController?.preferredContentSize,
            expandedListSize
        )
    }

    func testGaugeTrackRemainsVisibleAcrossUpperHalfAtMenuBarSize() throws {
        let image = StatusItemGaugeRenderer.image(utilization: 5, color: .white)
        let representation = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let fullHeight = 0..<representation.pixelsHigh
        let bitmapTopHalf = (representation.pixelsHigh / 2)..<representation.pixelsHigh
        let thirdWidth = representation.pixelsWide / 3
        let horizontalThirds = [
            0..<thirdWidth,
            thirdWidth..<(thirdWidth * 2),
            (thirdWidth * 2)..<representation.pixelsWide
        ]

        XCTAssertEqual(image.size, NSSize(width: 18, height: 14))
        XCTAssertGreaterThan(
            visiblePixelCount(
                in: representation,
                xRange: 0..<representation.pixelsWide,
                yRange: bitmapTopHalf
            ),
            0,
            "The gauge crown must reach the top half of the menu-bar canvas"
        )
        for third in horizontalThirds {
            XCTAssertGreaterThan(
                visiblePixelCount(in: representation, xRange: third, yRange: fullHeight),
                0,
                "The gauge track must remain visible across every horizontal third"
            )
        }
    }

    func testStatusButtonContentWritesLightAndDarkVisualEvidence() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIUsageMonitorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let samples: [(String, CombinedUsageSnapshot)] = [
            ("normal", UsageMonitorFixtures.normalSnapshot),
            ("warning", UsageMonitorFixtures.warningSnapshot),
            ("critical", UsageMonitorFixtures.criticalSnapshot)
        ]
        let appearances: [(String, NSAppearance.Name, NSColor)] = [
            ("light", .aqua, NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1)),
            ("dark", .darkAqua, NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1))
        ]

        for (stateName, snapshot) in samples {
            let controller = StatusItemController(store: makeStore(snapshot: snapshot))
            let button = try XCTUnwrap(controller.statusItem.button)
            XCTAssertFalse(try XCTUnwrap(button.image).isTemplate)

            for (appearanceName, appearanceNameValue, backgroundColor) in appearances {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceNameValue))
                let data = try statusButtonEvidence(
                    button,
                    appearance: appearance,
                    backgroundColor: backgroundColor
                )
                let destination = outputDirectory.appendingPathComponent(
                    "status-item-\(stateName)-\(appearanceName)@2x.png"
                )
                try data.write(to: destination, options: .atomic)
                XCTAssertGreaterThan(data.count, 500)
            }
        }
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

    private func statusButtonEvidence(
        _ button: NSStatusBarButton,
        appearance: NSAppearance,
        backgroundColor: NSColor
    ) throws -> Data {
        let buttonSize = button.bounds.size
        XCTAssertGreaterThan(buttonSize.width, 18)
        XCTAssertGreaterThanOrEqual(buttonSize.height, 22)

        let canvasSize = NSSize(width: buttonSize.width + 16, height: 30)
        let canvas = NSView(frame: NSRect(origin: .zero, size: canvasSize))
        canvas.appearance = appearance
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = backgroundColor.cgColor

        let evidenceButton = NSButton(frame: NSRect(
            x: 8,
            y: (canvasSize.height - buttonSize.height) / 2,
            width: buttonSize.width,
            height: buttonSize.height
        ))
        evidenceButton.appearance = appearance
        evidenceButton.imagePosition = button.imagePosition
        evidenceButton.isBordered = button.isBordered
        evidenceButton.image = button.image
        evidenceButton.attributedTitle = button.attributedTitle
        evidenceButton.wantsLayer = true
        evidenceButton.layer?.cornerRadius = button.layer?.cornerRadius ?? 0
        evidenceButton.layer?.backgroundColor = button.layer?.backgroundColor
        canvas.addSubview(evidenceButton)
        canvas.layoutSubtreeIfNeeded()
        canvas.displayIfNeeded()

        let scale: CGFloat = 2
        let canvasBitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(canvasSize.width * scale)),
            pixelsHigh: Int(ceil(canvasSize.height * scale)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        canvasBitmap.size = canvasSize
        appearance.performAsCurrentDrawingAppearance {
            canvas.cacheDisplay(in: canvas.bounds, to: canvasBitmap)
        }
        return try XCTUnwrap(canvasBitmap.representation(using: .png, properties: [:]))
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

    private func visiblePixelCount(
        in representation: NSBitmapImageRep,
        xRange: Range<Int>,
        yRange: Range<Int>
    ) -> Int {
        yRange.reduce(into: 0) { count, y in
            for x in xRange where (representation.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                count += 1
            }
        }
    }

    private func makeStore(snapshot: CombinedUsageSnapshot = UsageMonitorFixtures.criticalSnapshot) -> UsageMonitorStore {
        UsageMonitorStore(
            dependencies: AppCompositionRoot.fixture(snapshot: snapshot),
            initialSnapshot: snapshot
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
