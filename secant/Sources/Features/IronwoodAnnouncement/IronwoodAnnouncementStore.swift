//
//  IronwoodAnnouncementStore.swift
//  Zashi
//
//  Created by Michal Fousek on 25.07.2026.
//

import ComposableArchitecture

@Reducer
struct IronwoodAnnouncement {
    @ObservableState
    struct State: Equatable {
        var isInAppBrowserOn = false
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<IronwoodAnnouncement.State>)
        case guideTapped
        case continueTapped
    }

    @Dependency(\.walletStorage) var walletStorage

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .guideTapped:
                // The ONE route to the support article since the duplicate `learnMoreTapped`
                // button was removed (2026-08-08) — the two arms were identical. Opening the
                // guide is deliberately NOT acknowledgement of the announcement: only
                // `continueTapped` writes the keychain flag below, so this case must never
                // touch `walletStorage`.
                state.isInAppBrowserOn = true
                return .none

            case .continueTapped:
                // Deliberately returns `.none` without navigating anywhere: the Root reducer
                // observes this same `.continueTapped` action and performs the transition to
                // Home itself. Do not "fix" this by adding navigation here.
                // `try?` is deliberate too: a keychain write failure must not trap the user on
                // this one-time announcement screen, so the failure is swallowed rather than
                // surfaced or retried.
                try? walletStorage.importIronwoodAnnouncementFlag(true)
                return .none
            }
        }
    }
}
