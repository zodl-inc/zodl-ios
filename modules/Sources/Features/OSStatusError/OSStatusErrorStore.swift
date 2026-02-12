//
//  OSStatusErrorStore.swift
//
//
//  Created by Lukáš Korba on 2024-11-20.
//

import Foundation
import ComposableArchitecture
import MessageUI

import SupportDataGenerator

@Reducer
public struct OSStatusError {
    @ObservableState
    public struct State: Equatable {
        public var isExportingData: Bool
        public var message: String
        public var osStatus: OSStatus
        public var supportData: SupportData?

        public init(
            isExportingData: Bool = false,
            message: String,
            osStatus: OSStatus,
            supportData: SupportData? = nil
        ) {
            self.isExportingData = isExportingData
            self.message = message
            self.osStatus = osStatus
            self.supportData = supportData
        }
    }
    
    public enum Action: Equatable {
        case onAppear
        case sendSupportMail
        case sendSupportMailFinished
        case shareFinished
    }

    public init() {}
    
    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                 state.isExportingData = false
                return .none
                
            case .sendSupportMail:
                let supportData = SupportDataGenerator.generateOSStatusError(osStatus: state.osStatus)
                if MFMailComposeViewController.canSendMail() {
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
            }
        }
    }
}
