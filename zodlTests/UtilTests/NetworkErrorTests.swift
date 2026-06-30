//
//  NetworkErrorTests.swift
//  zodlTests
//
//  Covers NetworkError.allowsRetry / .message (Utils/Network.swift).
//

import Testing
import Foundation
@testable import zodl_internal

@Suite struct NetworkErrorTests {
    @Test(arguments: [
        URLError.Code.timedOut,
        .notConnectedToInternet,
        .networkConnectionLost,
        .cannotConnectToHost
    ])
    func transportRetryableCodesAllowRetry(_ code: URLError.Code) {
        #expect(NetworkError.transport(URLError(code)).allowsRetry)
    }

    @Test(arguments: [
        URLError.Code.badURL,
        .cancelled,
        .unsupportedURL,
        .userAuthenticationRequired
    ])
    func transportNonRetryableCodesDoNotAllowRetry(_ code: URLError.Code) {
        #expect(!NetworkError.transport(URLError(code)).allowsRetry)
    }

    @Test func unknownErrorDoesNotAllowRetry() {
        #expect(!NetworkError.unknown(SampleError.boom).allowsRetry)
    }

    @Test func messageReflectsCase() {
        #expect(NetworkError.httpStatus(code: 404).message == "404")
        #expect(NetworkError.unknown(SampleError.boom).message == "unknown")
        #expect(!NetworkError.transport(URLError(.timedOut)).message.isEmpty)
    }

    @Test func clientErrorsDoNotRetry() {
        #expect(NetworkError.httpStatus(code: 400).allowsRetry == false)
        #expect(NetworkError.httpStatus(code: 404).allowsRetry == false)
    }

    @Test func serverErrorsRetry() {
        #expect(NetworkError.httpStatus(code: 500).allowsRetry == true)
        #expect(NetworkError.httpStatus(code: 502).allowsRetry == true)
        #expect(NetworkError.httpStatus(code: 503).allowsRetry == true)
    }
}

private enum SampleError: Error {
    case boom
}
