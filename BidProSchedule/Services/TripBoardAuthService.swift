import Foundation
import WebKit

struct TripBoardCookie: Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expiresDate: Date?
    let isSecure: Bool

    init(cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expiresDate = cookie.expiresDate
        isSecure = cookie.isSecure
    }

    func toHTTPCookie() -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .secure: isSecure
        ]
        if let expiresDate {
            properties[.expires] = expiresDate
        }
        return HTTPCookie(properties: properties)
    }
}

protocol TripBoardAuthServiceProtocol {
    func loadPersistedCookies() -> [HTTPCookie]
    func persistCookies(_ cookies: [HTTPCookie]) throws
    func clearPersistedCookies() throws
    func isAuthenticated(url: URL?, cookies: [HTTPCookie]) -> Bool
    @MainActor
    func currentWebKitCookies() async -> [HTTPCookie]
    @MainActor
    func clearWebKitCookies() async
}

final class TripBoardAuthService: TripBoardAuthServiceProtocol {
    private let keychain: KeychainServiceProtocol
    private let account = "tripboard.cookies"
    private let allowedDomainSuffix = "bidproplus.com"
    private let authCookieNames = [".aspnet.ups-trip-board"]

    init(keychain: KeychainServiceProtocol = KeychainService()) {
        self.keychain = keychain
    }

    func loadPersistedCookies() -> [HTTPCookie] {
        do {
            guard let data = try keychain.load(account: account) else { return [] }
            let stored = try JSONDecoder().decode([TripBoardCookie].self, from: data)
            return stored.compactMap { $0.toHTTPCookie() }.filter { isBidProCookie($0) }
        } catch {
            return []
        }
    }

    func persistCookies(_ cookies: [HTTPCookie]) throws {
        let filtered = cookies.filter { isBidProCookie($0) }
        let stored = filtered.map(TripBoardCookie.init(cookie:))
        let data = try JSONEncoder().encode(stored)
        try keychain.save(data: data, account: account)
    }

    func clearPersistedCookies() throws {
        try keychain.delete(account: account)
    }

    func isAuthenticated(url: URL?, cookies: [HTTPCookie]) -> Bool {
        let validCookies = cookies.filter { cookie in
            isBidProCookie(cookie) && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
        }
        if validCookies.isEmpty { return false }

        // Only treat session as logged-in when an actual auth cookie exists.
        let hasAuthCookie = validCookies.contains { cookie in
            authCookieNames.contains(cookie.name.lowercased())
        }
        if !hasAuthCookie { return false }

        guard let url else { return true }
        let host = url.host?.lowercased() ?? ""
        if !host.contains(allowedDomainSuffix) { return false }

        let path = url.path.lowercased()
        return !path.contains("login") && !path.contains("authenticate")
    }

    @MainActor
    func currentWebKitCookies() async -> [HTTPCookie] {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return cookies.filter { isBidProCookie($0) }
    }

    @MainActor
    func clearWebKitCookies() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await store.allCookies()
        for cookie in cookies where isBidProCookie(cookie) {
            await store.deleteCookieAsync(cookie)
        }
    }

    private func isBidProCookie(_ cookie: HTTPCookie) -> Bool {
        cookie.domain.lowercased().contains(allowedDomainSuffix)
    }
}

@MainActor
private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}

@MainActor
private extension WKHTTPCookieStore {
    func deleteCookieAsync(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            delete(cookie) {
                continuation.resume()
            }
        }
    }
}
