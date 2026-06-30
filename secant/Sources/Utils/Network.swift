//
//  Network.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-08-19.
//

import Foundation

enum NetworkError: Error {
    case transport(URLError)
    case httpStatus(code: Int)
    case unknown(Error)

    var allowsRetry: Bool {
        switch self {
        case .transport(let urlError):
            switch urlError.code {
            case .timedOut,
                 .notConnectedToInternet,
                 .networkConnectionLost,
                 .cannotConnectToHost:
                return true
            default:
                return false
            }

        case .httpStatus(let code):
            // Retry server errors (5xx); client errors (4xx) won't succeed on retry.
            return (500...599).contains(code)

        case .unknown:
            return false
        }
    }
    
    var message: String {
        switch self {
        case .transport(let urlError):
            return "\(urlError.code)"
        case .httpStatus(let code):
            return "\(code)"
        case .unknown:
            return "unknown"
        }
    }
}
