import XCTest
@testable import AIUsageMonitor

final class LifecycleContractTests: XCTestCase {
    func testLifecycleContractIncludesWorkspaceSleepAndWakeEvents() {
        XCTAssertEqual(AppLifecycleEvent.workspaceWillSleep.rawValue, "workspaceWillSleep")
        XCTAssertEqual(AppLifecycleEvent.workspaceDidWake.rawValue, "workspaceDidWake")
    }
}
