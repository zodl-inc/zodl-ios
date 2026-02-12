//
//  SendFeedbackStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 10-11-2024.
//

import ComposableArchitecture
import UIComponents
import MessageUI
import SupportDataGenerator
import Generated

@Reducer
public struct SendFeedback {
    @ObservableState
    public struct State: Equatable {
        public var canSendMail = false
        public var memoState: MessageEditor.State = .initial
        public var messageToBeShared: String?
        public let ratings = ["😠", "😒", "🙂", "😄", "😍"]
        public var selectedRating: Int?
        public var supportData: SupportData?

        public var invalidForm: Bool {
            selectedRating == nil || memoState.text.isEmpty
        }
        
        public init(
        ) {
        }
    }
    
    public enum Action: BindableAction, Equatable {
        case binding(BindingAction<SendFeedback.State>)
        case memo(MessageEditor.Action)
        case onAppear
        case ratingTapped(Int)
        case sendTapped
        case sendSupportMailFinished
        case shareFinished
    }

    public init() { }

    public var body: some Reducer<State, Action> {
        BindingReducer()
        
        Scope(state: \.memoState, action: \.memo) {
            MessageEditor()
        }

        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.memoState.text = ""
                state.selectedRating = nil
                state.canSendMail = MFMailComposeViewController.canSendMail()
                return .none

            case .sendTapped:
                guard let selectedRating = state.selectedRating else {
                    return .none
                }
                
                var prefixMessage = "\(L10n.SendFeedback.ratingQuestion)\n\(state.ratings[selectedRating]) \(selectedRating + 1)/\(state.ratings.count)\n\n"
                prefixMessage += "\(L10n.SendFeedback.howCanWeHelp)\n\(state.memoState.text)\n\n"
                
                if state.canSendMail {
                    state.supportData = SupportDataGenerator.generate(prefixMessage)
                    return .none
                } else {
                    let sharePrefix =
                    """
                    ===
                    \(L10n.SendFeedback.Share.notAppleMailInfo) \(SupportDataGenerator.Constants.email)
                    ===
                    
                    \(prefixMessage)
                    """
                    let supportData = SupportDataGenerator.generate(sharePrefix)
                    state.messageToBeShared = supportData.message
                }
                return .none

            case .sendSupportMailFinished:
                state.supportData = nil
                return .none

            case .binding:
                return .none

            case .memo:
                return .none
                
            case .ratingTapped(let rating):
                state.selectedRating = rating
                return .none
                
            case .shareFinished:
                state.messageToBeShared = nil
                return .none
            }
        }
    }
}
