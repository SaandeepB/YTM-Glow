import Foundation

/// Decides which WebSocket `Origin`s may connect.
///
/// Browsers attach an `Origin` header to every WebSocket handshake, and
/// WebSockets are not covered by CORS, so without this check any web page
/// could talk to the app. Extension origins and native clients (which send no
/// `Origin`) are allowed; web pages are not.
public enum OriginPolicy {
    static let allowedSchemes: Set<String> = ["chrome-extension", "moz-extension", "safari-web-extension"]

    public static func isAllowed(_ origin: String?) -> Bool {
        guard let origin = origin?.trimmingCharacters(in: .whitespaces), !origin.isEmpty else {
            return true
        }
        guard let schemeEnd = origin.range(of: "://") else { return false }
        let scheme = origin[origin.startIndex..<schemeEnd.lowerBound].lowercased()
        let rest = origin[schemeEnd.upperBound...]
        return allowedSchemes.contains(scheme) && !rest.isEmpty
    }
}
