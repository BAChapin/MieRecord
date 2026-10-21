import XCTest

/// End-to-end check of Milestone 1 behavior on the simulator: start a
/// recording, see the live screen, stop, and open the saved recording.
/// Live transcription may be unavailable on the simulator; the test only
/// requires the recording itself to survive the round trip.
final class RecordingFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRecordStopAndOpenRecording() throws {
        let app = XCUIApplication()
        app.launch()

        // Accept the microphone prompt if the simulator shows one.
        addUIInterruptionMonitor(withDescription: "Microphone") { alert in
            for label in ["Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }

        let recordButton = app.buttons["Record"].firstMatch
        XCTAssertTrue(recordButton.waitForExistence(timeout: 10), "Record button should be on the list screen")
        recordButton.tap()
        app.tap() // Triggers the interruption monitor if an alert is up.

        let stopButton = app.buttons["Stop"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 20), "Recording should start and show Stop")
        XCTAssertTrue(app.staticTexts["Recording"].waitForExistence(timeout: 5))

        // Record a few seconds so the file has content.
        sleep(4)
        stopButton.tap()

        // The live screen dismisses itself once the recording is saved.
        let navTitle = app.navigationBars["Recordings"]
        XCTAssertTrue(navTitle.waitForExistence(timeout: 30), "Should return to the list after stopping")

        let firstRow = app.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "The new recording should be listed")
        XCTAssertTrue(firstRow.staticTexts.element(matching: NSPredicate(format: "label BEGINSWITH 'Recording '")).exists)
        firstRow.tap()

        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "Detail screen should show playback controls")
        XCTAssertTrue(play.isEnabled, "The saved audio file should be playable")
        XCTAssertTrue(app.staticTexts["Duration"].exists)
    }
}
