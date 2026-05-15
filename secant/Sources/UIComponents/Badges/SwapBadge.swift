//
//  SwapBadge.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-06-22.
//

import SwiftUI

struct SwapBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    
    enum Status {
        case failed
        case incompleteDeposit
        case pending
        case pendingDeposit
        case processing
        case refunded
        case success
        case expired
        
        var title: String {
            switch self {
            case .pending: return String(localizable: .swapAndPayStatusPending)
            case .processing: return String(localizable: .swapAndPayStatusProcessing)
            case .refunded: return String(localizable: .swapAndPayStatusRefunded)
            case .success: return String(localizable: .swapAndPayStatusSuccess)
            case .failed: return String(localizable: .swapAndPayStatusFailed)
            case .pendingDeposit: return String(localizable: .swapAndPayStatusPendingDeposit)
            case .expired: return String(localizable: .swapAndPayStatusExpired)
            case .incompleteDeposit: return String(localizable: .swapAndPayStatusIncompleteDeposit)
            }
        }
        
        var fontStyle: Colorable {
            switch self {
            case .pending: return Design.Utility.HyperBlue._700
            case .processing: return Design.Utility.HyperBlue._700
            case .refunded: return Design.Utility.ErrorRed._700
            case .success: return Design.Utility.SuccessGreen._700
            case .failed: return Design.Utility.ErrorRed._700
            case .pendingDeposit: return Design.Utility.WarningYellow._700
            case .expired: return Design.Utility.ErrorRed._700
            case .incompleteDeposit: return Design.Utility.WarningYellow._700
            }
        }
        
        var bcgStyle: Colorable {
            switch self {
            case .pending: return Design.Utility.HyperBlue._50
            case .processing: return Design.Utility.HyperBlue._50
            case .refunded: return Design.Utility.ErrorRed._50
            case .success: return Design.Utility.SuccessGreen._50
            case .failed: return Design.Utility.ErrorRed._50
            case .pendingDeposit: return Design.Utility.WarningYellow._50
            case .expired: return Design.Utility.ErrorRed._50
            case .incompleteDeposit: return Design.Utility.WarningYellow._50
            }
        }
        
        var outlineStyle: Colorable {
            switch self {
            case .pending: return Design.Utility.HyperBlue._200
            case .processing: return Design.Utility.HyperBlue._200
            case .refunded: return Design.Utility.ErrorRed._200
            case .success: return Design.Utility.SuccessGreen._200
            case .failed: return Design.Utility.ErrorRed._200
            case .pendingDeposit: return Design.Utility.WarningYellow._200
            case .expired: return Design.Utility.ErrorRed._200
            case .incompleteDeposit: return Design.Utility.WarningYellow._200
            }
        }
    }
    
    let status: Status
    
    init(_ privacy: Status) {
        self.status = privacy
    }
    
    var body: some View {
        Text(status.title)
            .zFont(.medium, size: 14, style: status.fontStyle)
            .padding(.vertical, 2)
            .padding(.horizontal, 10)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._2xl)
                    .fill(status.bcgStyle.color(colorScheme))
                    .background {
                        RoundedRectangle(cornerRadius: Design.Radius._2xl)
                            .stroke(status.outlineStyle.color(colorScheme))
                    }
            }
    }
}

#Preview {
    VStack(spacing: 40) {
        SwapBadge(.success)
        SwapBadge(.pending)
        SwapBadge(.refunded)
    }
}
