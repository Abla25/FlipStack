import XCTest
@testable import FlipStackCore

final class QueueVisibilityTests: XCTestCase {
    private func job(id: Int, owner: String?) -> PrintJob {
        PrintJob(id: id, printerID: "queue", title: "FlipStack job", owner: owner)
    }

    func testOnlyCurrentUserAndSessionJobsAreVisible() {
        let owned = job(id: 1, owner: "demo-user")
        let foreign = job(id: 2, owner: "someone-else")
        let unowned = job(id: 3, owner: nil)
        let local = job(id: 4, owner: "someone-else")

        XCTAssertTrue(owned.isVisible(to: "demo-user"))
        XCTAssertFalse(foreign.isVisible(to: "demo-user"))
        XCTAssertFalse(unowned.isVisible(to: "demo-user"))
        XCTAssertTrue(local.isVisible(to: "demo-user", localJobIDs: [4]))
    }
}
