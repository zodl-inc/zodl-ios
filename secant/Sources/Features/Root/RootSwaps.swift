//
//  RootSwaps.swift
//  Zashi
//
//  Created by Lukáš Korba on 14.10.2025.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

extension Root {
    func swapsReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
            case .home(.transactionList(.transactionOnAppear(let txId))),
                .transactionsCoordFlow(.transactionsManager(.transactionOnAppear(let txId))):
                if let candidate = state.transactions[id: txId] {
                    let triggerResolution = state.autoUpdateSwapCandidates.isEmpty
                    state.autoUpdateSwapCandidates.append(candidate)
                    if triggerResolution {
                        return .send(.attemptToCheckSwapStatus(false))
                    }
                }
                return .none

            case .attemptToCheckSwapStatus(let fastSuccessFollowup):
                guard !state.autoUpdateSwapCandidates.isEmpty else {
                    return .none
                }

                let now = Date.now.timeIntervalSince1970
                let diff = now - state.autoUpdateLatestAttemptedTimestamp
                
                // schedule next check
                if fastSuccessFollowup {
                    state.autoUpdateRefreshScheduled = true
                    return .run { send in
                        let waitTime = UInt64.random(in: 500_000_000...1_500_000_000)
                        try? await Task.sleep(nanoseconds: waitTime)
                        await send(.attemptToCheckSwapStatus(false))
                    }
                } else if diff < 5.0 && !state.autoUpdateRefreshScheduled {
                    state.autoUpdateRefreshScheduled = true
                    return .run { send in
                        let waitTime = UInt64.random(in: 5_000_000_000...15_000_000_000)
                        try? await Task.sleep(nanoseconds: waitTime)
                        await send(.attemptToCheckSwapStatus(false))
                    }
                }
                state.autoUpdateLatestAttemptedTimestamp = now

                // check the status
                guard state.autoUpdateCandidate == nil else {
                    return .none
                }
                if let candidate = state.autoUpdateSwapCandidates.first {
                    // move it to the end of the queue
                    state.autoUpdateSwapCandidates.remove(candidate)
                    state.autoUpdateSwapCandidates.append(candidate)

                    state.autoUpdateRefreshScheduled = true
                    state.autoUpdateCandidate = candidate
                    return .run { send in
                        if let swapDetails = try? await swapAndPay.status(candidate.address, candidate.isSwapToZec) {
                            await send(.autoUpdateCandidatesSwapDetails(swapDetails))
                        }
                    }
                }
                return .none
                
            case .autoUpdateCandidatesSwapDetails(let swapDetails):
                guard let candidate = state.autoUpdateCandidate else {
                    state.autoUpdateRefreshScheduled = false
                    return .none
                }
                
                // terminated status update
                if candidate.isPending && !swapDetails.status.isPending {
                    return .send(.compareAndUpdateMetadataOfSwap(swapDetails))
                }
                
                // refresh next schedule
                state.autoUpdateRefreshScheduled = false
                state.autoUpdateCandidate = nil
                
                return .send(.attemptToCheckSwapStatus(false))
                
            case .compareAndUpdateMetadataOfSwap(let swapDetails):
                state.autoUpdateRefreshScheduled = false
                guard let candidatesId = state.autoUpdateCandidate?.id else {
                    state.autoUpdateCandidate = nil
                    return .send(.attemptToCheckSwapStatus(false))
                }
                guard var candidate = state.transactions[id: candidatesId], let zAddress = candidate.zAddress else {
                    state.autoUpdateCandidate = nil
                    return .send(.attemptToCheckSwapStatus(false))
                }
                state.autoUpdateSwapCandidates.remove(candidate)

                let umSwapId = userMetadataProvider.swapDetailsForTransaction(zAddress)
                guard var umSwapId else {
                    state.autoUpdateCandidate = nil
                    return .send(.attemptToCheckSwapStatus(false))
                }
                state.autoUpdateCandidate = nil

                var needsUpdate = false
                
                // from asset
                if let fromAsset = state.swapAssets.filter({ $0.assetId == swapDetails.fromAsset }).first {
                    if umSwapId.fromAsset != fromAsset.id {
                        needsUpdate = true
                        umSwapId.fromAsset = fromAsset.id
                    }
                }
                // to asset
                if let toAsset = state.swapAssets.filter({ $0.assetId == swapDetails.toAsset }).first {
                    if umSwapId.toAsset != toAsset.id {
                        needsUpdate = true
                        umSwapId.toAsset = toAsset.id
                    }
                }
                // swap vs. pay update
                if umSwapId.exactInput != swapDetails.isSwap {
                    needsUpdate = true
                    umSwapId.exactInput = swapDetails.isSwap
                }
                // amountOutFormatted
                if let amountOutFormattedValue = swapDetails.amountOutFormatted, swapDetails.isSwapToZec {
                    let amountOutFormatted = "\(amountOutFormattedValue)"
                    if umSwapId.amountOutFormatted != amountOutFormatted {
                        needsUpdate = true
                        umSwapId.amountOutFormatted = amountOutFormatted
                        if let localeString = amountOutFormatted.localeString {
                            candidate.swapToZecAmount = localeString
                        }
                    }
                }
                // status
                if umSwapId.status != swapDetails.status.rawName {
                    needsUpdate = true
                    umSwapId.status = swapDetails.status.rawName
                }
                // update of metadata needed
                if let account = state.selectedWalletAccount?.account, needsUpdate {
                    userMetadataProvider.update(umSwapId)
                    try? userMetadataProvider.store(account)
                    candidate.checkAndUpdateWith(umSwapId)
                    state.$transactions.withLock { $0[id: candidate.id] = candidate }
                }
                return .send(.attemptToCheckSwapStatus(true))

            default: return .none
            }
        }
    }
}
