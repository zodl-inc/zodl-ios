import Foundation
import XCTest
@testable import secant_testnet

final class VotingAPIResponseParserTests: XCTestCase {
    func testParseJSONObjectAcceptsRegularJSONObject() throws {
        let response = try makeResponse()
        let data = Data(#"{"tx_hash":"ABC123","code":0,"log":""}"#.utf8)

        let json = try SvAPIResponseParser.parseJSONObject(
            data,
            response: response,
            context: "POST /shielded-vote/v1/delegate-vote"
        )

        XCTAssertEqual(json["tx_hash"] as? String, "ABC123")
        XCTAssertEqual((json["code"] as? NSNumber)?.uint32Value, 0)
    }

    func testParseJSONObjectAcceptsDoubleEncodedJSONObject() throws {
        let response = try makeResponse()
        let data = Data(#""{\"tx_hash\":\"ABC123\",\"code\":0,\"log\":\"\"}""#.utf8)

        let json = try SvAPIResponseParser.parseJSONObject(
            data,
            response: response,
            context: "POST /shielded-vote/v1/delegate-vote"
        )

        XCTAssertEqual(json["tx_hash"] as? String, "ABC123")
        XCTAssertEqual((json["code"] as? NSNumber)?.uint32Value, 0)
    }

    func testParseJSONObjectIncludesContextOnMalformedJSON() throws {
        let response = try makeResponse()
        let data = Data("<html>ok</html>".utf8)

        do {
            _ = try SvAPIResponseParser.parseJSONObject(
                data,
                response: response,
                context: "POST /shielded-vote/v1/delegate-vote"
            )
            XCTFail("Expected invalid response error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("POST /shielded-vote/v1/delegate-vote"))
            XCTAssertTrue(error.localizedDescription.contains("Content-Type: application/json"))
            XCTAssertTrue(error.localizedDescription.contains("<html>ok</html>"))
        }
    }

    func testParseTxResultAcceptsFlatVoteAPIEnvelope() throws {
        let result = try SvAPIResponseParser.parseTxResult([
            "tx_hash": "ABC123",
            "code": 0,
            "log": ""
        ])

        XCTAssertEqual(result, TxResult(txHash: "ABC123", code: 0, log: ""))
    }

    func testParseTxResultAcceptsCosmosRestEnvelope() throws {
        let result = try SvAPIResponseParser.parseTxResult([
            "tx_response": [
                "txhash": "ABC123",
                "code": 0,
                "raw_log": ""
            ]
        ])

        XCTAssertEqual(result, TxResult(txHash: "ABC123", code: 0, log: ""))
    }

    func testParseTxResultAcceptsCometEnvelope() throws {
        let result = try SvAPIResponseParser.parseTxResult([
            "result": [
                "hash": "ABC123",
                "code": 0,
                "log": ""
            ]
        ])

        XCTAssertEqual(result, TxResult(txHash: "ABC123", code: 0, log: ""))
    }

    private func makeResponse() throws -> HTTPURLResponse {
        guard let url = URL(string: "https://vote-chain-primary.valargroup.org/shielded-vote/v1/delegate-vote"),
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              )
        else {
            throw XCTSkip("Failed to build HTTPURLResponse fixture")
        }
        return response
    }
}
