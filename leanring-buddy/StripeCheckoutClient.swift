//
//  StripeCheckoutClient.swift
//  leanring-buddy
//
//  Calls the Clicky Worker's /create-checkout-session endpoint and returns
//  the Stripe-hosted checkout URL. The caller opens this URL in the browser
//  via NSWorkspace.shared.open(_:) — no Stripe SDK needed on the client.
//

import Foundation

// MARK: - Error type

enum StripeCheckoutError: LocalizedError {
    case invalidEndpointURL
    case notAuthenticated
    case noActiveSubscription
    case invalidServerResponse
    case serverError(statusCode: Int, body: String)
    case missingCheckoutURL

    var errorDescription: String? {
        switch self {
        case .invalidEndpointURL:
            return "Worker endpoint URL is invalid — check API settings."
        case .notAuthenticated:
            return "请先登录后再操作。"
        case .noActiveSubscription:
            return "尚无有效订阅，请先升级套餐。"
        case .invalidServerResponse:
            return "服务器返回了无效响应，请稍后重试。"
        case .serverError(let statusCode, _):
            return "请求失败（\(statusCode)），请稍后重试。"
        case .missingCheckoutURL:
            return "未能获取页面链接，请稍后重试。"
        }
    }
}

// MARK: - Client

/// Thin client for the Worker's /create-checkout-session route.
/// Stateless — every call reads the current APIConfiguration and Supabase session.
@MainActor
final class StripeCheckoutClient {
    static let shared = StripeCheckoutClient()
    private init() {}

    /// Calls POST /create-checkout-session on the Clicky Worker and returns
    /// the Stripe-hosted checkout page URL.
    ///
    /// - Parameter plan: "pro" or "premium" — must match a configured Stripe price
    /// - Returns: The Stripe Checkout URL to open in the browser
    /// - Throws: `StripeCheckoutError` on any failure
    func createCheckoutSession(plan: String) async throws -> URL {
        let workerBaseURL = APIConfiguration.shared.chatAPIBaseURL
        let endpointString = "\(workerBaseURL)/create-checkout-session"
        guard let endpointURL = URL(string: endpointString) else {
            throw StripeCheckoutError.invalidEndpointURL
        }

        guard let accessToken = SupabaseAuthManager.shared.currentSession?.accessToken,
              !accessToken.isEmpty else {
            throw StripeCheckoutError.notAuthenticated
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The Worker verifies this JWT to authenticate the user server-side.
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["plan": plan])
        request.timeoutInterval = 30

        let (responseData, urlResponse) = try await URLSession.shared.data(for: request)

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw StripeCheckoutError.invalidServerResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: responseData, encoding: .utf8) ?? "(empty)"
            print("❌ StripeCheckoutClient: server error \(httpResponse.statusCode): \(responseBody)")
            throw StripeCheckoutError.serverError(
                statusCode: httpResponse.statusCode,
                body: responseBody
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let checkoutURLString = json["url"] as? String,
              let checkoutURL = URL(string: checkoutURLString) else {
            throw StripeCheckoutError.missingCheckoutURL
        }

        print("✅ StripeCheckoutClient: checkout session created for plan '\(plan)'")
        return checkoutURL
    }

    /// Calls POST /create-portal-session on the Clicky Worker and returns the
    /// Stripe Billing Portal URL so the user can manage their subscription.
    /// Only available to users who have completed at least one checkout.
    ///
    /// - Returns: The Stripe Billing Portal URL to open in the browser
    /// - Throws: `StripeCheckoutError.noActiveSubscription` if the user has no Stripe customer record
    func createPortalSession() async throws -> URL {
        let workerBaseURL = APIConfiguration.shared.chatAPIBaseURL
        let endpointString = "\(workerBaseURL)/create-portal-session"
        guard let endpointURL = URL(string: endpointString) else {
            throw StripeCheckoutError.invalidEndpointURL
        }

        guard let accessToken = SupabaseAuthManager.shared.currentSession?.accessToken,
              !accessToken.isEmpty else {
            throw StripeCheckoutError.notAuthenticated
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        // Empty body — the Worker infers the user from the JWT.
        request.httpBody = try JSONSerialization.data(withJSONObject: [:])
        request.timeoutInterval = 30

        let (responseData, urlResponse) = try await URLSession.shared.data(for: request)

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw StripeCheckoutError.invalidServerResponse
        }

        // 404 with "no_subscription" means the user has never subscribed.
        if httpResponse.statusCode == 404 {
            throw StripeCheckoutError.noActiveSubscription
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: responseData, encoding: .utf8) ?? "(empty)"
            print("❌ StripeCheckoutClient portal: server error \(httpResponse.statusCode): \(responseBody)")
            throw StripeCheckoutError.serverError(
                statusCode: httpResponse.statusCode,
                body: responseBody
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let portalURLString = json["url"] as? String,
              let portalURL = URL(string: portalURLString) else {
            throw StripeCheckoutError.missingCheckoutURL
        }

        print("✅ StripeCheckoutClient: billing portal session created")
        return portalURL
    }
}
