//
//  TransactionStateTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 08.11.2023.
//

import XCTest
@preconcurrency import ZcashLightClientKit

final class TransactionStateTests: XCTestCase {
    // MARK: - Title tests (String & Color)
    
    func testTitleSent() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .paid,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_000_000),
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false
        )
        
        XCTAssertEqual(transaction.title, String(localizable: .transactionSent))
    }

    func testTitleSentColor() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .paid,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_000_000),
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false
        )
        
        XCTAssertEqual(transaction.titleColor, Asset.Colors.primary.color)
    }

    func testTitleReceived() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .received,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_000_000),
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false
        )
        
        XCTAssertEqual(transaction.title, String(localizable: .transactionReceived))
    }
    
    func testTitleReceivedColor() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .received,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_000_000),
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false
        )
        
        XCTAssertEqual(transaction.titleColor, Asset.Colors.primary.color)
    }
    
    func testTitleSending() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .sending,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_000_000),
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false
        )
        
        XCTAssertEqual(transaction.title, String(localizable: .transactionSending))
    }
    
    func testTitleSendingColor() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .sending,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_000_000),
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false
        )
        
        XCTAssertEqual(transaction.titleColor, Asset.Colors.shade47.color)
    }
    
    func testTitleReceiving() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .receiving,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_000_000),
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false
        )
        
        XCTAssertEqual(transaction.title, String(localizable: .transactionReceiving))
    }
    
    func testTitleReceivingColor() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .receiving,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_000_000),
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false
        )
        
        XCTAssertEqual(transaction.titleColor, Asset.Colors.shade47.color)
    }
    
    func testTitleFailedSend() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .failed,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_000_000),
            isSentTransaction: true,
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false
        )
        
        XCTAssertEqual(transaction.title, String(localizable: .transactionFailedSend))
    }
    
    func testTitleFailedSendColor() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .failed,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_000_000),
            isSentTransaction: true,
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false
        )
        
        XCTAssertEqual(transaction.titleColor, Design.Utility.ErrorRed._600.color)
    }
    
    func testTitleFailedReceived() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .failed,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_000_000),
            isSentTransaction: false,
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false
        )
        
        XCTAssertEqual(transaction.title, String(localizable: .transactionFailedReceive))
    }
    
    func testTitleFailedReceivedColor() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .failed,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_000_000),
            isSentTransaction: false,
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false
        )
        
        XCTAssertEqual(transaction.titleColor, Design.Utility.ErrorRed._600.color)
    }

    // MARK: - Balance color
    
    func testBalanceSentColor() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .paid,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_000_000),
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false
        )
        
        XCTAssertEqual(transaction.balanceColor, Design.Utility.ErrorRed._600.color)
    }
    
    func testBalanceReceivedColor() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .received,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_000_000),
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false
        )
        
        XCTAssertEqual(transaction.balanceColor, Asset.Colors.primary.color)
    }
    
    func testBalanceFailedSendColor() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .failed,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_000_000),
            isSentTransaction: true,
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false
        )
        
        XCTAssertEqual(transaction.balanceColor, Design.Utility.ErrorRed._600.color)
    }
    
    func testBalanceFailedReceivedColor() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .failed,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_000_000),
            isSentTransaction: false,
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false
        )
        
        XCTAssertEqual(transaction.balanceColor, Design.Utility.ErrorRed._600.color)
    }
    
    func testBalanceSendingColor() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .sending,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_000_000),
            isSentTransaction: false,
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false
        )
        
        XCTAssertEqual(transaction.balanceColor, Design.Utility.ErrorRed._600.color)
    }
    
    func testBalanceReceivingColor() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .receiving,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_000_000),
            isSentTransaction: false,
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false
        )
        
        XCTAssertEqual(transaction.balanceColor, Asset.Colors.primary.color)
    }
    
    // MARK: - Read/Unread
    
    func testNotUnreadForNoMemos() throws {
        let transaction = TransactionState(
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .received,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_793_456),
            isSentTransaction: false,
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false,
            isMarkedAsRead: true
        )
        
        XCTAssertFalse(transaction.isUnread)
    }
    
    func testNotUnreadForNoTextMemos() throws {
        let transaction = TransactionState(
            memos: [Memo.empty],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .received,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_793_456),
            isSentTransaction: false,
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false,
            isMarkedAsRead: true
        )
        
        XCTAssertFalse(transaction.isUnread)
    }
    
    func testUnreadForNotBeingMarkedAsRead() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .received,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_793_456),
            isSentTransaction: false,
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false,
            isMarkedAsRead: false
        )
        
        XCTAssertTrue(transaction.isUnread)
    }
    
    func testRead() throws {
        let transaction = TransactionState(
            memos: [try! Memo(string: "Hi, pay me and I'll pay you")],
            minedHeight: BlockHeight(1),
            zAddress: "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE",
            fee: Zatoshi(10_000),
            id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
            status: .received,
            timestamp: 1699290621,
            zecAmount: Zatoshi(25_793_456),
            isSentTransaction: false,
            isAddressExpanded: false,
            isExpanded: false,
            isIdExpanded: false,
            isMarkedAsRead: true
        )
        
        XCTAssertFalse(transaction.isUnread)
    }
}
