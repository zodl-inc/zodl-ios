//
//  WalletBirthdayTitleLogo.swift
//  Zashi
//
//  MOB-2020: the vendor title logo drawn above an `isKeystoneFlow` (hardware-wallet) screen's
//  title -- Ledger's own mark for a Ledger flow, Keystone's for every other vendor (Keystone's
//  own flows included). WalletBirthdayEstimateDateView, WalletBirthdayEstimatedHeightView and
//  WalletBirthdayView all draw it through this one shared view instead of three separate copies.
//

import SwiftUI

/// `vendor`'s title logo. Callers still gate this behind `isKeystoneFlow` themselves -- a
/// non-hardware-wallet screen shows no logo at all.
struct WalletBirthdayTitleLogo: View {
    let vendor: WalletAccount.Vendor

    var body: some View {
        if vendor == .ledger {
            Asset.Assets.Partners.ledgerTitleLogo.image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 32)
                .padding(.top, 16)
        } else {
            Asset.Assets.Partners.keystoneTitleLogo.image
                .resizable()
                .frame(width: 193, height: 32)
                .padding(.top, 16)
        }
    }
}
