//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        let captureStartTime = CFAbsoluteTimeGetCurrent()

        // Capture all screens in parallel using TaskGroup for faster multi-monitor capture.
        // Each display is captured independently, so no ordering dependency exists.
        let capturedScreens: [CompanionScreenCapture] = try await withThrowingTaskGroup(
            of: CompanionScreenCapture?.self
        ) { group in
            for (displayIndex, display) in sortedDisplays.enumerated() {
                let displayFrame: CGRect
                if let nsScreen = nsScreenByDisplayID[display.displayID] {
                    displayFrame = nsScreen.frame
                } else {
                    let primaryScreenHeight = NSScreen.screens.first?.frame.height
                        ?? CGFloat(display.height)
                    let appKitOriginY = primaryScreenHeight
                        - display.frame.origin.y
                        - CGFloat(display.height)
                    displayFrame = CGRect(
                        x: display.frame.origin.x,
                        y: appKitOriginY,
                        width: CGFloat(display.width),
                        height: CGFloat(display.height)
                    )
                    print("⚠️ CompanionScreenCapture: display \(display.displayID) not found in NSScreen lookup — " +
                          "converted CG frame to AppKit: \(displayFrame)")
                }
                let isCursorScreen = displayFrame.contains(mouseLocation)
                let totalDisplayCount = sortedDisplays.count

                // Capture the excluded windows list before entering the sendable closure
                let excludedWindows = ownAppWindows

                group.addTask {
                    let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

                    let configuration = SCStreamConfiguration()
                    let maxDimension = 1280
                    let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
                    if display.width >= display.height {
                        configuration.width = maxDimension
                        configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
                    } else {
                        configuration.height = maxDimension
                        configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
                    }

                    let cgImage = try await SCScreenshotManager.captureImage(
                        contentFilter: filter,
                        configuration: configuration
                    )

                    guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                        return nil
                    }

                    let screenLabel: String
                    if totalDisplayCount == 1 {
                        screenLabel = "user's screen (cursor is here)"
                    } else if isCursorScreen {
                        screenLabel = "screen \(displayIndex + 1) of \(totalDisplayCount) — cursor is on this screen (primary focus)"
                    } else {
                        screenLabel = "screen \(displayIndex + 1) of \(totalDisplayCount) — secondary screen"
                    }

                    return CompanionScreenCapture(
                        imageData: jpegData,
                        label: screenLabel,
                        isCursorScreen: isCursorScreen,
                        displayWidthInPoints: Int(displayFrame.width),
                        displayHeightInPoints: Int(displayFrame.height),
                        displayFrame: displayFrame,
                        screenshotWidthInPixels: configuration.width,
                        screenshotHeightInPixels: configuration.height
                    )
                }
            }

            // Collect results, preserving the original display order (cursor screen first)
            var results: [CompanionScreenCapture] = []
            for try await capture in group {
                if let capture { results.append(capture) }
            }
            // Re-sort so cursor screen is first (TaskGroup returns results in completion order)
            return results.sorted { $0.isCursorScreen && !$1.isCursorScreen }
        }

        let captureElapsed = (CFAbsoluteTimeGetCurrent() - captureStartTime) * 1000
        print("📸 Screen capture: \(capturedScreens.count) screen(s) in \(Int(captureElapsed))ms")

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }
}
