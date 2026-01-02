import SwiftUI

extension View {
    public func navigationLink<Destination: View>(
        isActive: Binding<Bool>,
        destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink<Self, Destination>(
            isActive: isActive,
            destination: destination,
            label: { self }
        )
    }

//    public func navigationLinkEmpty<Destination: View>(
//        isActive: Binding<Bool>,
//        destination: @escaping () -> Destination
//    ) -> some View {
//        return self.overlay(
//            NavigationLink<EmptyView, Destination>(
//                isActive: isActive,
//                destination: destination,
//                label: { EmptyView() }
//            )
//        )
//    }
}
