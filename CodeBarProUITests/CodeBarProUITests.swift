//
//  CodeBarProUITests.swift
//  CodeBarProUITests
//
//  Created by charles qin on 4/26/26.
//

import XCTest

final class CodeBarProUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testExample() throws {
        throw XCTSkip("CodeBarPro is an LSUIElement menu bar app; add menu bar-specific automation before enabling UI tests.")
    }

    @MainActor
    func testLaunchPerformance() throws {
        throw XCTSkip("CodeBarPro is an LSUIElement menu bar app; launch screenshots do not verify the menu bar UI.")
    }
}
