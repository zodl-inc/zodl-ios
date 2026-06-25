//
//  AppSection.swift
//  Zashi
//
//  The shared sidebar sections for the split layouts — MacSplitView (macOS) and IPadSplitView (iPad
//  regular). Pure data: title + icon + the Root action each section selects (the same actions the iPhone
//  Home buttons send, so the whole store graph is reused). Single source consolidated from the former
//  MacSection / PadSection duplicates (Phase iP-7); each file keeps its local name via a typealias.
//

import SwiftUI
import ComposableArchitecture

enum AppSection: CaseIterable {
    case activity, receive, send, pay, swap, vote, more

    var title: String {
        switch self {
        case .activity: return String(localizable: .generalActivity)
        case .receive: return String(localizable: .tabsReceive)
        case .send: return String(localizable: .tabsSend)
        case .pay: return String(localizable: .swapAndPayPay)
        case .swap: return String(localizable: .swapAndPaySwap)
        case .vote: return String(localizable: .coinVoteSidebarTitle)
        case .more: return String(localizable: .settingsTitle)
        }
    }

    var sectionIcon: Image {
        switch self {
        case .activity: return Asset.Assets.Icons.activity.image
        case .receive: return Asset.Assets.Icons.received.image
        case .send: return Asset.Assets.Icons.sent.image
        case .pay: return Asset.Assets.Icons.pay.image
        case .swap: return Asset.Assets.Icons.swap.image
        case .vote: return Asset.Assets.Icons.checkVerified.image
        case .more: return Asset.Assets.Icons.dotsMenu.image
        }
    }

    var action: Root.Action {
        switch self {
        case .activity: return .home(.seeAllTransactionsTapped)
        case .receive: return .home(.receiveTapped)
        case .send: return .home(.sendTapped)
        case .pay: return .home(.payWithNearTapped)
        case .swap: return .home(.swapWithNearTapped)
        case .vote: return .macVoteSectionSelected
        case .more: return .home(.settingsTapped)
        }
    }
}
