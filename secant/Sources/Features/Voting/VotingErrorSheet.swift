import SwiftUI

// Shared bottom-sheet content for the voting flow: icon + title + body and one
// or two stacked action buttons. Presentation is handled by `zashiSheet`.
// The top button is the lighter/cancel-style action; the bottom button is the
// primary affirmative action — this matches the visual hierarchy used in the
// Figma designs and the existing Unanswered Questions sheet.
struct VotingSheetContent: View {
    @Environment(\.colorScheme) var colorScheme

    enum ButtonStyle {
        case primary
        case secondary
    }

    enum VisualStyle {
        case standard
        case unverifiedWarning

        var horizontalPadding: CGFloat {
            switch self {
            case .standard:
                return Design.Spacing._3xl
            case .unverifiedWarning:
                return 0
            }
        }
    }

    struct ButtonConfig {
        let title: String
        let style: ButtonStyle
        let action: () -> Void
    }

    let iconSystemName: String
    let iconStyle: Colorable
    let title: String
    let message: String
    let primary: ButtonConfig
    let secondary: ButtonConfig?
    let visualStyle: VisualStyle

    init(
        iconSystemName: String,
        iconStyle: Colorable,
        title: String,
        message: String,
        primary: ButtonConfig,
        secondary: ButtonConfig?,
        visualStyle: VisualStyle = .standard
    ) {
        self.iconSystemName = iconSystemName
        self.iconStyle = iconStyle
        self.title = title
        self.message = message
        self.primary = primary
        self.secondary = secondary
        self.visualStyle = visualStyle
    }

    var body: some View {
        VStack(spacing: 0) {
            iconView
                .padding(.top, iconTopPadding)
                .padding(.bottom, iconBottomPadding)

            Text(title)
                .zFont(.semiBold, size: titleFontSize, style: Design.Text.primary)
                .tracking(titleTracking)
                .multilineTextAlignment(.center)
                .padding(.bottom, titleBottomPadding)

            Text(message)
                .zFont(size: 14, style: messageTextStyle)
                .tracking(messageTracking)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: messageMaxWidth)
                .padding(.horizontal, messageHorizontalPadding)
                .padding(.bottom, messageBottomPadding)

            VStack(spacing: 12) {
                if let secondary {
                    button(secondary)
                }
                button(primary)
            }
            .padding(.bottom, buttonBottomPadding)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, contentHorizontalPadding)
        .background(sheetBackgroundColor)
    }

    @ViewBuilder
    private var iconView: some View {
        switch visualStyle {
        case .standard:
            ZStack {
                Circle()
                    .fill(iconStyle.color(colorScheme).opacity(0.1))
                    .frame(width: 48, height: 48)
                Image(systemName: iconSystemName)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(iconStyle.color(colorScheme).opacity(0.8))
            }
        case .unverifiedWarning:
            ZStack {
                Circle()
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    .frame(width: 44, height: 44)
                Asset.Assets.Icons.alertOutline.image
                    .zImage(size: 20, style: Design.Utility.ErrorRed._500)
            }
        }
    }

    private var iconTopPadding: CGFloat {
        switch visualStyle {
        case .standard:
            return 16
        case .unverifiedWarning:
            return 24
        }
    }

    private var iconBottomPadding: CGFloat {
        switch visualStyle {
        case .standard:
            return 16
        case .unverifiedWarning:
            return 12
        }
    }

    private var titleFontSize: CGFloat {
        switch visualStyle {
        case .standard:
            return 22
        case .unverifiedWarning:
            return 20
        }
    }

    private var titleTracking: CGFloat {
        switch visualStyle {
        case .standard:
            return 0
        case .unverifiedWarning:
            return -0.32
        }
    }

    private var titleBottomPadding: CGFloat {
        switch visualStyle {
        case .standard:
            return 8
        case .unverifiedWarning:
            return 4
        }
    }

    private var messageTextStyle: Design.Text {
        switch visualStyle {
        case .standard:
            return .secondary
        case .unverifiedWarning:
            return .tertiary
        }
    }

    private var messageTracking: CGFloat {
        switch visualStyle {
        case .standard:
            return 0
        case .unverifiedWarning:
            return -0.224
        }
    }

    private var messageHorizontalPadding: CGFloat {
        switch visualStyle {
        case .standard:
            return 24
        case .unverifiedWarning:
            return 0
        }
    }

    private var messageMaxWidth: CGFloat? {
        switch visualStyle {
        case .standard:
            return nil
        case .unverifiedWarning:
            return 264
        }
    }

    private var messageBottomPadding: CGFloat {
        switch visualStyle {
        case .standard:
            return 24
        case .unverifiedWarning:
            return 32
        }
    }

    private var buttonBottomPadding: CGFloat {
        switch visualStyle {
        case .standard:
            return Design.Spacing.sheetBottomSpace
        case .unverifiedWarning:
            return 32
        }
    }

    private var contentHorizontalPadding: CGFloat {
        switch visualStyle {
        case .standard:
            return 0
        case .unverifiedWarning:
            return 24
        }
    }

    private var sheetBackgroundColor: Color {
        switch visualStyle {
        case .standard:
            return .clear
        case .unverifiedWarning:
            return Design.Surfaces.bgPrimary.color(colorScheme).opacity(0.96)
        }
    }

    @ViewBuilder
    private func button(_ config: ButtonConfig) -> some View {
        switch config.style {
        case .primary:
            ZashiButton(config.title, action: config.action)
        case .secondary:
            ZashiButton(config.title, type: .secondary, action: config.action)
        }
    }
}

extension View {
    /// Present a voting-flow bottom sheet (error or confirmation) with an
    /// icon, title, body, and one or two stacked buttons.
    func votingSheet(
        isPresented: Binding<Bool>,
        iconSystemName: String = "exclamationmark.circle",
        iconStyle: Colorable = Design.Utility.ErrorRed._500,
        title: String,
        message: String,
        primary: VotingSheetContent.ButtonConfig,
        secondary: VotingSheetContent.ButtonConfig? = nil,
        visualStyle: VotingSheetContent.VisualStyle = .standard,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        zashiSheet(
            isPresented: isPresented,
            horizontalPadding: visualStyle.horizontalPadding,
            onDismiss: onDismiss
        ) {
            VotingSheetContent(
                iconSystemName: iconSystemName,
                iconStyle: iconStyle,
                title: title,
                message: message,
                primary: primary,
                secondary: secondary,
                visualStyle: visualStyle
            )
        }
    }
}

private struct VotingBlockingSheetModifier<SheetContent: View>: ViewModifier {
    let isActive: () -> Bool
    let visualStyle: VotingSheetContent.VisualStyle
    let onExit: () -> Void
    let sheetContent: (_ dismissAndExit: @escaping () -> Void) -> SheetContent

    @State private var sheetPresented = true
    @State private var exitAfterSheetDismiss = false

    func body(content: Content) -> some View {
        content
            .zashiSheet(
                isPresented: sheetBinding,
                horizontalPadding: visualStyle.horizontalPadding,
                onDismiss: exitIfNeeded
            ) {
                sheetContent(dismissSheetAndExit)
            }
    }

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { sheetPresented && isActive() },
            set: { newValue in
                if !newValue && isActive() {
                    exitAfterSheetDismiss = true
                }
                sheetPresented = newValue
            }
        )
    }

    private func dismissSheetAndExit() {
        exitAfterSheetDismiss = true
        sheetPresented = false
    }

    private func exitIfNeeded() {
        guard exitAfterSheetDismiss else { return }
        exitAfterSheetDismiss = false
        onExit()
    }
}

extension View {
    /// Presents a blocking voting sheet and exits the voting flow only after
    /// the sheet dismiss animation finishes.
    func votingBlockingSheet<SheetContent: View>(
        isActive: @escaping () -> Bool,
        visualStyle: VotingSheetContent.VisualStyle = .standard,
        onExit: @escaping () -> Void,
        @ViewBuilder content: @escaping (_ dismissAndExit: @escaping () -> Void) -> SheetContent
    ) -> some View {
        modifier(
            VotingBlockingSheetModifier(
                isActive: isActive,
                visualStyle: visualStyle,
                onExit: onExit,
                sheetContent: content
            )
        )
    }
}
