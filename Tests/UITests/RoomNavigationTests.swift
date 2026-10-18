import XCTest

final class RoomNavigationTests: XCTestCase {
    func testSampleRoomNavigationAndEquipmentPersistence() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["roomOptions"].tap()
        app.buttons["Add sample room"].tap()
        let sample = app.staticTexts["Sample room · simulated"].firstMatch
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        sample.tap()
        app.buttons["Explore room & equipment"].tap()
        XCTAssertTrue(app.buttons["Add equipment"].waitForExistence(timeout: 10))
        app.buttons["Add equipment"].tap()
        let scene = app.otherElements["roomScene"].firstMatch
        XCTAssertTrue(scene.waitForExistence(timeout: 5))
        scene.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        let field = app.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let name = "Test sensor " + UUID().uuidString.prefix(6)
        field.typeText(String(name))
        app.buttons["Save"].tap()
        let equipment = app.buttons[String(name)].firstMatch
        XCTAssertTrue(equipment.waitForExistence(timeout: 5))
        equipment.tap()
        XCTAssertTrue(app.staticTexts["No readings yet"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        let overview = XCTAttachment(screenshot: app.screenshot()); overview.name = "Overview with equipment"; overview.lifetime = .keepAlways
        add(overview)
        app.buttons["Walk inside"].tap()
        scene.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        let start = scene.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: scene.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Walk inside with equipment"; shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Close"].tap()
        app.buttons["Explore room & equipment"].tap()
        XCTAssertTrue(app.buttons[String(name)].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
}
