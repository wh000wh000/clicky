//
//  ElementLocationDetector.swift
//  leanring-buddy
//
//  Detects the screen location of UI elements in screenshots for precise cursor pointing.
//  Supports two backends, auto-selected by model name:
//
//  • UI-TARS-1.5-7B (model name contains "ui-tars"):
//    OpenAI-compatible chat completions API (e.g. via OpenRouter). Specialized GUI
//    grounding model with ~61.6% ScreenSpot-Pro accuracy — 2.2× better than Claude
//    Computer Use. Outputs 0–1000 normalized bounding box coordinates.
//
//  • Claude Computer Use (all other models):
//    Anthropic-proprietary `computer_20251124` tool. Uses aspect-ratio-matched
//    resize to Anthropic's recommended resolutions for best coordinate accuracy.
//

import AppKit
import Foundation

class ElementLocationDetector {
    private let apiKey: String
    private let baseURL: String
    private let model: String
    private let session: URLSession

    /// Whether to use the UI-TARS backend (OpenAI-compatible).
    /// Detected by checking if the model name contains "ui-tars".
    private var isUITARSBackend: Bool {
        model.lowercased().contains("ui-tars")
    }

    // MARK: - Claude Computer Use Constants

    /// Anthropic-recommended resolutions for Computer Use, paired with their aspect ratios.
    /// We pick the one closest to the actual display aspect ratio to avoid distortion.
    /// Higher resolutions get downsampled by the API and degrade precision, so these
    /// are intentionally small.
    private static let supportedComputerUseResolutions: [(width: Int, height: Int, aspectRatio: Double)] = [
        (1024, 768,  1024.0 / 768.0),  // 4:3   = 1.333 (legacy displays)
        (1280, 800,  1280.0 / 800.0),  // 16:10  = 1.600 (MacBook Air, MacBook Pro, most Macs)
        (1366, 768,  1366.0 / 768.0)   // ~16:9  = 1.779 (external monitors, ultrawide fallback)
    ]

    // MARK: - Init

    /// - Parameters:
    ///   - baseURL: API base URL. For Claude Computer Use, the full messages endpoint
    ///     (e.g. `https://api.anthropic.com/v1/messages`). For UI-TARS, the OpenAI-
    ///     compatible base URL without path (e.g. `https://openrouter.ai/api/v1`).
    ///   - apiKey: API key for the chosen provider.
    ///   - model: Model ID. If it contains "ui-tars", the UI-TARS backend is used.
    init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Detects the screen location of a named UI element in the screenshot.
    ///
    /// - Parameters:
    ///   - screenshotData: JPEG or PNG screenshot data from ScreenCaptureKit.
    ///   - elementQuery: Short description of the element to find (e.g. "save button",
    ///     "search bar"). For UI-TARS this is used verbatim. For Claude it is embedded
    ///     in a broader prompt alongside the user's original question.
    ///   - displayWidthInPoints: Captured display width in screen points (not pixels).
    ///   - displayHeightInPoints: Captured display height in screen points (not pixels).
    ///
    /// - Returns: A `CGPoint` in display-local AppKit coordinates (bottom-left origin)
    ///   if an element was found, or `nil` if detection failed or no element was found.
    func detectElementLocation(
        screenshotData: Data,
        elementQuery: String,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int
    ) async -> CGPoint? {
        if isUITARSBackend {
            return await detectWithUITARS(
                screenshotData: screenshotData,
                elementQuery: elementQuery,
                displayWidthInPoints: displayWidthInPoints,
                displayHeightInPoints: displayHeightInPoints
            )
        } else {
            return await detectWithClaudeComputerUse(
                screenshotData: screenshotData,
                elementQuery: elementQuery,
                displayWidthInPoints: displayWidthInPoints,
                displayHeightInPoints: displayHeightInPoints
            )
        }
    }

    // MARK: - UI-TARS Backend

    /// Detects an element using UI-TARS-1.5-7B via OpenAI-compatible chat completions.
    ///
    /// UI-TARS outputs coordinates in `click(start_box='[x1, y1, x2, y2]')` format
    /// where all values are in 0–1000 range (normalized × 1000 of the image dimensions).
    /// The center of the bounding box, scaled to display points, is returned.
    private func detectWithUITARS(
        screenshotData: Data,
        elementQuery: String,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int
    ) async -> CGPoint? {
        // UI-TARS chat completions endpoint appended to base URL
        guard let endpointURL = URL(string: baseURL.trimmingCharacters(in: .init(charactersIn: "/")) + "/chat/completions") else {
            print("⚠️ ElementLocationDetector (UI-TARS): invalid base URL: \(baseURL)")
            return nil
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let mediaType = detectImageMediaType(for: screenshotData)
        let base64Screenshot = screenshotData.base64EncodedString()
        let imageDataURL = "data:\(mediaType);base64,\(base64Screenshot)"

        // UI-TARS was trained with this grounding prompt format.
        // The phrasing "what is the position of the element corresponding to the command"
        // matches its training distribution and yields the click(start_box=...) output format.
        let groundingPrompt = "In this UI screenshot, what is the position of the element corresponding to the command \"click \(elementQuery)\"?"

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image_url",
                            "image_url": ["url": imageDataURL]
                        ],
                        [
                            "type": "text",
                            "text": groundingPrompt
                        ]
                    ]
                ]
            ]
        ]

        do {
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            request.httpBody = bodyData

            let payloadMB = Double(bodyData.count) / 1_048_576.0
            print("🎯 ElementLocationDetector (UI-TARS): querying \"\(elementQuery)\", payload \(String(format: "%.1f", payloadMB))MB")

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
                print("⚠️ ElementLocationDetector (UI-TARS): API error \(statusCode): \(errorBody.prefix(300))")
                return nil
            }

            return parseUITARSCoordinates(
                responseData: data,
                displayWidthInPoints: displayWidthInPoints,
                displayHeightInPoints: displayHeightInPoints
            )

        } catch {
            print("⚠️ ElementLocationDetector (UI-TARS): request failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Parses UI-TARS's `click(start_box='[x1, y1, x2, y2]')` response and converts
    /// the bounding box center to display-local AppKit coordinates.
    ///
    /// UI-TARS outputs coordinates in 0–1000 range normalized by image dimensions.
    /// Converting to display points: `(coord / 1000) * displayDimension`.
    private func parseUITARSCoordinates(
        responseData: Data,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int
    ) -> CGPoint? {
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let responseText = message["content"] as? String else {
            print("⚠️ ElementLocationDetector (UI-TARS): could not parse response JSON")
            return nil
        }

        print("🎯 ElementLocationDetector (UI-TARS): raw response: \(responseText.prefix(200))")

        // Match click(start_box='[x1, y1, x2, y2]') or click(start_box='(x1, y1, x2, y2)')
        // Both bracket styles appear in UI-TARS outputs depending on training variation.
        let pattern = #"click\(start_box='[\[\(]([\d.]+),\s*([\d.]+),\s*([\d.]+),\s*([\d.]+)[\]\)]'\)"#

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              match.numberOfRanges == 5,
              let x1Range = Range(match.range(at: 1), in: responseText),
              let y1Range = Range(match.range(at: 2), in: responseText),
              let x2Range = Range(match.range(at: 3), in: responseText),
              let y2Range = Range(match.range(at: 4), in: responseText) else {
            print("⚠️ ElementLocationDetector (UI-TARS): no click coordinate found in response")
            return nil
        }

        guard let x1 = Double(responseText[x1Range]),
              let y1 = Double(responseText[y1Range]),
              let x2 = Double(responseText[x2Range]),
              let y2 = Double(responseText[y2Range]) else {
            print("⚠️ ElementLocationDetector (UI-TARS): could not parse coordinate values")
            return nil
        }

        // Center of the bounding box in 0–1000 range
        let centerX = (x1 + x2) / 2.0
        let centerY = (y1 + y2) / 2.0

        // Normalize to 0–1 range, then scale to display point dimensions
        let displayLocalX = (centerX / 1000.0) * Double(displayWidthInPoints)
        let displayLocalYTopLeftOrigin = (centerY / 1000.0) * Double(displayHeightInPoints)

        // Convert from top-left origin (UI-TARS / CoreGraphics) to bottom-left origin (AppKit)
        let displayLocalYBottomLeftOrigin = Double(displayHeightInPoints) - displayLocalYTopLeftOrigin

        print("🎯 ElementLocationDetector (UI-TARS): box (\(Int(x1)),\(Int(y1)),\(Int(x2)),\(Int(y2))) " +
              "→ center (\(Int(centerX)),\(Int(centerY)))/1000 " +
              "→ display point (\(Int(displayLocalX)), \(Int(displayLocalYBottomLeftOrigin))) AppKit")

        return CGPoint(x: displayLocalX, y: displayLocalYBottomLeftOrigin)
    }

    // MARK: - Claude Computer Use Backend

    /// Detects an element using Claude's Computer Use API.
    ///
    /// The `computer_20251124` tool activates Claude's specialized pixel-counting
    /// training. We pick the Anthropic-recommended resolution closest to the display's
    /// actual aspect ratio to avoid distorting the image Claude sees.
    private func detectWithClaudeComputerUse(
        screenshotData: Data,
        elementQuery: String,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int
    ) async -> CGPoint? {
        let computerUseResolution = bestComputerUseResolution(
            forDisplayWidth: displayWidthInPoints,
            displayHeight: displayHeightInPoints
        )

        print("🎯 ElementLocationDetector (Claude): display is \(displayWidthInPoints)x\(displayHeightInPoints) " +
              "(ratio \(String(format: "%.3f", Double(displayWidthInPoints) / Double(displayHeightInPoints)))), " +
              "using Computer Use resolution \(computerUseResolution.width)x\(computerUseResolution.height)")

        guard let resizedScreenshotData = resizeScreenshotForComputerUse(
            originalImageData: screenshotData,
            targetWidth: computerUseResolution.width,
            targetHeight: computerUseResolution.height
        ) else {
            print("⚠️ ElementLocationDetector (Claude): failed to resize screenshot")
            return nil
        }

        guard let claudeCoordinate = await callClaudeComputerUseAPI(
            resizedScreenshotData: resizedScreenshotData,
            elementQuery: elementQuery,
            declaredDisplayWidth: computerUseResolution.width,
            declaredDisplayHeight: computerUseResolution.height
        ) else {
            return nil
        }

        // Clamp coordinates to the valid range — Claude occasionally returns values
        // slightly outside the declared display dimensions.
        let clampedX = max(0, min(claudeCoordinate.x, CGFloat(computerUseResolution.width)))
        let clampedY = max(0, min(claudeCoordinate.y, CGFloat(computerUseResolution.height)))

        // Scale from Computer Use resolution back to actual display point dimensions
        let scaledX = (clampedX / CGFloat(computerUseResolution.width)) * CGFloat(displayWidthInPoints)
        let scaledYTopLeftOrigin = (clampedY / CGFloat(computerUseResolution.height)) * CGFloat(displayHeightInPoints)

        // Convert from top-left origin (Computer Use) to bottom-left origin (AppKit)
        let scaledYBottomLeftOrigin = CGFloat(displayHeightInPoints) - scaledYTopLeftOrigin

        print("🎯 ElementLocationDetector (Claude): mapped (\(Int(clampedX)), \(Int(clampedY))) in " +
              "\(computerUseResolution.width)x\(computerUseResolution.height) → " +
              "(\(Int(scaledX)), \(Int(scaledYBottomLeftOrigin))) display-local AppKit")

        return CGPoint(x: scaledX, y: scaledYBottomLeftOrigin)
    }

    /// Picks the Anthropic-recommended Computer Use resolution whose aspect ratio
    /// is closest to the actual display, minimizing image distortion.
    private func bestComputerUseResolution(
        forDisplayWidth displayWidth: Int,
        displayHeight: Int
    ) -> (width: Int, height: Int) {
        let displayAspectRatio = Double(displayWidth) / Double(max(1, displayHeight))

        var bestWidth = 1280
        var bestHeight = 800
        var smallestAspectRatioDifference = Double.greatestFiniteMagnitude

        for resolution in Self.supportedComputerUseResolutions {
            let difference = abs(displayAspectRatio - resolution.aspectRatio)
            if difference < smallestAspectRatioDifference {
                smallestAspectRatioDifference = difference
                bestWidth = resolution.width
                bestHeight = resolution.height
            }
        }

        return (width: bestWidth, height: bestHeight)
    }

    /// Calls the Claude Computer Use API and returns the raw coordinate in the
    /// declared Computer Use resolution space, or nil if detection failed.
    private func callClaudeComputerUseAPI(
        resizedScreenshotData: Data,
        elementQuery: String,
        declaredDisplayWidth: Int,
        declaredDisplayHeight: Int
    ) async -> CGPoint? {
        guard let endpointURL = URL(string: baseURL) else {
            print("⚠️ ElementLocationDetector (Claude): invalid URL: \(baseURL)")
            return nil
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The beta header activates Computer Use capabilities and Claude's specialized
        // pixel-counting training that makes coordinate detection accurate.
        request.setValue("computer-use-2025-11-24", forHTTPHeaderField: "anthropic-beta")

        let mediaType = detectImageMediaType(for: resizedScreenshotData)
        let base64Screenshot = resizedScreenshotData.base64EncodedString()

        let userPrompt = """
        Locate the UI element described as: "\(elementQuery)"

        Look at the screenshot. Click on that element. If no such element is visible, respond with text saying "no specific element".
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "tools": [
                [
                    "type": "computer_20251124",
                    "name": "computer",
                    "display_width_px": declaredDisplayWidth,
                    "display_height_px": declaredDisplayHeight
                ]
            ],
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": mediaType,
                                "data": base64Screenshot
                            ]
                        ],
                        [
                            "type": "text",
                            "text": userPrompt
                        ]
                    ]
                ]
            ]
        ]

        do {
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            request.httpBody = bodyData

            let payloadMB = Double(bodyData.count) / 1_048_576.0
            print("🎯 ElementLocationDetector (Claude): sending \(String(format: "%.1f", payloadMB))MB request " +
                  "(declared \(declaredDisplayWidth)x\(declaredDisplayHeight))")

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
                print("⚠️ ElementLocationDetector (Claude): API error \(statusCode): \(errorBody.prefix(200))")
                return nil
            }

            return parseClaudeComputerUseCoordinate(from: data)

        } catch {
            print("⚠️ ElementLocationDetector (Claude): request failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Parses Claude's Computer Use API response to extract click coordinates.
    /// Claude returns a `tool_use` content block with `{"action": "left_click", "coordinate": [x, y]}`.
    private func parseClaudeComputerUseCoordinate(from data: Data) -> CGPoint? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentBlocks = json["content"] as? [[String: Any]] else {
            print("⚠️ ElementLocationDetector (Claude): could not parse response JSON")
            return nil
        }

        for block in contentBlocks {
            guard let blockType = block["type"] as? String,
                  blockType == "tool_use",
                  let input = block["input"] as? [String: Any],
                  let coordinate = input["coordinate"] as? [NSNumber],
                  coordinate.count == 2 else {
                continue
            }

            let x = CGFloat(coordinate[0].doubleValue)
            let y = CGFloat(coordinate[1].doubleValue)
            print("🎯 ElementLocationDetector (Claude): raw coordinate (\(Int(x)), \(Int(y)))")
            return CGPoint(x: x, y: y)
        }

        // No tool_use block — Claude responded with text (no element found)
        print("🎯 ElementLocationDetector (Claude): no element detected")
        return nil
    }

    // MARK: - Shared Helpers

    /// Resizes screenshot data to the specified resolution using exact-pixel-dimension
    /// NSBitmapImageRep, bypassing NSImage's Retina-aware coordinate system.
    ///
    /// **Critical Retina fix**: On Retina displays (2x backing scale), using
    /// `NSImage.lockFocus()` creates a bitmap at 2× the declared size. This causes
    /// the sent image to be 2× larger than the resolution declared in the Computer
    /// Use tool definition, making Claude's pixel-counting return wrong-scale coordinates.
    private func resizeScreenshotForComputerUse(
        originalImageData: Data,
        targetWidth: Int,
        targetHeight: Int
    ) -> Data? {
        guard let originalImage = NSImage(data: originalImageData) else { return nil }

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        bitmapRep.size = NSSize(width: targetWidth, height: targetHeight)

        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSGraphicsContext.current = graphicsContext
        graphicsContext?.imageInterpolation = .high
        originalImage.draw(
            in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: NSRect(origin: .zero, size: originalImage.size),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// Detects MIME type by inspecting the first bytes of image data.
    private func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        return "image/jpeg"
    }
}
