//
//  SmartBannerMigrationContent.swift
//  zodl
//
//  Ironwood migration content for the SmartBanner's `priorityMigration` case (MOB-1464). Visual-only:
//  the case can never be requested by the running evaluator chain yet — wiring the real
//  triggering/evaluators/routing is MOB-1466's job. `MigrationBannerVariant` is a pure, testable
//  mapping (see MigrationBannerVariantTests); `migrationContent()` mirrors `shieldingContent()`'s
//  structure.
//

import SwiftUI
import ComposableArchitecture

enum MigrationBannerVariant: Equatable {
    case required
    case splitting
    case inProgress(done: Int, total: Int)
    case transferWaiting(number: Int)
    case updatePlan
    case transfersExpired(first: Int, last: Int)
    case transferReady(number: Int)
    case complete

    var title: String {
        switch self {
        case .required, .splitting:
            return String(localizable: .migrationBannerRequiredTitle)
        case .inProgress:
            return String(localizable: .migrationBannerProgressTitle)
        case .transferWaiting(let number):
            return String(localizable: .migrationBannerWaitingTitle(number))
        case .updatePlan:
            return String(localizable: .migrationBannerUpdatePlanTitle)
        case .transfersExpired(let first, let last):
            return String(localizable: .migrationBannerExpiredTitle(first, last))
        case .transferReady(let number):
            return String(localizable: .migrationBannerReadyTitle(number))
        case .complete:
            return String(localizable: .migrationBannerCompleteTitle)
        }
    }

    var info: String {
        switch self {
        case .required:
            return String(localizable: .migrationBannerRequiredInfo)
        case .splitting:
            return String(localizable: .migrationBannerSplittingInfo)
        case .inProgress(let done, let total):
            return String(localizable: .migrationBannerProgressInfo(done, total, percent ?? 0))
        case .transferWaiting:
            return String(localizable: .migrationBannerWaitingInfo)
        case .updatePlan:
            return String(localizable: .migrationBannerUpdatePlanInfo)
        case .transfersExpired:
            return String(localizable: .migrationBannerExpiredInfo)
        case .transferReady:
            return String(localizable: .migrationBannerReadyInfo)
        case .complete:
            return String(localizable: .migrationBannerCompleteInfo)
        }
    }

    /// "More" everywhere except `transferReady`, which reads "Review".
    var buttonLabel: String {
        switch self {
        case .transferReady:
            return String(localizable: .sendReview)
        default:
            return String(localizable: .generalMore)
        }
    }

    var percent: Int? {
        guard case let .inProgress(done, total) = self else {
            return nil
        }
        return Int((Double(done) / Double(max(total, 1)) * 100).rounded())
    }
}

extension SmartBannerView {
    @ViewBuilder func migrationContent() -> some View {
        HStack(spacing: 0) {
            migrationIcon()
                .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(store.migrationBannerVariant.title)
                    .zFont(.medium, size: 14, color: titleStyle())

                Text(store.migrationBannerVariant.info)
                    .zFont(.medium, size: 12, color: infoStyle())
            }

            Spacer()

            ZashiButton(
                store.migrationBannerVariant.buttonLabel,
                type: .ghost,
                infinityWidth: false
            ) {
                store.send(.smartBannerContentTapped)
            }
        }
    }

    @ViewBuilder private func migrationIcon() -> some View {
        switch store.migrationBannerVariant {
        case .required, .splitting:
            Asset.Assets.Icons.coinsSwap.image
                .zImage(size: 20, color: titleStyle())
        case .inProgress:
            migrationProgressRing()
        case .transferWaiting, .updatePlan, .transfersExpired, .transferReady:
            Asset.Assets.Icons.alertCircle.image
                .zImage(size: 20, color: titleStyle())
        case .complete:
            Asset.Assets.Icons.checkVerified.image
                .zImage(size: 20, color: titleStyle())
        }
    }

    @ViewBuilder private func migrationProgressRing() -> some View {
        let percent = store.migrationBannerVariant.percent ?? 0

        ZStack {
            Circle()
                .stroke(titleStyle().opacity(0.3), lineWidth: 2)

            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(titleStyle(), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
    }
}
