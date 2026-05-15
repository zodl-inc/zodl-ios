//
//  LocalAuthenticationMocks.swift
//  Zashi
//
//  Created by Lukáš Korba on 12.11.2022.
//

extension LocalAuthenticationClient {
    static let mockAuthenticationSucceeded = Self(
        authenticate: { true },
        method: { .none }
    )
    
    static let mockAuthenticationFailed = Self(
        authenticate: { false },
        method: { .none }
    )
}
