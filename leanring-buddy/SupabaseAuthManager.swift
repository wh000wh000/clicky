//
//  SupabaseAuthManager.swift
//  leanring-buddy
//
//  Manages Supabase authentication for the proxy mode.
//  Uses the Supabase Auth REST API directly via URLSession — no SPM package
//  required. Supports Apple Sign In (primary) and email/password (fallback).
//
//  Token storage mirrors the Keychain pattern already used in APIConfiguration.
//

import AuthenticationServices
import Combine
import Foundation
import Security

// MARK: - Data Models

/// A decoded Supabase Auth session returned by the API.
struct SupabaseSession: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int       // seconds from issue time
    let expiresAt: Int?      // Unix timestamp (optional, returned by some endpoints)
    let user: SupabaseUser

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn    = "expires_in"
        case expiresAt    = "expires_at"
        case user
    }

    /// Whether the access token is expired or will expire within the next 60 seconds.
    var isExpiredOrAboutToExpire: Bool {
        guard let storedExpiresAt = expiresAt else { return false }
        return Int(Date().timeIntervalSince1970) >= storedExpiresAt - 60
    }
}

/// A Supabase user object embedded in a session response.
struct SupabaseUser: Codable {
    let id: String
    let email: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
    }
}

// MARK: - SupabaseAuthManager

/// Central authentication manager for Supabase.
///
/// In proxy mode the app needs a valid Supabase JWT to call the Cloudflare Worker.
/// This manager handles sign-in, session persistence, and silent token refresh.
///
/// In direct mode (user supplies their own API key) this manager is not used.
@MainActor
final class SupabaseAuthManager: NSObject, ObservableObject {

    static let shared = SupabaseAuthManager()

    // MARK: - Published State

    /// The currently active session, or nil if the user is signed out.
    @Published private(set) var currentSession: SupabaseSession?

    var isAuthenticated: Bool { currentSession != nil }

    // MARK: - Configuration

    /// Supabase project URL, e.g. "https://abcdefgh.supabase.co"
    private let supabaseProjectURL: String

    /// Supabase anonymous (public) key — safe to embed in the client.
    private let supabaseAnonKey: String

    // MARK: - Private

    private let urlSession: URLSession
    private let keychainServiceName = "com.clicky.supabase-auth"

    // MARK: - Init

    private override init() {
        self.supabaseProjectURL = AppBundleConfiguration.stringValue(forKey: "SupabaseProjectURL") ?? ""
        self.supabaseAnonKey    = AppBundleConfiguration.stringValue(forKey: "SupabaseAnonKey") ?? ""
        self.urlSession = URLSession(configuration: .default)
        super.init()
    }

    // MARK: - Session Restoration

    /// Attempts to restore a persisted session from Keychain on app launch.
    /// If the stored access token is near expiry, silently refreshes it.
    func restoreSession() async {
        guard
            let storedAccessToken  = keychainRead(key: "accessToken"),
            let storedRefreshToken = keychainRead(key: "refreshToken")
        else {
            return // no persisted session
        }

        // Try to reconstruct a session from Keychain data.
        // We don't persist the full JSON so we build a minimal placeholder and
        // refresh immediately if the token looks expired (expiresAt not stored).
        let needsRefresh: Bool
        if let expiresAtString = keychainRead(key: "expiresAt"),
           let expiresAtInt = Int(expiresAtString) {
            needsRefresh = Int(Date().timeIntervalSince1970) >= expiresAtInt - 60
        } else {
            // No expiry stored — always refresh to be safe.
            needsRefresh = true
        }

        if needsRefresh {
            await refreshAccessToken(usingRefreshToken: storedRefreshToken)
        } else {
            // Build a lightweight in-memory session from stored values.
            let userId    = keychainRead(key: "userId") ?? ""
            let userEmail = keychainRead(key: "userEmail")
            let expiresAt = Int(keychainRead(key: "expiresAt") ?? "0") ?? 0
            currentSession = SupabaseSession(
                accessToken:  storedAccessToken,
                refreshToken: storedRefreshToken,
                expiresIn:    3600,
                expiresAt:    expiresAt,
                user:         SupabaseUser(id: userId, email: userEmail)
            )
        }
    }

    // MARK: - Apple Sign In

    /// Starts the Apple Sign In flow and exchanges the identity token for a Supabase session.
    func signInWithApple() async throws {
        let appleIDCredential = try await performAppleSignInRequest()
        guard let identityTokenData = appleIDCredential.identityToken,
              let identityTokenString = String(data: identityTokenData, encoding: .utf8) else {
            throw SupabaseAuthError.missingIdentityToken
        }

        let session = try await exchangeAppleIdentityTokenForSession(
            identityToken: identityTokenString
        )
        persistSession(session)
        currentSession = session
    }

    // MARK: - Email/Password Sign In & Sign Up

    /// Signs in with email and password.
    func signIn(email: String, password: String) async throws {
        let session = try await requestEmailPasswordSession(email: email, password: password)
        persistSession(session)
        currentSession = session
    }

    /// Registers a new account with email and password.
    /// Supabase's signup endpoint returns a full session when email confirmation
    /// is disabled, or just a user object (no session) when it is enabled.
    /// When email confirmation is required, throws `.emailConfirmationRequired`
    /// so the UI can switch to a "check your inbox" view instead of an error.
    func signUp(email: String, password: String) async throws {
        do {
            let session = try await requestSignUp(email: email, password: password)
            persistSession(session)
            currentSession = session
        } catch is DecodingError {
            // Signup succeeded but email confirmation is enabled — the response
            // contained a user object without an access_token. Signal the UI
            // to show the "check your email" screen. Sign-in will only work
            // after the user clicks the confirmation link in their inbox.
            throw SupabaseAuthError.emailConfirmationRequired(email: email)
        }
    }

    // MARK: - Sign Out

    /// Revokes the current session and clears all stored credentials.
    func signOut() {
        clearPersistedSession()
        currentSession = nil
    }

    /// Resends the signup confirmation email for an unconfirmed account.
    /// Safe to call multiple times; Supabase rate-limits resends server-side.
    func resendConfirmationEmail(email: String) async {
        guard !supabaseProjectURL.isEmpty else { return }

        let endpoint = URL(string: "\(supabaseProjectURL)/auth/v1/resend")!
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        let body: [String: Any] = ["type": "signup", "email": email]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        urlRequest.httpBody = bodyData

        _ = try? await urlSession.data(for: urlRequest)
        print("📧 Resent confirmation email to \(email)")
    }

    // MARK: - Token Refresh

    /// Silently refreshes the access token using the stored refresh token.
    func refreshSessionIfNeeded() async {
        guard let session = currentSession, session.isExpiredOrAboutToExpire else { return }
        await refreshAccessToken(usingRefreshToken: session.refreshToken)
    }

    // MARK: - Access Token Accessor

    /// Returns the current access token, refreshing it first if it is near expiry.
    /// Returns nil if the user is not authenticated.
    func validAccessToken() async -> String? {
        await refreshSessionIfNeeded()
        return currentSession?.accessToken
    }

    // MARK: - Auth Callback (Deep Link)

    /// Handles the Supabase email confirmation deep link opened via the custom
    /// URL scheme: `clicky://auth/callback#access_token=...&refresh_token=...`
    ///
    /// Supabase encodes the session tokens in the URL **fragment** (after `#`),
    /// not the query string, so we treat the fragment as a query string to parse
    /// individual key-value pairs.
    ///
    /// Called by `CompanionAppDelegate.application(_:open:)` whenever macOS
    /// hands the app a `clicky://` URL.
    func handleAuthCallback(url: URL) async {
        guard url.scheme == "clicky", url.host == "auth" else { return }

        guard let fragment = url.fragment else {
            print("⚠️ Auth callback: URL has no fragment")
            return
        }

        // Treat the fragment as a query string so URLComponents can parse it.
        var fragmentComponents = URLComponents()
        fragmentComponents.query = fragment
        guard let queryItems = fragmentComponents.queryItems else { return }

        let params = Dictionary(
            uniqueKeysWithValues: queryItems.compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name, value)
            }
        )

        // Surface errors (e.g. otp_expired) as console warnings — the app stays
        // in the "awaiting confirmation" state and the user can request a resend.
        if let errorCode = params["error"] {
            let description = params["error_description"]?
                .replacingOccurrences(of: "+", with: " ") ?? errorCode
            print("⚠️ Auth callback error (\(errorCode)): \(description)")
            return
        }

        guard
            let accessToken  = params["access_token"],
            let refreshToken = params["refresh_token"],
            let expiresInString = params["expires_in"],
            let expiresIn = Int(expiresInString)
        else {
            print("⚠️ Auth callback: missing required token fields in fragment")
            return
        }

        let expiresAt = params["expires_at"].flatMap { Int($0) }

        // Fetch full user details (id + email) using the new access token.
        let user = await fetchUserDetails(accessToken: accessToken)
            ?? SupabaseUser(id: "", email: nil)

        let session = SupabaseSession(
            accessToken:  accessToken,
            refreshToken: refreshToken,
            expiresIn:    expiresIn,
            expiresAt:    expiresAt,
            user:         user
        )

        persistSession(session)
        currentSession = session
        print("✅ Auth callback: session established for \(user.email ?? "unknown")")
    }

    /// Fetches the authenticated user's profile from Supabase using a valid access token.
    private func fetchUserDetails(accessToken: String) async -> SupabaseUser? {
        guard !supabaseProjectURL.isEmpty else { return nil }

        let endpoint = URL(string: "\(supabaseProjectURL)/auth/v1/user")!
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        guard let (data, _) = try? await urlSession.data(for: request) else { return nil }
        return try? JSONDecoder().decode(SupabaseUser.self, from: data)
    }

    // MARK: - Private: Apple Sign In Flow

    private func performAppleSignInRequest() async throws -> ASAuthorizationAppleIDCredential {
        return try await withCheckedThrowingContinuation { continuation in
            let appleIDProvider = ASAuthorizationAppleIDProvider()
            let request = appleIDProvider.createRequest()
            request.requestedScopes = [.email]

            let controller = ASAuthorizationController(authorizationRequests: [request])

            // We use an ephemeral delegate wrapper to bridge the callback into async/await.
            let delegateWrapper = AppleSignInDelegateWrapper { result in
                switch result {
                case .success(let credential):
                    continuation.resume(returning: credential)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            controller.delegate = delegateWrapper
            controller.presentationContextProvider = delegateWrapper
            controller.performRequests()

            // Retain the delegate wrapper for the duration of the request.
            // (ASAuthorizationController does not retain its delegate.)
            AppleSignInDelegateWrapper.retainTemporarily(delegateWrapper)
        }
    }

    // MARK: - Private: REST API calls

    private func exchangeAppleIdentityTokenForSession(
        identityToken: String
    ) async throws -> SupabaseSession {
        guard !supabaseProjectURL.isEmpty else { throw SupabaseAuthError.notConfigured }

        let endpoint = URL(string: "\(supabaseProjectURL)/auth/v1/token?grant_type=id_token")!
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        let body: [String: Any] = [
            "provider": "apple",
            "id_token": identityToken
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await performSessionRequest(urlRequest)
    }

    private func requestEmailPasswordSession(
        email: String,
        password: String
    ) async throws -> SupabaseSession {
        guard !supabaseProjectURL.isEmpty else { throw SupabaseAuthError.notConfigured }

        let endpoint = URL(string: "\(supabaseProjectURL)/auth/v1/token?grant_type=password")!
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        let body = ["email": email, "password": password]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await performSessionRequest(urlRequest)
    }

    private func requestSignUp(
        email: String,
        password: String
    ) async throws -> SupabaseSession {
        guard !supabaseProjectURL.isEmpty else { throw SupabaseAuthError.notConfigured }

        // Supabase signup endpoint returns a session directly when email
        // confirmation is disabled, or a user object (no session) when it is enabled.
        // We assume confirmation is disabled for this internal app.
        let endpoint = URL(string: "\(supabaseProjectURL)/auth/v1/signup")!
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        let body = ["email": email, "password": password]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await performSessionRequest(urlRequest)
    }

    private func refreshAccessToken(usingRefreshToken refreshToken: String) async {
        guard !supabaseProjectURL.isEmpty else { return }

        let endpoint = URL(string: "\(supabaseProjectURL)/auth/v1/token?grant_type=refresh_token")!
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        let body = ["refresh_token": refreshToken]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        urlRequest.httpBody = bodyData

        do {
            let session = try await performSessionRequest(urlRequest)
            persistSession(session)
            currentSession = session
        } catch {
            // Refresh failed (e.g. token revoked) — require re-authentication.
            print("⚠️ Supabase token refresh failed: \(error). Signing out.")
            signOut()
        }
    }

    /// Performs a URLSession request, decodes a SupabaseSession from the response,
    /// and throws a descriptive error if the HTTP status is not 2xx.
    private func performSessionRequest(_ request: URLRequest) async throws -> SupabaseSession {
        let (data, response) = try await urlSession.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("❌ Supabase Auth API error \(httpResponse.statusCode): \(errorMessage)")
            throw SupabaseAuthError.apiError(statusCode: httpResponse.statusCode, body: errorMessage)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(SupabaseSession.self, from: data)
    }

    // MARK: - Private: Session Persistence (Keychain)

    private func persistSession(_ session: SupabaseSession) {
        keychainWrite(key: "accessToken",  value: session.accessToken)
        keychainWrite(key: "refreshToken", value: session.refreshToken)
        keychainWrite(key: "userId",       value: session.user.id)
        if let email = session.user.email {
            keychainWrite(key: "userEmail", value: email)
        }
        if let expiresAt = session.expiresAt {
            keychainWrite(key: "expiresAt", value: String(expiresAt))
        } else {
            // Derive expiresAt from the current time plus the expiresIn interval.
            let derivedExpiresAt = Int(Date().timeIntervalSince1970) + session.expiresIn
            keychainWrite(key: "expiresAt", value: String(derivedExpiresAt))
        }
    }

    private func clearPersistedSession() {
        for key in ["accessToken", "refreshToken", "userId", "userEmail", "expiresAt"] {
            keychainDelete(key: key)
        }
    }

    // MARK: - Keychain Helpers

    private func keychainRead(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainWrite(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        keychainDelete(key: key) // avoid duplicate-item errors
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      keychainServiceName,
            kSecAttrAccount as String:      key,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlocked
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func keychainDelete(key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Error Types

enum SupabaseAuthError: LocalizedError {
    case notConfigured
    case missingIdentityToken
    case emailConfirmationRequired(email: String)
    case apiError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Supabase is not configured. Set SupabaseProjectURL and SupabaseAnonKey in Info.plist."
        case .missingIdentityToken:
            return "Apple Sign In did not return an identity token."
        case .emailConfirmationRequired(let email):
            return "注册成功！确认邮件已发送至 \(email)，请点击邮件中的链接激活账号后再登录。"
        case .apiError(let statusCode, let body):
            return "Supabase Auth API error \(statusCode): \(body)"
        }
    }
}

// MARK: - Apple Sign In Delegate Wrapper

/// A bridge that turns the ASAuthorizationControllerDelegate callbacks into
/// an async/await continuation. Also serves as the presentation context provider
/// so the system can anchor the Apple Sign In sheet to the correct window.
private final class AppleSignInDelegateWrapper: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    private let completionHandler: (Result<ASAuthorizationAppleIDCredential, Error>) -> Void

    /// Temporary strong references so the delegate is not deallocated before
    /// the ASAuthorizationController delivers its result.
    private static var temporaryRetainer: [AppleSignInDelegateWrapper] = []

    init(completionHandler: @escaping (Result<ASAuthorizationAppleIDCredential, Error>) -> Void) {
        self.completionHandler = completionHandler
    }

    static func retainTemporarily(_ wrapper: AppleSignInDelegateWrapper) {
        temporaryRetainer.append(wrapper)
    }

    private func release() {
        AppleSignInDelegateWrapper.temporaryRetainer.removeAll { $0 === self }
    }

    // MARK: ASAuthorizationControllerDelegate

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        defer { release() }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            completionHandler(.failure(SupabaseAuthError.missingIdentityToken))
            return
        }
        completionHandler(.success(credential))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        defer { release() }
        completionHandler(.failure(error))
    }

    // MARK: ASAuthorizationControllerPresentationContextProviding

    func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        // Return the key window. For a menu bar app there is no main window, but
        // the floating panel counts as a window and is sufficient for Apple Sign In.
        return NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }
}
