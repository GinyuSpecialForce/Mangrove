import Foundation
import Security

/// A single HTTP cookie, stored in the Keychain so the app can talk to Overleaf
/// across launches without keeping the user's password anywhere.
struct CookieRecord: Codable, Hashable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var isSecure: Bool
    var expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }

    /// Whether this cookie should be sent to the given host.
    func matches(host: String) -> Bool {
        guard !isExpired else { return false }
        let normalized = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == normalized || host.hasSuffix("." + normalized)
    }

    init(name: String, value: String, domain: String, path: String = "/", isSecure: Bool = true, expiresAt: Date? = nil) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.isSecure = isSecure
        self.expiresAt = expiresAt
    }

    init?(cookie: HTTPCookie) {
        guard !cookie.name.isEmpty else { return nil }
        self.name = cookie.name
        self.value = cookie.value
        self.domain = cookie.domain
        self.path = cookie.path
        self.isSecure = cookie.isSecure
        self.expiresAt = cookie.expiresDate
    }
}

/// Everything needed to authenticate against one Overleaf instance.
struct StoredSession: Codable {
    var baseURL: String
    var cookies: [CookieRecord]
    var savedAt: Date

    var host: String { URL(string: baseURL)?.host ?? "" }

    var isEmpty: Bool { cookies.isEmpty }

    /// Builds a `Cookie:` request header value for the stored host.
    func cookieHeader() -> String {
        let host = self.host
        return cookies
            .filter { $0.matches(host: host) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// Parses a raw `Cookie:` header that the user copied from their browser's devtools.
    static func fromRawCookieHeader(_ header: String, baseURL: String) throws -> StoredSession {
        let host = URL(string: baseURL)?.host ?? ""
        var records: [CookieRecord] = []
        for pair in header.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[trimmed.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            records.append(CookieRecord(name: name, value: value, domain: host))
        }
        guard records.contains(where: { $0.name.contains("session") || $0.name.contains("sid") }) else {
            throw MangroveError.message(
                "That does not look like an Overleaf cookie header. Copy the full value of the `Cookie` request header from a logged-in overleaf.com request."
            )
        }
        return StoredSession(baseURL: baseURL, cookies: records, savedAt: Date())
    }
}

/// Keychain-backed storage for the session. One generic-password item.
final class SessionStore {
    private let service = "com.mangrovedesktop.session"
    private let account = "mangrove"

    func load() -> StoredSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    func save(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)
        var query = baseQuery()

        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MangroveError.message("Could not save your session to the Keychain (status \(addStatus)).")
        }
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
