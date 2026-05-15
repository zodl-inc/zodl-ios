//
//  SendFeedbackStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 10-11-2024.
//

import ComposableArchitecture
import MessageUI

@Reducer
struct SendFeedback {
    @ObservableState
    struct State: Equatable {
        var canSendMail = false
        var memoState: MessageEditor.State = .initial
        var messageToBeShared: String?
        let ratings = ["😠", "😒", "🙂", "😄", "😍"]
        var selectedRating: Int?
        var supportData: SupportData?

        var invalidForm: Bool {
            selectedRating == nil || memoState.text.isEmpty
        }
        
        init(
        ) {
        }
    }
    
    enum Action: BindableAction, Equatable {
        case binding(BindingAction<SendFeedback.State>)
        case memo(MessageEditor.Action)
        case onAppear
        case ratingTapped(Int)
        case sendTapped
        case sendSupportMailFinished
        case shareFinished
    }

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()
        
        Scope(state: \.memoState, action: \.memo) {
            MessageEditor()
        }

        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.memoState.text = ""
                state.selectedRating = 4
                state.canSendMail = MFMailComposeViewController.canSendMail()
                return .none

            case .sendTapped:
                guard let selectedRating = state.selectedRating else {
                    return .none
                }
                
                var prefixMessage = "\(String(localizable: .sendFeedbackRatingQuestion))\n\(state.ratings[selectedRating]) \(selectedRating + 1)/\(state.ratings.count)\n\n"
                prefixMessage += "\(String(localizable: .sendFeedbackHowCanWeHelp))\n\(state.memoState.text)\n\n"
                
                if state.canSendMail {
                    state.supportData = SupportDataGenerator.generate(prefixMessage)
                    return .none
                } else {
                    let sharePrefix =
                    """
                    ===
                    \(String(localizable: .sendFeedbackShareNotAppleMailInfo)) \(SupportDataGenerator.Constants.email)
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
