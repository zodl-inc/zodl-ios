#if VOTING_ENABLED
import Foundation
import Testing
@testable import zodl_internal

@Suite struct VotingAPIResponseParserTests {
    @Test func parseJSONObjectAcceptsRegularJSONObject() throws {
        let response = try makeResponse()
        let data = Data(#"{"tx_hash":"ABC123","code":0,"log":""}"#.utf8)

        let json = try SvAPIResponseParser.parseJSONObject(
            data,
            response: response,
            context: "POST /shielded-vote/v1/delegate-vote"
        )

        #expect(json["tx_hash"] as? String == "ABC123")
        #expect((json["code"] as? NSNumber)?.uint32Value == 0)
    }

    @Test func parseJSONObjectAcceptsDoubleEncodedJSONObject() throws {
        let response = try makeResponse()
        let data = Data(#""{\"tx_hash\":\"ABC123\",\"code\":0,\"log\":\"\"}""#.utf8)

        let json = try SvAPIResponseParser.parseJSONObject(
            data,
            response: response,
            context: "POST /shielded-vote/v1/delegate-vote"
        )

        #expect(json["tx_hash"] as? String == "ABC123")
        #expect((json["code"] as? NSNumber)?.uint32Value == 0)
    }

    @Test func parseJSONObjectIncludesContextOnMalformedJSON() throws {
        let response = try makeResponse()
        let data = Data("<html>ok</html>".utf8)

        let error = #expect(throws: (any Error).self) {
            _ = try SvAPIResponseParser.parseJSONObject(
                data,
                response: response,
                context: "POST /shielded-vote/v1/delegate-vote"
            )
        }

        #expect(error?.localizedDescription.contains("POST /shielded-vote/v1/delegate-vote") == true)
        #expect(error?.localizedDescription.contains("Content-Type: application/json") == true)
        #expect(error?.localizedDescription.contains("<html>ok</html>") == true)
    }

    @Test func parseTxResultAcceptsFlatVoteAPIEnvelope() throws {
        let result = try SvAPIResponseParser.parseTxResult([
            "tx_hash": "ABC123",
            "code": 0,
            "log": ""
        ])

        #expect(result == TxResult(txHash: "ABC123", code: 0, log: ""))
    }

    @Test func parseTxResultAcceptsCosmosRestEnvelope() throws {
        let result = try SvAPIResponseParser.parseTxResult([
            "tx_response": [
                "txhash": "ABC123",
                "code": 0,
                "raw_log": ""
            ]
        ])

        #expect(result == TxResult(txHash: "ABC123", code: 0, log: ""))
    }

    @Test func parseTxResultAcceptsCometEnvelope() throws {
        let result = try SvAPIResponseParser.parseTxResult([
            "result": [
                "hash": "ABC123",
                "code": 0,
                "log": ""
            ]
        ])

        #expect(result == TxResult(txHash: "ABC123", code: 0, log: ""))
    }

    private func makeResponse() throws -> HTTPURLResponse {
        let url = try #require(URL(string: "https://vote-chain-primary.valargroup.org/shielded-vote/v1/delegate-vote"))
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return response
    }
}
#endif
