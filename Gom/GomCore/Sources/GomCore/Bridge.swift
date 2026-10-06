import Foundation

public struct AddRequest: Codable, Equatable, Sendable {
    public var url: URL
    public var filename: String?
    public var referrer: String?
    public var cookies: String?
    public var userAgent: String?

    /// Request headers to replay when downloading.
    public var headers: [String: String] {
        var headers: [String: String] = [:]
        if let cookies, !cookies.isEmpty { headers["Cookie"] = cookies }
        if let referrer, !referrer.isEmpty { headers["Referer"] = referrer }
        if let userAgent, !userAgent.isEmpty { headers["User-Agent"] = userAgent }
        return headers
    }
}

/// Decides the response to a bridge request. Returns the download to add, if any.
/// The token is the credential. Web pages can't send it: the custom X-Gom-Token header forces a
/// CORS preflight, which is always refused, and any non-extension Origin is rejected outright.
/// A missing Origin is allowed because Chrome omits it for extensions with host permissions.
public func route(_ request: HTTPRequest, token: String) -> (HTTPResponse, AddRequest?) {
    if request.method == "OPTIONS" {
        return (HTTPResponse(status: 403, json: #"{"ok":false,"error":"forbidden"}"#), nil)
    }
    let originAllowed = request.headers["origin"].map { $0.hasPrefix("chrome-extension://") } ?? true
    guard originAllowed, request.headers["x-gom-token"] == token else {
        return (HTTPResponse(status: 401, json: #"{"ok":false,"error":"unauthorized"}"#), nil)
    }
    switch (request.method, request.path) {
    case ("GET", "/ping"):
        return (HTTPResponse(status: 200, json: #"{"ok":true,"app":"Gom"}"#), nil)
    case ("POST", "/add"):
        guard let add = try? JSONDecoder().decode(AddRequest.self, from: request.body), isDownloadableURL(add.url) else {
            return (HTTPResponse(status: 400, json: #"{"ok":false,"error":"bad request"}"#), nil)
        }
        return (HTTPResponse(status: 200, json: #"{"ok":true}"#), add)
    default:
        return (HTTPResponse(status: 404, json: #"{"ok":false,"error":"not found"}"#), nil)
    }
}

/// 32 random bytes as hex. SystemRandomNumberGenerator is cryptographically secure on Apple platforms.
public func generateToken() -> String {
    (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
}
