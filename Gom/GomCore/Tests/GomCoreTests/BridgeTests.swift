import Foundation
import Testing
@testable import GomCore

@Suite struct BridgeTests {
    func request(_ method: String, _ path: String, origin: String? = "chrome-extension://abcdef", token: String? = "secret", body: String = "") -> HTTPRequest {
        var headers: [String: String] = [:]
        if let origin { headers["origin"] = origin }
        if let token { headers["x-gom-token"] = token }
        return HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
    }

    @Test func preflightIsForbidden() {
        #expect(route(request("OPTIONS", "/add"), token: "secret").0.status == 403)
    }

    @Test func missingOrWrongTokenIsUnauthorized() {
        #expect(route(request("GET", "/ping", token: nil), token: "secret").0.status == 401)
        #expect(route(request("GET", "/ping", token: "nope"), token: "secret").0.status == 401)
    }

    @Test func webPageOriginIsUnauthorized() {
        #expect(route(request("GET", "/ping", origin: "https://evil.example"), token: "secret").0.status == 401)
        #expect(route(request("GET", "/ping", origin: "null"), token: "secret").0.status == 401)
    }

    /// Chrome sends no Origin for fetches from an extension that holds host permissions
    /// (seen in Chrome 154: `Sec-Fetch-Site: none`, no Origin), so the token alone must be enough.
    @Test func extensionRequestWithoutOriginIsAllowed() {
        #expect(route(request("GET", "/ping", origin: nil), token: "secret").0.status == 200)
        #expect(route(request("GET", "/ping", origin: nil, token: nil), token: "secret").0.status == 401)
    }

    @Test func pingReturnsAppName() {
        let (response, add) = route(request("GET", "/ping"), token: "secret")
        #expect(response == HTTPResponse(status: 200, json: #"{"ok":true,"app":"Gom"}"#))
        #expect(add == nil)
    }

    @Test func addAcceptsValidDownload() {
        let body = #"{"url":"https://cdn.example.com/a.iso","filename":"a.iso","referrer":"https://example.com/","cookies":"s=1","userAgent":"UA"}"#
        let (response, add) = route(request("POST", "/add", body: body), token: "secret")
        #expect(response.status == 200)
        #expect(add?.url.absoluteString == "https://cdn.example.com/a.iso")
        #expect(add?.headers == ["Cookie": "s=1", "Referer": "https://example.com/", "User-Agent": "UA"])
    }

    @Test func addRejectsNonHTTPURL() {
        let (response, add) = route(request("POST", "/add", body: #"{"url":"file:///etc/passwd"}"#), token: "secret")
        #expect(response.status == 400)
        #expect(add == nil)
    }

    @Test func addRejectsBadJSON() {
        #expect(route(request("POST", "/add", body: "{"), token: "secret").0.status == 400)
    }

    @Test func unknownPathIsNotFound() {
        #expect(route(request("GET", "/nope"), token: "secret").0.status == 404)
    }

    @Test func tokensAreRandomHex() {
        let a = generateToken()
        let b = generateToken()
        #expect(a.count == 64)
        let allHex = a.allSatisfy(\.isHexDigit)
        #expect(allHex)
        #expect(a != b)
    }
}
