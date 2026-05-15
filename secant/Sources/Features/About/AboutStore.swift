import SwiftUI
import ComposableArchitecture

@Reducer
struct About {
    @ObservableState
    struct State: Equatable {
        var appVersion = ""
        var appBuild = ""
        var isInAppBrowserPolicyOn = false
        var isInAppBrowserTermsOn = false

        init(
            appVersion: String = "",
            appBuild: String = ""
        ) {
            self.appVersion = appVersion
            self.appBuild = appBuild
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<About.State>)
        case onAppear
        case privacyPolicyButtonTapped
        case termsOfUseButtonTapped
    }

    @Dependency(\.appVersion) var appVersion

    init() { }

    var body: some Reducer<State, Action> {
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
