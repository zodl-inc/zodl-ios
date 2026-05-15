//
//  DerivationToolLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 12.11.2022.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension DerivationToolClient: DependencyKey {
    static let liveValue = DerivationToolClient.live()
        
    static func live() -> Self {
        Self(
            deriveSpendingKey: { seed, accountIndex, networkType in
                try DerivationTool(networkType: networkType).deriveUnifiedSpendingKey(seed: seed, accountIndex: accountIndex)
            },
            deriveUnifiedFullViewingKey: { spendingKey, networkType in
                try DerivationTool(networkType: networkType).deriveUnifiedFullViewingKey(from: spendingKey)
            },
            doesAddressSupportMemo: { address, networkType in
                do {
                    if case .transparent = try Recipient(address, network: networkType) {
                        return false
                    } else if case .tex = try Recipient(address, network: networkType) {
                        return false
                    }
                    else {
                        return true
                    }
                } catch {
                    return false
                }
            },
            isUnifiedAddress: { address, networkType in
                do {
                    if case .unified = try Recipient(address, network: networkType) {
                        return true
                    } else {
                        return false
                    }
                } catch {
                    return false
                }
            },
            isSaplingAddress: { address, networkType in
                do {
                    if case .sapling = try Recipient(address, network: networkType) {
                        return true
                    } else {
                        return false
                    }
                } catch {
                    return false
                }
            },
            isTransparentAddress: { address, networkType in
                do {
                    if case .transparent = try Recipient(address, network: networkType) {
                        return true
                    } else {
                        return false
                    }
                } catch {
                    return false
                }
            },
            isTexAddress: { address, networkType in
                do {
                    if case .tex = try Recipient(address, network: networkType) {
                        return true
                    } else {
                        return false
                    }
                } catch {
                    return false
                }
            },
            isZcashAddress: { address, networkType in
                do {
                    _ = try Recipient(address, network: networkType)
                    return true
                } catch {
                    return false
                }
            },
            deriveUnifiedAddressFrom: { ufvk, networkType in
                try DerivationTool(networkType: networkType).deriveUnifiedAddressFrom(ufvk: ufvk)
            },
            deriveArbitraryWalletKey: { contextString, seed in
                try DerivationTool.deriveArbitraryWalletKey(
                    contextString: contextString,
                    seed: seed
                )
            },
            deriveArbitraryAccountKey: { contextString, seed, accountIndex, networkType in
                try DerivationTool(networkType: networkType).deriveArbitraryAccountKey(
                    contextString: contextString,
                    seed: seed,
                    accountIndex: accountIndex
                )
            }
        )
    }
}
