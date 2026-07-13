//
//  WalletInitMode.swift
//  Zodl
//
//  [#1755] The SDK now DERIVES the wallet init flow (new / restore / existing) from whether an account
//  already exists plus the birthday, so `Synchronizer.prepare` no longer takes a mode. Zodl keeps this
//  small local enum only to track WHICH onboarding flow the user is in — so it can pass a `nil` birthday
//  for a brand-new wallet (the SDK then picks a reorg-safe recent height) versus the stored / restore
//  birthday otherwise. It is no longer handed to the SDK.
//

import Foundation

enum WalletInitMode: Equatable {
    case newWallet
    case restoreWallet
    case existingWallet
}
