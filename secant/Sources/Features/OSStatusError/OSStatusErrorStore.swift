//
//  OSStatusErrorStore.swift
//
//
//  Created by Lukáš Korba on 2024-11-20.
//

import Foundation
import Combine
import ComposableArchitecture
#if canImport(MessageUI)
import MessageUI
#endif

@Reducer
struct OSStatusError {
    @ObservableState
    struct State: Equatable {
        var isExportingData: Bool
        var message: String
        var osStatus: OSStatus
        var supportData: SupportData?
        /// macOS only: this Mac has no Secure Enclave, so the seed can't be stored securely and there is
        /// no plaintext fallback. Shows a dedicated "unsupported Mac" message instead of a keychain code.
        var secureEnclaveUnavailable: Bool

        init(
            isExportingData: Bool = false,
            message: String,
            osStatus: OSStatus,
            supportData: SupportData? = nil,
            secureEnclaveUnavailable: Bool = false
        ) {
            self.isExportingData = isExportingData
            self.message = message
            self.osStatus = osStatus
            self.supportData = supportData
            self.secureEnclaveUnavailable = secureEnclaveUnavailable
        }
    }
    
    enum Action: Equatable {
        case onAppear
        case sendSupportMail
        case sendSupportMailFinished
        case shareFinished
        /// macOS: the failed-relocation recovery affordance (MOB-1485). Root intercepts
        /// `.osStatusError(.startOverTapped)`, presents the `wipeRequest` confirmation, and runs
        /// the standard reset flow.
        case startOverTapped
    }

    init() {}
    
    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                 state.isExportingData = false
                return .none
                
            case .sendSupportMail:
                let supportData = SupportDataGenerator.generateOSStatusError(osStatus: state.osStatus)
                // TCA Store is @MainActor; reducer body always runs on main.
                if MailSupport.canSendMail() {
                    state.supportData = supportData
                } else {
                    state.message = supportData.message
                    state.isExportingData = true
                }
                return .none
                
            case .sendSupportMailFinished:
                state.supportData = nil
                return .none
                
            case .shareFinished:
                state.isExportingData = false
                return .none

            case .startOverTapped:
                // Root intercepts this (RootInitialization) — nothing to do locally.
                return .none
            }
        }
    }
}
