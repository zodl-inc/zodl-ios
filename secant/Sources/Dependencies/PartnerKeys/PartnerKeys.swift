//
//  PartnerKeys.swift
//  Zashi
//
//  Created by Lukáš Korba on 05-17-2024.
//

import Foundation

struct PartnerKeys {
    // NOTE: this key list is mirrored by Scripts/validate-partner-keys.sh, which
    // fails an *archive* build when a required key is missing. Keep both in sync.
    private enum Constants {
        static let cbProjectId = "cbProjectId"
        static let flexaPublishableKey = "flexaPublishableKey"
        static let flexaPublishableTestKey = "flexaPublishableTestKey"
        static let nearKey = "nearKey"
        static let cmcKey = "cmcKey"
        static let nearFeeDepositAddress = "nearFeeDepositAddress"
#if !SECANT_DISTRIB
        static let testSeed = "testSeed"
#endif
    }
    
    static var cbProjectId: String? {
        PartnerKeys.value(for: Constants.cbProjectId)
    }
    
    static var flexaPublishableKey: String? {
        PartnerKeys.value(for: Constants.flexaPublishableKey)
    }
    
    static var flexaPublishableTestKey: String? {
        PartnerKeys.value(for: Constants.flexaPublishableTestKey)
    }
    
    static var nearKey: String? {
        PartnerKeys.value(for: Constants.nearKey)
    }
    
    static var cmcKey: String? {
        PartnerKeys.value(for: Constants.cmcKey)
    }
    
    static var nearFeeDepositAddress: String? {
        PartnerKeys.value(for: Constants.nearFeeDepositAddress)
    }
    
#if !SECANT_DISTRIB
    static var testSeed: String? {
        PartnerKeys.value(for: Constants.testSeed)
    }
#endif
}

private extension PartnerKeys {
    static func value(for key: String) -> String? {
        let fileName = "PartnerKeys.plist"

        guard
            let configFile = Bundle.main.url(forResource: fileName, withExtension: nil),
            let properties = NSDictionary(contentsOf: configFile),
            let key = properties[key] as? String
        else {
            return nil
        }

        return key
    }
}
