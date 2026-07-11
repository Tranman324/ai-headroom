import XCTest

final class AIUsageMonitorUITests: XCTestCase {
    func testApplicationLaunchesAsMenuBarAgent() {
        let app = XCUIApplication()

        app.launch()

        XCTAssertNotEqual(app.state, .notRunning)
        app.terminate()
    }
}
