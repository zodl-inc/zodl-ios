import SwiftUI
import ComposableArchitecture

import AppVersion
import Generated

@Reducer
public struct About {
    @ObservableState
    public struct State: Equatable {
        public var appVersion = ""
        public var appBuild = ""
        public var isInAppBrowserPolicyOn = false
        public var isInAppBrowserTermsOn = false

        public init(
            appVersion: String = "",
            appBuild: String = ""
        ) {
            self.appVersion = appVersion
            self.appBuild = appBuild
        }
    }

    public enum Action: BindableAction, Equatable {
        case binding(BindingAction<About.State>)
        case onAppear
        case privacyPolicyButtonTapped
        case termsOfUseButtonTapped
    }

    @Dependency(\.appVersion) var appVersion

    public init() { }

    public var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.appVersion = appVersion.appVersion()
                state.appBuild = appVersion.appBuild()
                return .none

            case .binding:
                return .none

            case .privacyPolicyButtonTapped:
                state.isInAppBrowserPolicyOn = true
                return .none

            case .termsOfUseButtonTapped:
                state.isInAppBrowserTermsOn = true
                return .none
            }
        }
    }
}
