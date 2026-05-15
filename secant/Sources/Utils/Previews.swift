import SwiftUI

// TODO: [#695] This should have a #DEBUG tag, but if so, it's not possible to compile this on release mode and submit it to testflight https://github.com/zcash/ZcashLightClientKit/issues/695
struct StateContainer<T, Content: View>: View {
    @State private var state: T
    private var content: (Binding<T>) -> Content

    init(initialState: T, content: @escaping (Binding<T>) -> Content) {
        self._state = State(initialValue: initialState)
        self.content = content
    }

    var body: some View {
        content($state)
    }
}
