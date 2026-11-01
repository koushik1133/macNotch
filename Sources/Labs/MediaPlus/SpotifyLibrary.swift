import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

/// Hearts for Spotify tracks through Spotify's Web API (Spotify's
/// AppleScript has no "like"). Off until the user connects it:
///
/// 1. The user registers a free app at developer.spotify.com with the
///    redirect URI `sparkv-spotify://callback` and pastes its Client ID.
/// 2. "Connect Spotify" opens Spotify's sign-in (OAuth with PKCE, scopes
///    `user-library-read user-library-modify`; no client secret exists).
/// 3. Tokens live in the login keychain; the access token refreshes itself.
///
/// What leaves the Mac: the id of the playing track, sent to
/// api.spotify.com when a track starts (to show the heart) and when the
/// heart is tapped. Nothing else.
@MainActor
final class SpotifyLibraryClient: NSObject, ObservableObject, MediaLibraryService, ASWebAuthenticationPresentationContextProviding {
    static let shared = SpotifyLibraryClient()

    static let redirectURI = "sparkv-spotify://callback"
    static let scopes = "user-library-read user-library-modify"

    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.clientID) }
    }
    @Published private(set) var isConnected: Bool
    @Published private(set) var isConnecting = false
    @Published private(set) var lastError: String?

    private enum Keys {
        static let clientID = "Spotify.clientID"
    }

    private struct Tokens: Codable {
        var access: String
        var refresh: String
        var expiresAt: Date
    }

    private var tokens: Tokens?
    private var session: ASWebAuthenticationSession?

    override init() {
        clientID = UserDefaults.standard.string(forKey: Keys.clientID) ?? ""
        isConnected = SpotifyKeychain.hasItem()
        super.init()
    }

    // MARK: Connecting

    func connect() {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            lastError = "Paste your Spotify app’s Client ID first"
            return
        }
        let verifier = Self.randomVerifier()
        let challenge = Self.challenge(for: verifier)
        let state = UUID().uuidString
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else { return }
        lastError = nil
        isConnecting = true
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "sparkv-spotify") { [weak self] callback, error in
            let callback = callback
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                self.session = nil
                guard !failed, let callback,
                      let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
                      items.first(where: { $0.name == "state" })?.value == state,
                      let code = items.first(where: { $0.name == "code" })?.value
                else {
                    self.isConnecting = false
                    if !failed { self.lastError = "Spotify didn’t confirm the connection" }
                    return
                }
                await self.exchange(code: code, verifier: verifier, clientID: id)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() {
            isConnecting = false
            lastError = "Couldn’t open Spotify’s sign-in"
        }
    }

    func disconnect() {
        tokens = nil
        SpotifyKeychain.delete()
        isConnected = false
        AppLog.log("Spotify: disconnected")
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey } ?? NSWindow()
        }
    }

    private func exchange(code: String, verifier: String, clientID: String) async {
        defer { isConnecting = false }
        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ]
        guard let fresh = await tokenRequest(body, keepingRefresh: nil) else {
            lastError = "Spotify refused the sign-in"
            return
        }
        store(fresh)
        isConnected = true
        AppLog.log("Spotify: connected for library hearts")
    }

    // MARK: MediaLibraryService

    func isSaved(trackID: String) async -> Bool? {
        guard let data = await api("GET", path: "me/tracks/contains", trackID: trackID),
              let flags = try? JSONSerialization.jsonObject(with: data) as? [Bool] else { return nil }
        return flags.first
    }

    func setSaved(_ saved: Bool, trackID: String) async -> Bool {
        await api(saved ? "PUT" : "DELETE", path: "me/tracks", trackID: trackID) != nil
    }

    // MARK: HTTP

    private func api(_ method: String, path: String, trackID: String) async -> Data? {
        guard Self.isValidID(trackID), let token = await validAccessToken() else { return nil }
        var components = URLComponents(string: "https://api.spotify.com/v1/" + path)!
        components.queryItems = [URLQueryItem(name: "ids", value: trackID)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await MPNetwork.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                tokens?.expiresAt = .distantPast
                return nil
            }
            guard (200..<300).contains(status) else {
                AppLog.log("Spotify: \(method) \(path) returned \(status)")
                return nil
            }
            return data
        } catch {
            AppLog.log("Spotify: \(method) \(path) failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func validAccessToken() async -> String? {
        if tokens == nil { tokens = SpotifyKeychain.load().flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) } }
        guard let current = tokens else {
            isConnected = false
            return nil
        }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.access }
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, let fresh = await tokenRequest(
            ["grant_type": "refresh_token", "refresh_token": current.refresh, "client_id": id],
            keepingRefresh: current.refresh
        ) else {
            lastError = "Reconnect Spotify (the sign-in expired)"
            return nil
        }
        store(fresh)
        return fresh.access
    }

    private func tokenRequest(_ fields: [String: String], keepingRefresh: String?) async -> Tokens? {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields).data(using: .utf8)
        guard let (data, response) = try? await MPNetwork.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String else { return nil }
        let refresh = object["refresh_token"] as? String ?? keepingRefresh ?? ""
        let expires = (object["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return Tokens(access: access, refresh: refresh, expiresAt: Date().addingTimeInterval(expires))
    }

    private func store(_ fresh: Tokens) {
        tokens = fresh
        if let data = try? JSONEncoder().encode(fresh) { SpotifyKeychain.save(data) }
    }

    // MARK: Helpers (tested)

    nonisolated static func formBody(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    /// 64 random URL-safe characters (RFC 7636: 43…128).
    nonisolated static func randomVerifier() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    /// base64url(SHA256(verifier)) without padding.
    nonisolated static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Spotify ids are 22 base-62 characters.
    nonisolated static func isValidID(_ id: String) -> Bool {
        id.count == 22 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

/// The Spotify tokens as one generic-password item (ClickyKeychain's
/// pattern: no access control, since SparkV is ad-hoc signed).
enum SpotifyKeychain {
    static let service = "com.sparkv.spotify"
    static let account = "oauth-tokens"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Attributes only: never prompts.
    static func hasItem() -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    static func load() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func save(_ data: Data) {
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        if update != errSecItemNotFound { delete() }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "SparkV Spotify (library hearts)"
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { AppLog.log("Spotify: keychain save failed (\(status))") }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
