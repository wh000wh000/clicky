//
//  OpenAICompatibleChatAPI.swift
//  leanring-buddy
//
//  Chat API client for OpenAI-compatible endpoints (SiliconFlow, OpenRouter,
//  etc.). Uses the standard /v1/chat/completions format with vision support.
//  Drop-in replacement for ClaudeAPI — same method signature so
//  CompanionManager can switch between them based on APIConfiguration.
//

import Foundation

/// Thrown when the Clicky proxy Worker rejects a /chat request because the
/// user's daily quota is exhausted. Carries the structured 429 response body
/// so the UI can display the exact limit and current usage count.
struct ChatQuotaExceededError: LocalizedError {
    let message: String
    let dailyLimit: Int
    let usedToday: Int

    var errorDescription: String? { message }
}

class OpenAICompatibleChatAPI {
    private let apiURL: URL
    var model: String
    private let apiKey: String
    private let session: URLSession

    init(baseURL: String, model: String, apiKey: String) {
        // If baseURL already ends with /chat/completions, use as-is.
        // Otherwise append the standard path.
        if baseURL.hasSuffix("/chat/completions") {
            self.apiURL = URL(string: baseURL)!
        } else {
            let cleanedBaseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
            self.apiURL = URL(string: "\(cleanedBaseURL)/chat/completions")!
        }
        self.model = model
        self.apiKey = apiKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    /// Detects the MIME type of image data by inspecting the first bytes.
    private static func detectMediaType(for imageData: Data) -> String {
        guard imageData.count >= 4 else { return "image/jpeg" }
        let header = [UInt8](imageData.prefix(4))
        if header[0] == 0x89 && header[1] == 0x50 && header[2] == 0x4E && header[3] == 0x47 {
            return "image/png"
        }
        return "image/jpeg"
    }

    /// Analyzes images with streaming, matching ClaudeAPI's method signature
    /// so CompanionManager can call either interchangeably.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        // Pass the Supabase JWT when using the proxy Worker with auth enabled.
        // In proxy mode the Worker verifies the JWT and adds the real API key
        // server-side, so the bearer token replaces the API key in the header.
        bearerToken: String? = nil,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // Build messages array
        var messages: [[String: Any]] = []

        // System message
        messages.append([
            "role": "system",
            "content": systemPrompt
        ])

        // Conversation history
        for entry in conversationHistory {
            messages.append([
                "role": "user",
                "content": entry.userPlaceholder
            ])
            messages.append([
                "role": "assistant",
                "content": entry.assistantResponse
            ])
        }

        // Current user message with images
        var userContentBlocks: [[String: Any]] = []

        // Add images as image_url content blocks
        for image in images {
            let base64String = image.data.base64EncodedString()
            let mediaType = Self.detectMediaType(for: image.data)
            let dataURL = "data:\(mediaType);base64,\(base64String)"

            // Add the label as a text block before each image
            userContentBlocks.append([
                "type": "text",
                "text": image.label
            ])

            userContentBlocks.append([
                "type": "image_url",
                "image_url": [
                    "url": dataURL
                ]
            ])
        }

        // Add the user's text prompt
        userContentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])

        messages.append([
            "role": "user",
            "content": userContentBlocks
        ])

        let requestBody: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 1024,
            "stream": true
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let payloadSizeMB = Double(request.httpBody?.count ?? 0) / 1_000_000.0
        print("📤 OpenAI-compatible API request: \(String(format: "%.1f", payloadSizeMB))MB payload → \(apiURL.host ?? "")")

        // Stream the response using SSE
        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAICompatibleChatAPI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }

            // Parse the proxy Worker's structured 429 quota-exceeded body so the
            // UI can show a meaningful message instead of a generic error string.
            if httpResponse.statusCode == 429,
               let data = errorBody.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (json["error"] as? String) == "daily_limit_exceeded",
               let message = json["message"] as? String {
                let dailyLimit = json["daily_limit"] as? Int ?? 0
                let usedToday  = json["used_today"]  as? Int ?? 0
                throw ChatQuotaExceededError(
                    message:    message,
                    dailyLimit: dailyLimit,
                    usedToday:  usedToday
                )
            }

            throw NSError(domain: "OpenAICompatibleChatAPI", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "API error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        var fullText = ""

        for try await line in bytes.lines {
            try Task.checkCancellation()

            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))

            if jsonString == "[DONE]" { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any],
                  let content = delta["content"] as? String else {
                continue
            }

            fullText += content
            await onTextChunk(fullText)
        }

        let duration = Date().timeIntervalSince(startTime)
        print("📥 OpenAI-compatible API response: \(fullText.count) chars in \(String(format: "%.1f", duration))s")

        return (text: fullText, duration: duration)
    }
}
