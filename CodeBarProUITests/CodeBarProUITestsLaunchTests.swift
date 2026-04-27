//
//  CodeBarProUITestsLaunchTests.swift
//  CodeBarProUITests
//
//  Created by charles qin on 4/26/26.
//

import XCTest

final class CodeBarProUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        throw XCTSkip("CodeBarPro is an LSUIElement menu bar app; launch screenshots do not verify the menu bar UI.")
    }
}
