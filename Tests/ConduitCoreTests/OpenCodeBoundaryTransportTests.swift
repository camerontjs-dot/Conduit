import ConduitCore
import Foundation
import XCTest

/// Owned in-process interception. No listener or provider is involved, and
/// this class is installed only on the ephemeral session used by these tests.
private final class BoundaryFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "conduit-fixture.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        if url.path == "/error" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let response: URLResponse
        if url.path == "/non-http" {
            response = URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 7, textEncodingName: "utf-8")
        } else {
            response = HTTPURLResponse(url: url, statusCode: url.path == "/failure" ? 500 : 204,
                                       httpVersion: "HTTP/1.1", headerFields: ["X-Fixture": "owned"])!
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("fixture".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class OpenCodeBoundaryTransportTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundaryFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
    @MainActor
    func testActualFoundationResponseCallbacksHaveDispatchReturnOrder() async throws {
        let owned = session(); defer { owned.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://conduit-fixture.invalid/success")!)
        var observations: [String] = []
        let (data, response) = try await OpenCodeBoundaryTransport.data(
            for: request, using: owned, onStart: { observations.append("start") },
            onResponse: { observations.append("response:\($0 ?? -1)") },
            onFailure: { observations.append("failure") }
        )
        observations.append("returned")
        XCTAssertEqual(observations, ["start", "response:204", "returned"])
        XCTAssertEqual(data, Data("fixture".utf8))
        XCTAssertEqual(response.url, request.url)
    }
    @MainActor
    func testHTTPFailureStillReturnsTheOriginalResponseAndBytes() async throws {
        let owned = session(); defer { owned.invalidateAndCancel() }
        var code: Int?; var failures = 0
        let (data, response) = try await OpenCodeBoundaryTransport.data(
            for: URLRequest(url: URL(string: "https://conduit-fixture.invalid/failure")!), using: owned,
            onStart: {}, onResponse: { code = $0 }, onFailure: { failures += 1 }
        )
        XCTAssertEqual(code, 500)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 500)
        XCTAssertEqual(data, Data("fixture".utf8)); XCTAssertEqual(failures, 0)
    }
    @MainActor
    func testOriginalTransportErrorIsThrownAndCannotProduceResponse() async {
        let owned = session(); defer { owned.invalidateAndCancel() }
        var observations: [String] = []
        do {
            _ = try await OpenCodeBoundaryTransport.data(
                for: URLRequest(url: URL(string: "https://conduit-fixture.invalid/error")!), using: owned,
                onStart: { observations.append("start") }, onResponse: { _ in observations.append("response") },
                onFailure: { observations.append("failure") }
            )
            XCTFail("The fixture transport must throw.")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSURLErrorDomain)
            XCTAssertEqual((error as NSError).code, URLError.timedOut.rawValue)
        }
        XCTAssertEqual(observations, ["start", "failure"])
    }
    @MainActor
    func testNonHTTPResponsePreservesUnknownStatus() async throws {
        let owned = session(); defer { owned.invalidateAndCancel() }
        var status: Int? = 204
        let (data, response) = try await OpenCodeBoundaryTransport.data(
            for: URLRequest(url: URL(string: "https://conduit-fixture.invalid/non-http")!), using: owned,
            onStart: {}, onResponse: { status = $0 }, onFailure: { XCTFail("Unexpected transport error") }
        )
        XCTAssertNil(status); XCTAssertFalse(response is HTTPURLResponse)
        XCTAssertEqual(data, Data("fixture".utf8))
    }
}
