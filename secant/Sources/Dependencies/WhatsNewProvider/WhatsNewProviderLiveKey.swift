//
//  WhatsNewProviderLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 05-14-2024.
//

import Foundation
import ComposableArchitecture
import SwiftUI

extension WhatsNewProviderClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        Self(
            latest: {
                WhatsNewProviderClient.releases().releases.first ?? .zero
            },
            all: {
                WhatsNewProviderClient.releases()
            }
        )
    }

    private static func checkCountryCodeEligibility(_ code: String) -> Bool {
        switch code {
        case "es": return true
        default: return false
        }
    }
    
    private static func releases() -> WhatNewReleases {
        // default what's new file with EN localization
        var fileName = "whatsNew"

        // localization
        var potentialCountryCode: String?
        
        if #available(iOS 16, *) {
            potentialCountryCode = Locale.current.language.languageCode?.identifier
        } else {
            potentialCountryCode = Locale.current.languageCode
        }
        
        // check the file if this localization exists
        if let potentialCountryCode, WhatsNewProviderClient.checkCountryCodeEligibility(potentialCountryCode) {
            let localizedWhatsNewFileName = "\(fileName)_\(potentialCountryCode)"
            if let whatsNewFile = Bundle.main.url(forResource: localizedWhatsNewFileName, withExtension: ".json"), FileManager.default.fileExists(atPath: whatsNewFile.path) {
                fileName = localizedWhatsNewFileName
            }
        }

        guard
            let whatsNewFile = Bundle.main.url(forResource: fileName, withExtension: ".json")
        else {
            return .zero
        }

        do {
            let data = try Data(contentsOf: whatsNewFile)
            let json = try JSONDecoder().decode(WhatNewReleases.self, from: data)
            
            return json
        } catch {
            return .zero
        }

    }
}
