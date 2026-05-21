//
//  NotEnoughFeeSpaceViewSnapshots.swift
//  secantTests
//
//  Created by Michal Fousek on 28.09.2022.
//

import XCTest
import ComposableArchitecture
@testable import zashi_internal

class NotEnoughFeeSpaceSnapshots: XCTestCase {
    func testNotEnoughFreeSpaceSnapshot() throws {
        let store = StoreOf<NotEnoughFreeSpace>(
            initialState: .initial
        ) {
            NotEnoughFreeSpace()
                .dependency(\.diskSpaceChecker, .mockEmptyDisk)
        }
        
        addAttachments(NotEnoughFreeSpaceView(store: store))
    }
}
