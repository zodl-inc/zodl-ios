//
//  SecItemClientTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 12.04.2022.
//

import XCTest
@testable import secant_testnet

extension WalletStorage.KeychainError {
    var debugValue: String {
        switch self {
        case .decoding: return "decoding"
        case .duplicate: return "duplicate"
        case .encoding: return "encoding"
        case .noDataFound: return "noDataFound"
        case .unknown: return "unknown"
        }
    }
}

class SecItemClientTests: XCTestCase {
    func test_secItemAdd_KeychainErrorDuplicate() throws {
        let secItemDuplicate = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecDuplicateItem },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecSuccess }
        )
        
        let walletStorage = WalletStorage(secItem: secItemDuplicate)
        
        do {
            try walletStorage.setData(Data(), forKey: "")

            XCTFail("SecItemClient: test_secItemAdd_KeychainErrorDuplicate expected to fail but passed.")
        } catch {
            guard let error = error as? WalletStorage.KeychainError else {
                XCTFail("SecItemClient: the error is expected to be WalletStorage.KeychainError but it's \(error).")
                
                return
            }
            
            XCTAssertEqual(
                error.debugValue,
                WalletStorage.KeychainError.duplicate.debugValue,
                "SecItemClient: error must be .duplicate but it's \(error)."
            )
        }
    }
    
    func test_secItemAdd_KeychainErrorUnknown() throws {
        let secItemDuplicate = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecCoreFoundationUnknown },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecSuccess }
        )
        
        let walletStorage = WalletStorage(secItem: secItemDuplicate)
        
        do {
            try walletStorage.setData(Data(), forKey: "")

            XCTFail("SecItemClient: test_secItemAdd_KeychainErrorUnknown expected to fail but passed.")
        } catch {
            guard let error = error as? WalletStorage.KeychainError else {
                XCTFail("SecItemClient: the error is expected to be WalletStorage.KeychainError but it's \(error).")
                
                return
            }
            
            XCTAssertEqual(
                error.debugValue,
                WalletStorage.KeychainError.unknown(0).debugValue,
                "SecItemClient: error must be .unknown but it's \(error)."
            )
        }
    }
    
    func test_secItemUpdate_KeychainErrorNoDataFound() throws {
        let secItemDuplicate = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecItemNotFound },
            delete: { _ in errSecSuccess }
        )
        
        let walletStorage = WalletStorage(secItem: secItemDuplicate)
        
        do {
            try walletStorage.updateData(Data(), forKey: "")

            XCTFail("SecItemClient: test_secItemUpdate_KeychainErrorNoDataFound expected to fail but passed.")
        } catch {
            guard let error = error as? WalletStorage.KeychainError else {
                XCTFail("SecItemClient: the error is expected to be WalletStorage.KeychainError but it's \(error).")
                
                return
            }
            
            XCTAssertEqual(
                error.debugValue,
                WalletStorage.KeychainError.noDataFound.debugValue,
                "SecItemClient: error must be .noDataFound but it's \(error)."
            )
        }
    }
    
    func test_secItemUpdate_KeychainErrorUnknown() throws {
        let secItemDuplicate = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecCoreFoundationUnknown },
            delete: { _ in errSecSuccess }
        )
        
        let walletStorage = WalletStorage(secItem: secItemDuplicate)
        
        do {
            try walletStorage.updateData(Data(), forKey: "")

            XCTFail("SecItemClient: test_secItemUpdate_KeychainErrorUnknown expected to fail but passed.")
        } catch {
            guard let error = error as? WalletStorage.KeychainError else {
                XCTFail("SecItemClient: the error is expected to be WalletStorage.KeychainError but it's \(error).")
                
                return
            }
            
            XCTAssertEqual(
                error.debugValue,
                WalletStorage.KeychainError.unknown(0).debugValue,
                "SecItemClient: error must be .unknown but it's \(error)."
            )
        }
    }
    
    func test_secItemDelete_Succeeded() throws {
        let secItemDuplicate = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecSuccess },
            delete: { _ in noErr }
        )
        
        let walletStorage = WalletStorage(secItem: secItemDuplicate)
        
        let result = walletStorage.deleteData(forKey: "")
        
        XCTAssertTrue(result)
    }
    
    func test_secItemDelete_Failed() throws {
        let secItemDuplicate = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecCoreFoundationUnknown }
        )
        
        let walletStorage = WalletStorage(secItem: secItemDuplicate)
        
        let result = walletStorage.deleteData(forKey: "")
        
        XCTAssertFalse(result)
    }
}
