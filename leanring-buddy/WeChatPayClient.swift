//
//  WeChatPayClient.swift
//  leanring-buddy
//
//  Calls the Clicky Worker's WeChat Pay routes:
//    POST /create-wechat-order      — creates a Native pay order, returns QR code URL
//    GET  /check-payment-status     — polls order status (paid or not)
//
//  The caller is responsible for generating a QR code image from the returned
//  code_url (see WeChatQRCodeGenerator) and displaying it to the user.
//

import Foundation

// MARK: - Data types

/// Returned by `createOrder(plan:)`. Contains everything needed to display
/// the payment QR code and poll for completion.
struct WeChatPayOrder {
    /// WeChat Pay QR code URL — encode this into a QR image for the user to scan.
    let codeURL: String
    /// Unique order number. Pass to `checkPaymentStatus(outTradeNo:)` while polling.
    let outTradeNo: String
    /// "pro" or "premium" — the plan the user is paying for.
    let plan: String
    /// Order amount in fen (1 CNY = 100 fen). e.g. 2900 = ¥29.00.
    let amountFen: Int
}

// MARK: - Errors

enum WeChatPayError: LocalizedError {
    case notConfigured
    case notAuthenticated
    case invalidServerResponse
    case serverError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "微信支付尚未配置，请联系开发者。"
        case .notAuthenticated:
            return "请先登录后再升级套餐。"
        case .invalidServerResponse:
            return "服务器返回了无效响应，请稍后重试。"
        case .serverError(let statusCode, _):
            return "创建订单失败（\(statusCode)），请稍后重试。"
        }
    }
}

// MARK: - Client

@MainActor
final class WeChatPayClient {
    static let shared = WeChatPayClient()
    private init() {}

    // MARK: - Create order

    /// Calls POST /create-wechat-order and returns the QR code URL + order metadata.
    /// The caller should display a QR code from `WeChatPayOrder.codeURL` and start
    /// polling `checkPaymentStatus(outTradeNo:)` every 3 seconds.
    func createOrder(plan: String) async throws -> WeChatPayOrder {
        let workerBaseURL  = APIConfiguration.shared.chatAPIBaseURL
        let endpointString = "\(workerBaseURL)/create-wechat-order"
        guard let endpointURL = URL(string: endpointString) else {
            throw WeChatPayError.notConfigured
        }

        guard let accessToken = SupabaseAuthManager.shared.currentSession?.accessToken,
              !accessToken.isEmpty else {
            throw WeChatPayError.notAuthenticated
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["plan": plan])
        request.timeoutInterval = 30

        let (responseData, urlResponse) = try await URLSession.shared.data(for: request)

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw WeChatPayError.invalidServerResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? "(empty)"
            print("❌ WeChatPayClient createOrder: HTTP \(httpResponse.statusCode): \(body)")
            throw WeChatPayError.serverError(statusCode: httpResponse.statusCode, body: body)
        }

        guard let json      = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let codeURL   = json["code_url"]      as? String,
              let outTradeNo = json["out_trade_no"] as? String,
              let planName  = json["plan"]           as? String else {
            throw WeChatPayError.invalidServerResponse
        }

        let amountFen = json["amount_fen"] as? Int ?? 0
        print("✅ WeChatPayClient: order \(outTradeNo) created (plan: \(planName), ¥\(amountFen / 100))")
        return WeChatPayOrder(
            codeURL:    codeURL,
            outTradeNo: outTradeNo,
            plan:       planName,
            amountFen:  amountFen
        )
    }

    // MARK: - Poll payment status

    /// Calls GET /check-payment-status?out_trade_no=xxx.
    /// Returns `true` when WeChat Pay confirms the order as paid (trade_state == SUCCESS).
    /// Returns `false` for any non-paid state or transient errors — the caller should
    /// keep polling until `true` or a timeout is reached.
    func checkPaymentStatus(outTradeNo: String) async throws -> Bool {
        let workerBaseURL  = APIConfiguration.shared.chatAPIBaseURL
        let endpointString = "\(workerBaseURL)/check-payment-status?out_trade_no=\(outTradeNo)"
        guard let endpointURL = URL(string: endpointString) else {
            throw WeChatPayError.notConfigured
        }

        guard let accessToken = SupabaseAuthManager.shared.currentSession?.accessToken,
              !accessToken.isEmpty else {
            throw WeChatPayError.notAuthenticated
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (responseData, urlResponse) = try await URLSession.shared.data(for: request)

        guard let httpResponse = urlResponse as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            // Transient error — caller keeps polling.
            return false
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let paid = json["paid"] as? Bool else {
            return false
        }

        return paid
    }
}
