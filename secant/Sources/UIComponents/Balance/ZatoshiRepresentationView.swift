//
//  ZatoshiRepresentationView.swift
//
//
//  Created by Lukáš Korba on 03.11.2023.
//

import SwiftUI
@preconcurrency import ZcashLightClientKit
import ComposableArchitecture
import XCTestDynamicOverlay
@preconcurrency import Combine

struct ZatoshiText: View {
    let balance: Zatoshi
    let format: ZatoshiStringRepresentation.Format
    let postfix: String?

    @Shared(.appStorage(.sensitiveContent)) var isSensitiveContentHidden = false
    
    init(
        _ balance: Zatoshi,
        _ format: ZatoshiStringRepresentation.Format = .expanded,
        _ postfix: String? = nil
    ) {
        self.balance = balance
        self.format = format
        self.postfix = postfix
    }
    
    var body: some View {
        if isSensitiveContentHidden {
            Text(localizable: .generalHideBalancesMost)
        } else {
            if format == .abbreviated {
                if let postfix {
                    Text("\(balance.threeDecimalsZashiFormatted()) \(postfix)")
                } else {
                    Text("\(balance.threeDecimalsZashiFormatted())")
                }
            } else {
                if let postfix {
                    Text("\(balance.atLeastThreeDecimalsZashiFormatted()) \(postfix)")
                } else {
                    Text("\(balance.atLeastThreeDecimalsZashiFormatted())")
                }
            }
        }
    }
}

struct ZatoshiRepresentationView: View {
    let zatoshiStringRepresentation: ZatoshiStringRepresentation
    let fontName: String
    let mostSignificantFontSize: CGFloat
    let leastSignificantFontSize: CGFloat
    let format: ZatoshiStringRepresentation.Format
    let strikethrough: Bool
    let isFee: Bool
    let couldBeHidden: Bool

    @Shared(.appStorage(.sensitiveContent)) var isSensitiveContentHidden = false
    
    init(
        balance: Zatoshi,
        fontName: String,
        mostSignificantFontSize: CGFloat,
        isFee: Bool = false,
        leastSignificantFontSize: CGFloat = 0,
        prefixSymbol: ZatoshiStringRepresentation.PrefixSymbol = .none,
        format: ZatoshiStringRepresentation.Format = .abbreviated,
        strikethrough: Bool = false,
        couldBeHidden: Bool = false
    ) {
        if !_XCTIsTesting {
            @Dependency(\.balanceFormatter) var balanceFormatter
            
            self.zatoshiStringRepresentation = balanceFormatter.convert(
                balance,
                prefixSymbol,
                format
            )
        } else {
            self.zatoshiStringRepresentation = ZatoshiStringRepresentation(
                balance,
                prefixSymbol: prefixSymbol,
                format: format
            )
        }
        self.fontName = fontName
        self.mostSignificantFontSize = mostSignificantFontSize
        self.leastSignificantFontSize = leastSignificantFontSize
        self.format = format
        self.strikethrough = strikethrough
        self.isFee = isFee
        self.couldBeHidden = couldBeHidden
    }
    
    var body: some View {
        WithPerceptionTracking {
            HStack {
                if isFee {
                    Text(zatoshiStringRepresentation.feeFormat)
                        .font(.custom(fontName, size: mostSignificantFontSize))
                } else {
                    if format == .expanded {
                        Text(couldBeHidden && isSensitiveContentHidden
                             ? String(localizable: .generalHideBalancesMost)
                             : zatoshiStringRepresentation.mostSignificantDigits
                        )
                        .font(.custom(fontName, size: mostSignificantFontSize))
                        .conditionalStrikethrough(strikethrough)
                        + Text(couldBeHidden && isSensitiveContentHidden
                               ? String(localizable: .generalHideBalancesLeast)
                               : zatoshiStringRepresentation.leastSignificantDigits
                        )
                        .font(.custom(fontName, size: leastSignificantFontSize))
                        .conditionalStrikethrough(strikethrough)
                    } else {
                        Text(couldBeHidden && isSensitiveContentHidden
                             ? String(localizable: .generalHideBalancesMostStandalone)
                             : zatoshiStringRepresentation.mostSignificantDigits
                        )
                        .font(.custom(fontName, size: mostSignificantFontSize))
                        .conditionalStrikethrough(strikethrough)
                    }
                }
            }
        }
    }
}

#Preview {
    let mostSignificantFontSize: CGFloat = 30
    let leastSignificantFontSize: CGFloat = 15
    
    return ScrollView {
        Text("PREFIX NONE")
            .padding()

        Text("abbreviated")

        ZatoshiRepresentationView(
            balance: Zatoshi(0),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize
        )

        ZatoshiRepresentationView(
            balance: Zatoshi(99_000),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize
        )

        ZatoshiRepresentationView(
            balance: Zatoshi(100_000),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize
        )

        ZatoshiRepresentationView(
            balance: Zatoshi(25_793_456),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize
        )

        Text("expanded")

        ZatoshiRepresentationView(
            balance: Zatoshi(0),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            format: .expanded
        )

        ZatoshiRepresentationView(
            balance: Zatoshi(5_000),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            format: .expanded
        )
        
        ZatoshiRepresentationView(
            balance: Zatoshi(100_000),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            format: .expanded
        )

        ZatoshiRepresentationView(
            balance: Zatoshi(25_793_456),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            format: .expanded
        )
        
        Text("PREFIX PLUS")
            .padding()

        Text("abbreviated")

        ZatoshiRepresentationView(
            balance: Zatoshi(0),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            prefixSymbol: .plus
        )

        ZatoshiRepresentationView(
            balance: Zatoshi(99_000),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            prefixSymbol: .plus
        )

        ZatoshiRepresentationView(
            balance: Zatoshi(100_000),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            prefixSymbol: .plus
        )

        ZatoshiRepresentationView(
            balance: Zatoshi(25_793_456),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            prefixSymbol: .plus
        )

        Text("expanded")

        ZatoshiRepresentationView(
            balance: Zatoshi(0),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            prefixSymbol: .plus,
            format: .expanded
        )

        ZatoshiRepresentationView(
            balance: Zatoshi(5_000),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            prefixSymbol: .plus,
            format: .expanded
        )
        
        ZatoshiRepresentationView(
            balance: Zatoshi(100_000),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            prefixSymbol: .plus,
            format: .expanded
        )

        ZatoshiRepresentationView(
            balance: Zatoshi(25_793_456),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            prefixSymbol: .plus,
            format: .expanded
        )
        
        Text("PREFIX MINUS")
            .padding()

        Text("abbreviated")

        ZatoshiRepresentationView(
            balance: Zatoshi(0),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            prefixSymbol: .minus
        )

        ZatoshiRepresentationView(
            balance: Zatoshi(99_000),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            prefixSymbol: .minus
        )

        ZatoshiRepresentationView(
            balance: Zatoshi(100_000),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            prefixSymbol: .minus
        )

        ZatoshiRepresentationView(
            balance: Zatoshi(25_793_456),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            prefixSymbol: .minus
        )

        Text("expanded")

        ZatoshiRepresentationView(
            balance: Zatoshi(0),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            prefixSymbol: .minus,
            format: .expanded
        )

        ZatoshiRepresentationView(
            balance: Zatoshi(5_000),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            prefixSymbol: .minus,
            format: .expanded
        )
        
        ZatoshiRepresentationView(
            balance: Zatoshi(100_000),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            prefixSymbol: .minus,
            format: .expanded
        )

        ZatoshiRepresentationView(
            balance: Zatoshi(25_793_456),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            leastSignificantFontSize: leastSignificantFontSize,
            prefixSymbol: .minus,
            format: .expanded
        )
        
        Text("FEE")
            .padding()

        ZatoshiRepresentationView(
            balance: Zatoshi(25_793_456),
            fontName: FontFamily.Inter.regular.name,
            mostSignificantFontSize: mostSignificantFontSize,
            isFee: true
        )
    }
}
