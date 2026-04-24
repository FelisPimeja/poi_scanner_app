import Foundation
import AuthenticationServices
import CryptoKit
import Observation

// MARK: - OSMAuthService
// OAuth 2.0 PKCE авторизация через openstreetmap.org

@MainActor
@Observable
final class OSMAuthService {

    static let shared = OSMAuthService()

    // MARK: - OAuth Config
    // Зарегистрируй приложение на https://www.openstreetmap.org/oauth2/applications
    // Redirect URI должен совпадать с CFBundleURLSchemes в Info.plist: poiscanner://oauth
    private let clientID     = "k4NOJKHdqhOSlABRCvy3Z4tqNylkAAD3y-G1rYASiLc"
    private let redirectURI  = "poi-scanner://osm-oauth"
    private let authURL      = "https://www.openstreetmap.org/oauth2/authorize"
    private let tokenURL     = URL(string: "https://www.openstreetmap.org/oauth2/token")!
    private let scope        = "write_api"

    // MARK: - State
    var isAuthenticated = false
    var userName: String?

    // Держим сильную ссылку — иначе ARC освобождает сессию до колбека (error 2)
    private var authSession: ASWebAuthenticationSession?
    // presentationContextProvider — weak var в ASWebAuthenticationSession, держим отдельно
    private var authSessionContext: PresentationContextProviderBox?

    private(set) var accessToken: String? {
        didSet {
            if let token = accessToken {
                KeychainHelper.save(token, key: "osm_access_token")
            } else {
                KeychainHelper.delete(key: "osm_access_token")
            }
            isAuthenticated = accessToken != nil
        }
    }

    private init() {
        // Восстанавливаем токен из Keychain при старте
        if let saved = KeychainHelper.load(key: "osm_access_token") {
            self.accessToken = saved
            self.isAuthenticated = true
            Task { await fetchUserInfo() }
        }
    }

    // MARK: - Public API

    func signIn(presentationAnchor: ASPresentationAnchor) async throws {
        let (codeVerifier, codeChallenge) = makePKCE()
        let state = UUID().uuidString

        var components = URLComponents(string: authURL)!
        components.queryItems = [
            .init(name: "response_type",         value: "code"),
            .init(name: "client_id",             value: clientID),
            .init(name: "redirect_uri",          value: redirectURI),
            .init(name: "scope",                 value: scope),
            .init(name: "state",                 value: state),
            .init(name: "code_challenge",        value: codeChallenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        guard let authPageURL = components.url else {
            throw OSMAuthError.invalidURL
        }

        // Открываем браузер и ждём редиректа
        let callbackURL: URL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
            let context = PresentationContextProviderBox(anchor: presentationAnchor)
            let session = ASWebAuthenticationSession(
                url: authPageURL,
                callbackURLScheme: "poi-scanner"
            ) { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: OSMAuthError.cancelled) }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = context
            authSessionContext = context  // weak var — держим сами, иначе ARC убьёт → error 2
            authSession = session         // держим сессию живой до редиректа
            session.start()
        }
        authSession = nil
        authSessionContext = nil

        // Извлекаем code и проверяем state
        guard
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
            components.queryItems?.first(where: { $0.name == "state" })?.value == state
        else {
            throw OSMAuthError.invalidCallback
        }

        // Меняем code на access token
        let token = try await exchangeCode(code, codeVerifier: codeVerifier)
        accessToken = token
        await fetchUserInfo()
    }

    func signOut() {
        accessToken = nil
        userName = nil
    }

    // MARK: - Token Exchange

    private func exchangeCode(_ code: String, codeVerifier: String) async throws -> String {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // urlQueryAllowed не экранирует '+','=','&' — используем строгий набор
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")

        let params: [(String, String)] = [
            ("grant_type",    "authorization_code"),
            ("code",          code),
            ("redirect_uri",  redirectURI),
            ("client_id",     clientID),
            ("code_verifier", codeVerifier),
        ]
        request.httpBody = params
            .map { k, v in
                let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
                let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
                return "\(ek)=\(ev)"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? "<binary>"
        print("[OSMAuth] token exchange status=\(statusCode) body=\(body)")

        guard statusCode == 200 else {
            throw OSMAuthError.tokenExchangeFailed("HTTP \(statusCode): \(body)")
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = json["access_token"] as? String
        else {
            throw OSMAuthError.tokenExchangeFailed("Нет access_token в ответе: \(body)")
        }
        return token
    }

    // MARK: - User Info

    @discardableResult
    func fetchUserInfo() async -> String? {
        guard let token = accessToken else { return nil }
        var request = URLRequest(url: URL(string: "https://api.openstreetmap.org/api/0.6/user/details.json")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard
            let (data, _) = try? await URLSession.shared.data(for: request),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let user = json["user"] as? [String: Any],
            let name = user["display_name"] as? String
        else { return nil }
        userName = name
        return name
    }

    // MARK: - PKCE

    private func makePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        return (verifier, challenge)
    }
}

// MARK: - PresentationContextProviderBox

private final class PresentationContextProviderBox: NSObject, ASWebAuthenticationPresentationContextProviding {
    let anchor: ASPresentationAnchor
    init(anchor: ASPresentationAnchor) { self.anchor = anchor }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
}

// MARK: - OSMAuthError

enum OSMAuthError: LocalizedError {
    case invalidURL
    case cancelled
    case invalidCallback
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:                    return "Неверный URL авторизации"
        case .cancelled:                     return "Авторизация отменена"
        case .invalidCallback:               return "Неверный ответ от сервера авторизации"
        case .tokenExchangeFailed(let msg):  return "Не удалось получить токен доступа: \(msg)"
        }
    }
}
