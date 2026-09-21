//
//  ViewingKeyPresentationTests.swift
//  zodlTests
//

import ComposableArchitecture
import CoreImage
import Foundation
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized)
@MainActor
struct ViewingKeyPresentationTests {
    private enum RenderState: String, CaseIterable {
        case chooser
        case selectedChooser
        case keystoneChooser
        case consent
        case checkedConsent
        case hiddenDetail
        case hiddenStringDetail
        case revealedQRDetail
        case revealedStringDetail
        case qrFailure
        case unavailableKey
    }

    private struct RenderConfiguration {
        let name: String
        let width: CGFloat
        let height: CGFloat
        let colorScheme: ColorScheme
        let dynamicTypeSize: DynamicTypeSize

        var preferredContentSizeCategory: UIContentSizeCategory {
            dynamicTypeSize == .accessibility5 ? .accessibilityExtraExtraExtraLarge : .large
        }
    }

    @Test
    func hiddenPresentationIsFixedAndContainsNoViewingKeyMaterial() async throws {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        let session = ViewingKeyExportSession(id: UUID(), account: account, network: .mainnet)
        let incoming = try #require(session.key(for: .incoming))
        let full = try #require(session.key(for: .full))

        let incomingPresentation = ViewingKeyPresentation.payload(
            isVisible: false,
            key: incoming,
            png: nil
        )
        let fullPresentation = ViewingKeyPresentation.payload(
            isVisible: false,
            key: full,
            png: ViewingKeyPNG(data: Data(full.rawValue.utf8))
        )

        let expected = ViewingKeyPayloadPresentation.hidden(
            text: "•••• •••• •••• ••••",
            accessibilityLabel: String(localizable: .viewing_key_hidden)
        )
        #expect(incomingPresentation == expected)
        #expect(fullPresentation == expected)
        #expect(!String(describing: incomingPresentation).contains(incoming.rawValue))
        #expect(!String(describing: fullPresentation).contains(full.rawValue))
    }

    @Test
    func revealedPresentationUsesExactCanonicalKeyAndPNG() async throws {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        let session = ViewingKeyExportSession(id: UUID(), account: account, network: .mainnet)
        let key = try #require(session.key(for: .incoming))
        let png = try await ViewingKeyQRCodeClient.liveValue.png(key)

        let presentation = ViewingKeyPresentation.payload(
            isVisible: true,
            key: key,
            png: png
        )

        let revealedPresentationMatches = presentation == .revealed(key: key.rawValue, png: png.data)
        #expect(revealedPresentationMatches)
    }

    @Test
    func presentationUsesSelectedKindAndCapturedVendorTitles() {
        #expect(ViewingKeyPresentation.title(for: .incoming) == String(localizable: .viewing_key_your_incoming))
        #expect(ViewingKeyPresentation.title(for: .full) == String(localizable: .viewing_key_your_full))
        #expect(ViewingKeyPresentation.vendorName(for: .zcash) == String(localizable: .accountsZashi))
        #expect(ViewingKeyPresentation.vendorName(for: .keystone) == String(localizable: .accountsKeystone))
    }

    @Test
    func pngItemSharesExactPNGBytesAndType() async throws {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        let session = ViewingKeyExportSession(id: UUID(), account: account, network: .mainnet)
        let key = try #require(session.key(for: .incoming))
        let bytes = try await ViewingKeyQRCodeClient.liveValue.png(key).data
        let item = ShareablePNG(data: bytes, title: "Public test title")
        let controller = UIActivityViewController(activityItems: [], applicationActivities: nil)

        #expect(item.activityViewController(controller, dataTypeIdentifierForActivityType: nil) == UTType.png.identifier)
        let sharedPNGMatches = (item.activityViewController(controller, itemForActivityType: nil) as? Data) == bytes
        #expect(sharedPNGMatches)
    }

    @Test
    func shareSheetReceivesRawStringAndPNGAsTwoDistinctItems() async throws {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        let session = ViewingKeyExportSession(id: UUID(), account: account, network: .mainnet)
        let key = try #require(session.key(for: .full))
        let png = try await ViewingKeyQRCodeClient.liveValue.png(key)
        let payload = ViewingKeySharePayload(id: UUID(), key: key, png: png)
        let ownership = ViewingKeyShareOwnership(payloadID: payload.id)

        let items = ViewingKeyShareItems(payload: payload, title: "Public test title")
        let rawString = try #require(items.activityItems.first as? String)
        let pngItem = try #require(items.activityItems.last as? ShareablePNG)
        let controller = ViewingKeyActivityView.makeController(
            activityItems: items.activityItems,
            ownership: ownership,
            onCompletion: {}
        )

        #expect(items.activityItems.count == 2)
        let sharedStringMatches = rawString == key.rawValue
        let sharedPNGMatches = (pngItem.activityViewController(controller, itemForActivityType: nil) as? Data) == png.data
        #expect(sharedStringMatches)
        #expect(sharedPNGMatches)
    }

    @Test
    func shareBridgeReportsUIKitOwnershipOnce() {
        var presentationCount = 0
        var completionCount = 0
        let ownership = ViewingKeyShareOwnership(payloadID: UUID())
        let controller = ViewingKeyActivityView.makeController(
            activityItems: ["public fixture"],
            ownership: ownership,
            onPresented: { presentationCount += 1 },
            onCompletion: { completionCount += 1 }
        )

        #expect(controller.didTransferPayload)
        #expect(ownership.hasNativeOwnership)
        #expect(presentationCount == 0)

        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()

        #expect(presentationCount == 1)
        controller.completionWithItemsHandler?(nil, false, nil, nil)
        #expect(completionCount == 1)
        #expect(ownership.isFinished)
    }

    @Test
    func cancelledShareOwnershipTransfersNoPayloadOrPresentationCallback() {
        var presentationCount = 0
        let ownership = ViewingKeyShareOwnership(payloadID: UUID())
        #expect(!ownership.cancelPreparedUnlessNativeOwned())
        let controller = ViewingKeyActivityView.makeController(
            activityItems: ["public fixture"],
            ownership: ownership,
            onPresented: { presentationCount += 1 },
            onCompletion: {}
        )

        #expect(ownership.wasCancelledBeforeHandoff)
        #expect(!controller.didTransferPayload)
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        #expect(presentationCount == 0)
    }

    @Test(arguments: [2, 3])
    func themedQRCardsDecodeExactlyAtDisplayedSize(displayScale: Int) async throws {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        let session = ViewingKeyExportSession(id: UUID(), account: account, network: .mainnet)
        let key = try #require(session.key(for: .full))
        let output = try await ViewingKeyQRCodeClient.liveValue.png(key)
        let image = try #require(UIImage(data: output.data)?.cgImage)
        let lightCard = try renderedQRCodeCard(image, displayScale: displayScale, colorScheme: .light)
        let darkCard = try renderedQRCodeCard(image, displayScale: displayScale, colorScheme: .dark)
        let lightCardDecodesExactly = decodedQRCode(lightCard) == key.rawValue
        let darkCardDecodesExactly = decodedQRCode(darkCard) == key.rawValue

        #expect(lightCardDecodesExactly)
        #expect(darkCardDecodesExactly)
    }

    @Test
    func chooserBackFinishesTheExportFlow() async throws {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        let state = ExportViewingKeys.State(
            session: ViewingKeyExportSession(id: UUID(), account: account, network: .mainnet)
        )
        state.$selectedWalletAccount.withLock { $0 = account }
        state.$walletAccounts.withLock { $0 = [account] }
        let store = TestStore(initialState: state) {
            ExportViewingKeys()
        } withDependencies: {
            $0.zcashSDKEnvironment.network = {
                ZcashNetworkBuilder.network(for: .mainnet)
            }
        }

        await store.send(.backTapped) {
            $0.isInvalidated = true
        }
        await store.receive(.delegate(.finished))
    }

    @Test
    func hostedSettingsViewForwardsLifecycleNotificationsToViewingKeyFlow() async throws {
        let inactiveHost = try await makeHostedSettingsView()
        #expect(!inactiveHost.store.isViewingKeyInactive)
        #expect(inactiveHost.store.path.compactMap { $0.exportViewingKeys }.first?.isInactive == false)

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        await nextMainRunLoopTurn()
        let inactiveState = (
            inactiveHost.store.isViewingKeyInactive,
            inactiveHost.store.path.compactMap { $0.exportViewingKeys }.first?.isPayloadVisible,
            inactiveHost.store.path.compactMap { $0.exportViewingKeys }.count
        )
        #expect(inactiveState.0)
        #expect(inactiveState.1 == false)
        #expect(inactiveState.2 == 1)
        inactiveHost.window.isHidden = true
        await nextMainRunLoopTurn()

        for notification in [UIApplication.protectedDataWillBecomeUnavailableNotification] {
            let host = try await makeHostedSettingsView()
            NotificationCenter.default.post(name: notification, object: nil)
            await nextMainRunLoopTurn()
            let exportWasRemoved = host.store.path.compactMap { $0.exportViewingKeys }.isEmpty
            #expect(exportWasRemoved)
            host.window.isHidden = true
            await nextMainRunLoopTurn()
        }
    }

    @Test
    func viewingKeyLayouts() async throws {
        let configurations = [
            RenderConfiguration(
                name: "light-393",
                width: 393,
                height: 852,
                colorScheme: .light,
                dynamicTypeSize: .large
            ),
            RenderConfiguration(
                name: "dark-393",
                width: 393,
                height: 852,
                colorScheme: .dark,
                dynamicTypeSize: .large
            ),
            RenderConfiguration(
                name: "compact-light",
                width: 320,
                height: 568,
                colorScheme: .light,
                dynamicTypeSize: .large
            ),
            RenderConfiguration(
                name: "accessibility5-light",
                width: 393,
                height: 852,
                colorScheme: .light,
                dynamicTypeSize: .accessibility5
            )
        ]

        for renderState in RenderState.allCases {
            for configuration in configurations {
                let store = try await makeRenderStore(renderState)
                let png = try await render(
                    store: store,
                    configuration: configuration,
                    expectsSheet: renderState == .consent || renderState == .checkedConsent
                )
                Attachment.record(
                    [UInt8](png),
                    named: "viewing-key-\(renderState.rawValue)-\(configuration.name).png"
                )
            }
        }

        let accessibilityConfiguration = try #require(
            configurations.first { $0.name == "accessibility5-light" }
        )
        for renderState in [RenderState.consent, .checkedConsent, .revealedQRDetail, .revealedStringDetail, .qrFailure] {
            let store = try await makeRenderStore(renderState)
            let png = try await render(
                store: store,
                configuration: accessibilityConfiguration,
                expectsSheet: renderState == .consent || renderState == .checkedConsent,
                scrollToBottom: true
            )
            Attachment.record(
                [UInt8](png),
                named: "viewing-key-\(renderState.rawValue)-accessibility5-footer.png"
            )
        }

        let compactConfiguration = try #require(
            configurations.first { $0.name == "compact-light" }
        )
        let unavailableStore = try await makeRenderStore(.unavailableKey)
        let unavailablePNG = try await render(
            store: unavailableStore,
            configuration: compactConfiguration,
            expectsSheet: false,
            scrollToBottom: true
        )
        Attachment.record(
            [UInt8](unavailablePNG),
            named: "viewing-key-unavailableKey-compact-light-footer.png"
        )
    }

    @Test
    func scrolledQRCodeCapturesDecodeAtCompactAndAccessibilitySizes() async throws {
        let configurations = [
            RenderConfiguration(
                name: "compact-light",
                width: 320,
                height: 568,
                colorScheme: .light,
                dynamicTypeSize: .large
            ),
            RenderConfiguration(
                name: "compact-accessibility5-light",
                width: 320,
                height: 568,
                colorScheme: .light,
                dynamicTypeSize: .accessibility5
            )
        ]

        for configuration in configurations {
            let store = try await makeRenderStore(.revealedQRDetail)
            let expectedKey = try #require(store.detail?.key?.rawValue)
            let png = try await render(
                store: store,
                configuration: configuration,
                expectsSheet: false,
                scrollToDecodedQRCode: expectedKey
            )
            let image = try #require(UIImage(data: png)?.cgImage)
            let feature = matchingQRCodeFeature(image, expected: expectedKey)
            let decodedMatches = feature != nil
            let fullQRCodeIsVisible = feature.map { isFullyVisible($0, in: image) } == true
            #expect(decodedMatches)
            #expect(fullQRCodeIsVisible)
            Attachment.record(
                [UInt8](png),
                named: "viewing-key-revealedQRDetail-\(configuration.name)-scrolled-decodable.png"
            )
        }
    }

    private func makeRenderStore(_ renderState: RenderState) async throws -> StoreOf<ExportViewingKeys> {
        let vendor: WalletAccount.Vendor = renderState == .keystoneChooser ? .keystone : .zcash
        let account = renderState == .unavailableKey
            ? try await ViewingKeyExportFixtures.accountWithoutViewingKeys(vendor: vendor)
            : try await ViewingKeyExportFixtures.account(vendor: vendor)
        let session = ViewingKeyExportSession(id: UUID(), account: account, network: .mainnet)
        var state = ExportViewingKeys.State(session: session)
        state.$selectedWalletAccount.withLock { $0 = account }
        state.$walletAccounts.withLock { $0 = [account] }

        switch renderState {
        case .chooser:
            break
        case .selectedChooser, .keystoneChooser:
            state.selectedKind = .incoming
        case .consent:
            state.selectedKind = .full
            state.isConsentPresented = true
        case .checkedConsent:
            state.selectedKind = .full
            state.consent = Set(ViewingKeyConsent.allCases)
            state.isConsentPresented = true
        case .hiddenDetail:
            state.selectedKind = .incoming
            state.detail = ExportViewingKeys.State.Detail(kind: .incoming)
        case .hiddenStringDetail:
            state.selectedKind = .incoming
            state.detail = ExportViewingKeys.State.Detail(kind: .incoming)
            state.detail?.tab = .keyString
        case .revealedQRDetail:
            let key = try #require(session.key(for: .incoming))
            let png = try await ViewingKeyQRCodeClient.liveValue.png(key)
            state.selectedKind = .incoming
            state.detail = ExportViewingKeys.State.Detail(kind: .incoming)
            state.detail?.isRevealed = true
            state.detail?.key = key
            state.detail?.qr = png
        case .revealedStringDetail:
            let key = try #require(session.key(for: .incoming))
            let png = try await ViewingKeyQRCodeClient.liveValue.png(key)
            state.selectedKind = .incoming
            state.detail = ExportViewingKeys.State.Detail(kind: .incoming)
            state.detail?.tab = .keyString
            state.detail?.isRevealed = true
            state.detail?.key = key
            state.detail?.qr = png
        case .qrFailure:
            state.selectedKind = .full
            state.detail = ExportViewingKeys.State.Detail(kind: .full)
            state.detail?.qrFailed = true
        case .unavailableKey:
            state.selectedKind = .incoming
            state.unavailableKey = true
        }

        if renderState == .revealedQRDetail || renderState == .revealedStringDetail {
            #expect(state.canShare)
        }

        return Store(initialState: state) {
            ExportViewingKeys()
        } withDependencies: {
            $0.zcashSDKEnvironment.network = {
                ZcashNetworkBuilder.network(for: .mainnet)
            }
        }
    }

    private func makeHostedSettingsView() async throws -> HostedSettingsView {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        let session = ViewingKeyExportSession(id: UUID(), account: account, network: .mainnet)
        let key = try #require(session.key(for: .incoming))
        let png = try await ViewingKeyQRCodeClient.liveValue.png(key)
        var flow = ExportViewingKeys.State(session: session)
        flow.$selectedWalletAccount.withLock { $0 = account }
        flow.$walletAccounts.withLock { $0 = [account] }
        flow.selectedKind = .incoming
        flow.detail = ExportViewingKeys.State.Detail(kind: .incoming)
        flow.detail?.isRevealed = true
        flow.detail?.key = key
        flow.detail?.qr = png
        flow.isInactive = true

        var state = Settings.State()
        state.isViewingKeyInactive = true
        state.$selectedWalletAccount.withLock { $0 = account }
        state.$walletAccounts.withLock { $0 = [account] }
        state.path.append(.exportViewingKeys(flow))
        let store = Store(initialState: state) {
            Reduce<Settings.State, Settings.Action> { state, action in
                switch action {
                case .viewingKeyBecameInactive:
                    state.isViewingKeyInactive = true
                    for id in Array(state.path.ids) {
                        state.path[id: id, case: \.exportViewingKeys]?.isInactive = true
                    }
                    return .none
                case .viewingKeyBecameActive:
                    state.isViewingKeyInactive = false
                    for id in Array(state.path.ids) {
                        state.path[id: id, case: \.exportViewingKeys]?.isInactive = false
                    }
                    return .none
                case .viewingKeyEnteredBackground:
                    for id in Array(state.path.ids) where state.path[id: id]?.exportViewingKeys != nil {
                        state.path[id: id] = nil
                    }
                    return .none
                default:
                    return .none
                }
            }
        } withDependencies: {
            $0.zcashSDKEnvironment.network = {
                ZcashNetworkBuilder.network(for: .mainnet)
            }
        }
        let controller = UIHostingController(rootView: SettingsView(store: store))
        let windowScene = try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        for _ in 0..<8 {
            await nextMainRunLoopTurn()
            window.layoutIfNeeded()
        }
        return HostedSettingsView(store: store, window: window)
    }

    private func render(
        store: StoreOf<ExportViewingKeys>,
        configuration: RenderConfiguration,
        expectsSheet: Bool,
        scrollToBottom: Bool = false,
        scrollToDecodedQRCode expectedQRCode: String? = nil
    ) async throws -> Data {
        let size = CGSize(width: configuration.width, height: configuration.height)
        let rootView = NavigationStack {
            ExportViewingKeysView(store: store)
        }
        .environment(\.colorScheme, configuration.colorScheme)
        .environment(\.dynamicTypeSize, configuration.dynamicTypeSize)
        .transaction { transaction in
            transaction.animation = nil
        }
        let controller = UIHostingController(rootView: rootView)
        let windowScene = try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let window = UIWindow(windowScene: windowScene)
        if #available(iOS 17.0, *) {
            window.traitOverrides.preferredContentSizeCategory = configuration.preferredContentSizeCategory
        }
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        for _ in 0..<8 {
            await nextMainRunLoopTurn()
            window.layoutIfNeeded()
        }

        if expectsSheet {
            let presented = try #require(window.rootViewController?.presentedViewController)
            if let coordinator = presented.transitionCoordinator {
                await withCheckedContinuation { continuation in
                    let registered = coordinator.animate(alongsideTransition: nil) { _ in
                        continuation.resume()
                    }
                    if !registered {
                        continuation.resume()
                    }
                }
            }
            await nextMainRunLoopTurn()
            window.layoutIfNeeded()
            let presentedView = try #require(presented.presentationController?.presentedView ?? presented.view)
            let visibleFrame = visiblePresentationFrame(view: presentedView, window: window)
            let visibleHeight = visibleFrame.height
            #expect(
                visibleHeight >= 400,
                "Consent sheet visible frame was \(visibleFrame) in window \(window.bounds)"
            )
        }


        var decodedCapture: UIImage?
        var bestQRCodeMargin: CGFloat = -.infinity
        if scrollToBottom || expectedQRCode != nil {
            let candidates = scrollViews(in: window)
            let scrollView = try #require(
                candidates
                    .filter {
                        expectsSheet
                            ? $0.bounds.height >= 200
                                && $0.bounds.width >= window.bounds.width * 0.7
                                && $0.bounds.width < window.bounds.width * 0.95
                            : $0.bounds.height >= window.bounds.height * 0.5
                                && $0.bounds.width >= window.bounds.width * 0.95
                    }
                    .max { scrollableHeight($0) < scrollableHeight($1) }
            )
            let maximumOffset = scrollableHeight(scrollView)
            #expect(maximumOffset > 0)
            if let expectedQRCode {
                let minimumOffset = -scrollView.adjustedContentInset.top
                let offsets = stride(from: minimumOffset, through: maximumOffset, by: 4).map { $0 }
                    + [maximumOffset]
                for offset in offsets {
                    scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    await nextMainRunLoopTurn()
                    window.layoutIfNeeded()
                    let candidate = capture(window: window)
                    guard let image = candidate.cgImage,
                          let feature = matchingQRCodeFeature(image, expected: expectedQRCode),
                          isFullyVisible(feature, in: image) else { continue }
                    let margin = min(
                        feature.bounds.minY,
                        CGFloat(image.height) - feature.bounds.maxY
                    )
                    if margin > bestQRCodeMargin {
                        bestQRCodeMargin = margin
                        decodedCapture = candidate
                    }
                }
                #expect(decodedCapture != nil)
            } else {
                scrollView.setContentOffset(CGPoint(x: 0, y: maximumOffset), animated: false)
                await nextMainRunLoopTurn()
                window.layoutIfNeeded()
                #expect(scrollView.contentOffset.y >= maximumOffset - 1)
            }
        }

        let image = decodedCapture ?? capture(window: window)
        window.rootViewController?.dismiss(animated: false)
        await nextMainRunLoopTurn()
        window.isHidden = true
        return try #require(image.pngData())
    }

    private func capture(window: UIWindow) -> UIImage {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func nextMainRunLoopTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func visiblePresentationFrame(view: UIView, window: UIWindow) -> CGRect {
        let frame = view.layer.presentation().map { layer in
            view.superview?.convert(layer.frame, to: window) ?? layer.frame
        } ?? view.convert(view.bounds, to: window)
        return frame.intersection(window.bounds)
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        let current = (view as? UIScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap(scrollViews(in:))
    }

    private func scrollableHeight(_ scrollView: UIScrollView) -> CGFloat {
        max(
            0,
            scrollView.contentSize.height
                + scrollView.adjustedContentInset.bottom
                - scrollView.bounds.height
        )
    }

    private func renderedQRCodeCard(
        _ image: CGImage,
        displayScale: Int,
        colorScheme: ColorScheme
    ) throws -> CGImage {
        let imageSide = 280 * displayScale
        let padding = 20 * displayScale
        let cardSide = imageSide + padding * 2
        let context = try #require(
            CGContext(
                data: nil,
                width: cardSide,
                height: cardSide,
                bitsPerComponent: 8,
                bytesPerRow: cardSide * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.interpolationQuality = .none
        context.setFillColor(UIColor(Design.Surfaces.bgSecondary.color(colorScheme)).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: cardSide, height: cardSide))

        let qrImage: CGImage
        if colorScheme == .dark {
            let filter = try #require(CIFilter(name: "CIColorInvert"))
            filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
            let output = try #require(filter.outputImage)
            qrImage = try #require(CIContext().createCGImage(output, from: output.extent))
            context.setBlendMode(.screen)
        } else {
            qrImage = image
            context.setBlendMode(.multiply)
        }
        context.draw(
            qrImage,
            in: CGRect(x: padding, y: padding, width: imageSide, height: imageSide)
        )
        return try #require(context.makeImage())
    }

    private func decodedQRCode(_ image: CGImage) -> String? {
        matchingQRCodeFeature(image)?.messageString
    }

    private func matchingQRCodeFeature(_ image: CGImage, expected: String? = nil) -> CIQRCodeFeature? {
        guard let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: CIContext(),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ) else {
            return nil
        }
        let features = detector.features(in: CIImage(cgImage: image)).compactMap { $0 as? CIQRCodeFeature }
        guard features.count == 1,
              let feature = features.first,
              expected == nil || feature.messageString == expected else {
            return nil
        }
        return feature
    }

    private func isFullyVisible(_ feature: CIQRCodeFeature, in image: CGImage) -> Bool {
        let minimumMargin = max(2, feature.bounds.width * 0.01)
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            .insetBy(dx: minimumMargin, dy: minimumMargin)
        return imageBounds.contains(feature.bounds)
    }
}

@MainActor
private struct HostedSettingsView {
    let store: StoreOf<Settings>
    let window: UIWindow
}
