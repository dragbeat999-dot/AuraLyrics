import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

// MARK: - Konfigurasi Spotify
public enum SpotifyConfig {
    static let placeholderClientID = "6a71e3653d88426396334ef290e7e894"

    /// GANTI teks di bawah ini dengan Client ID dari Spotify Developer Dashboard
    public static let clientID = "6a71e3653d88426396334ef290e7e894"

    /// Harus sama persis dengan Redirect URI yang terdaftar di dashboard
    public static let redirectURI = "auralyrics://spotify-callback"
    public static let callbackScheme = "auralyrics"

    public static let scopes = "user-read-currently-playing user-read-playback-state"
}

// MARK: - Error
public enum SpotifyError: LocalizedError {
    case notConfigured
    case notLoggedIn
    case cancelled
    case invalidCallback
    case stateMismatch
    case tokenRequestFailed(String)
    case rateLimited(TimeInterval)
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Client ID Spotify belum diisi di file SpotifyAuthManager.swift."
        case .notLoggedIn:
            return "Belum masuk ke Spotify."
        case .cancelled:
            return "Login dibatalkan."
        case .invalidCallback:
            return "Balasan login Spotify tidak valid."
        case .stateMismatch:
            return "Verifikasi login gagal (state tidak cocok). Coba lagi."
        case .tokenRequestFailed(let message):
            return "Gagal menukar token Spotify: \(message)"
        case .rateLimited(let seconds):
            return "Terlalu banyak permintaan ke Spotify, coba lagi sekitar \(Int(seconds)) detik."
        case .http(let code):
            switch code {
            case 401:
                return "Sesi Spotify kedaluwarsa (401). Coba keluar lalu masuk lagi."
            case 403:
                return "Spotify menolak akses (403). Pastikan akunmu terdaftar di User Management dashboard."
            default:
                return "Spotify mengembalikan error HTTP \(code)."
            }
        }
    }
}

// MARK: - Penyimpanan token (Keychain, cadangan UserDefaults)
enum SpotifyTokenStore {
    private static let service = "com.auralyrics.spotify"

    static func save(_ value: String, key: String) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = Data(value.utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        let fallbackKey = "\(service).\(key)"
        if status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
        } else {
            // Beberapa lingkungan sideload menolak Keychain, simpan di UserDefaults sebagai cadangan
            UserDefaults.standard.set(value, forKey: fallbackKey)
        }
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let string = String(data: data, encoding: .utf8) {
            return string
        }
        return UserDefaults.standard.string(forKey: "\(service).\(key)")
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "\(service).\(key)")
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        return base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Manajer login Spotify (OAuth PKCE, tanpa Client Secret)
@MainActor
public final class SpotifyAuthManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    public static let shared = SpotifyAuthManager()

    @Published public private(set) var isLoggedIn: Bool = false

    private var accessToken: String?
    private var accessTokenExpiry: Date = .distantPast
    private var authSession: ASWebAuthenticationSession?

    private override init() {
        super.init()
        isLoggedIn = (SpotifyTokenStore.load(key: "refresh_token") != nil)
    }

    // MARK: Login
    public func login() async throws {
        guard SpotifyConfig.clientID != SpotifyConfig.placeholderClientID else {
            throw SpotifyError.notConfigured
        }

        let verifier = Self.randomURLSafeString(byteCount: 64)
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomURLSafeString(byteCount: 16)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: SpotifyConfig.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: SpotifyConfig.redirectURI),
            URLQueryItem(name: "scope", value: SpotifyConfig.scopes),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state)
        ]
        guard let authURL = components.url else { throw SpotifyError.invalidCallback }

        let callbackURL = try await startWebAuth(url: authURL)

        guard let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems else {
            throw SpotifyError.invalidCallback
        }
        if let errorValue = items.first(where: { $0.name == "error" })?.value {
            throw SpotifyError.tokenRequestFailed(errorValue)
        }
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw SpotifyError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw SpotifyError.invalidCallback
        }

        try await requestToken(parameters: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": SpotifyConfig.redirectURI,
            "client_id": SpotifyConfig.clientID,
            "code_verifier": verifier
        ])
    }

    public func logout() {
        accessToken = nil
        accessTokenExpiry = .distantPast
        SpotifyTokenStore.delete(key: "refresh_token")
        isLoggedIn = false
    }

    // MARK: Token akses
    public func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let token = accessToken, accessTokenExpiry.timeIntervalSinceNow > 60 {
            return token
        }
        guard let refresh = SpotifyTokenStore.load(key: "refresh_token") else {
            throw SpotifyError.notLoggedIn
        }
        try await requestToken(parameters: [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": SpotifyConfig.clientID
        ])
        guard let token = accessToken else { throw SpotifyError.notLoggedIn }
        return token
    }

    // MARK: Internal
    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?
    }

    private func requestToken(parameters: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body = URLComponents()
        body.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpotifyError.http(-1) }

        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            if message.contains("invalid_grant") && parameters["grant_type"] == "refresh_token" {
                logout()
            }
            throw SpotifyError.tokenRequestFailed(message)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let token = try decoder.decode(TokenResponse.self, from: data)

        accessToken = token.accessToken
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expiresIn))
        if let refresh = token.refreshToken {
            SpotifyTokenStore.save(refresh, key: "refresh_token")
        }
        isLoggedIn = true
    }

    private func startWebAuth(url: URL) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: SpotifyConfig.callbackScheme
            ) { callbackURL, error in
                if let callbackURL = callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let authError = error as? ASWebAuthenticationSessionError,
                          authError.code == .canceledLogin {
                    continuation.resume(throwing: SpotifyError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? SpotifyError.invalidCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session
            session.start()
        }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first ?? ASPresentationAnchor()
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncodedString()
    }
}
