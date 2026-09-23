import ComposableArchitecture

extension DependencyValues {
    var viewingKeyQRCode: ViewingKeyQRCodeClient {
        get { self[ViewingKeyQRCodeClient.self] }
        set { self[ViewingKeyQRCodeClient.self] = newValue }
    }
}

enum ViewingKeyQRCodeError: Error, Equatable {
    case generationFailed
}

@DependencyClient
struct ViewingKeyQRCodeClient {
    var png: @Sendable (ViewingKeyMaterial) async throws -> ViewingKeyPNG
}
