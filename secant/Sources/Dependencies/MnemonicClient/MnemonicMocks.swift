//
//  MnemonicMocks.swift
//  Zashi
//
//  Created by Lukáš Korba on 13.11.2022.
//

import Foundation

extension MnemonicClient {
    static let mock = MnemonicClient(
        randomMnemonic: {
            """
            still champion voice habit trend flight \
            survey between bitter process artefact blind \
            carbon truly provide dizzy crush flush \
            breeze blouse charge solid fish spread
            """
        },
        randomMnemonicWords: {
            let mnemonic = """
                still champion voice habit trend flight \
                survey between bitter process artefact blind \
                carbon truly provide dizzy crush flush \
                breeze blouse charge solid fish spread
                """
            
            return mnemonic.components(separatedBy: " ")
        },
        toSeed: { _ in
            let seedString = Data(
                base64Encoded: "9VDVOZZZOWWHpZtq1Ebridp3Qeux5C+HwiRR0g7Oi7HgnMs8Gfln83+/Q1NnvClcaSwM4ADFL1uZHxypEWlWXg=="
            )!// swiftlint:disable:this force_unwrapping
            
            return [UInt8](seedString)
        },
        asWords: { mnemonic in
            let mnemonic = """
                still champion voice habit trend flight \
                survey between bitter process artefact blind \
                carbon truly provide dizzy crush flush \
                breeze blouse charge solid fish spread
                """
            
            return mnemonic.components(separatedBy: " ")
        },
        isValid: { _ in },
        suggestWords: { _ in [] }
    )
}
