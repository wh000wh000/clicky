//
//  SceneContextDetector.swift
//  leanring-buddy
//
//  Detects the user's current scene context — which app is in the foreground
//  and what window is focused — to customize quick action presets and enrich
//  Claude's system prompt with app-aware context.
//

import AppKit

// MARK: - Scene Context

struct SceneContext {
    let frontmostAppName: String?
    let frontmostAppBundleIdentifier: String?
    let focusedWindowTitle: String?

    /// One-line summary appended to Claude's system prompt so it knows
    /// which app and window the user is working in. Returns an empty
    /// string when no context is available (safe to append unconditionally).
    var contextSummaryForSystemPrompt: String {
        var parts: [String] = []

        if let appName = frontmostAppName {
            parts.append("the user's frontmost app is \(appName)")
        }
        if let windowTitle = focusedWindowTitle, !windowTitle.isEmpty {
            parts.append("the focused window title is \"\(windowTitle)\"")
        }

        guard !parts.isEmpty else { return "" }
        return "\n\ncontext: \(parts.joined(separator: ", "))."
    }
}

// MARK: - Scene Context Detector

struct SceneContextDetector {

    /// Captures a snapshot of the user's current scene: frontmost app name,
    /// bundle identifier, and focused window title (via Accessibility API).
    /// All fields are optional — returns gracefully if detection fails.
    static func captureCurrentSceneContext() -> SceneContext {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return SceneContext(
                frontmostAppName: nil,
                frontmostAppBundleIdentifier: nil,
                focusedWindowTitle: nil
            )
        }

        let appName = frontApp.localizedName
        let bundleIdentifier = frontApp.bundleIdentifier

        // Attempt to get the focused window title via AX API.
        // This requires Accessibility permission, which Clicky already requests.
        let focusedWindowTitle = windowTitleForApplication(processIdentifier: frontApp.processIdentifier)

        return SceneContext(
            frontmostAppName: appName,
            frontmostAppBundleIdentifier: bundleIdentifier,
            focusedWindowTitle: focusedWindowTitle
        )
    }

    /// Returns app-specific quick action presets when the frontmost app is
    /// recognized. Mixes 2 app-specific presets with 2 defaults for a
    /// balanced set. Falls back to full defaults for unrecognized apps.
    static func sceneAwareQuickActionPresets(
        for sceneContext: SceneContext,
        defaultPresets: [QuickActionPreset]
    ) -> [QuickActionPreset] {
        guard let bundleIdentifier = sceneContext.frontmostAppBundleIdentifier else {
            return defaultPresets
        }

        let appSpecificPresets: [QuickActionPreset]? = {
            switch bundleIdentifier {
            // Code editors
            case "com.apple.dt.Xcode":
                return [
                    QuickActionPreset(label: String(localized: "Explain error"), iconName: "exclamationmark.triangle", promptText: "Look at the error or warning on my screen in Xcode. Explain what it means and how to fix it."),
                    QuickActionPreset(label: String(localized: "Review code"), iconName: "eye", promptText: "Review the code visible on my screen. Point out any bugs, improvements, or best practices I should follow."),
                ]
            case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders":
                return [
                    QuickActionPreset(label: String(localized: "Explain error"), iconName: "exclamationmark.triangle", promptText: "Look at the error or warning on my screen in VS Code. Explain what it means and how to fix it."),
                    QuickActionPreset(label: String(localized: "Review code"), iconName: "eye", promptText: "Review the code visible on my screen. Point out any bugs, improvements, or best practices I should follow."),
                ]
            // Browsers
            case "com.apple.Safari", "com.google.Chrome", "com.brave.Browser",
                 "org.mozilla.firefox", "com.microsoft.edgemac":
                return [
                    QuickActionPreset(label: String(localized: "Summarize page"), iconName: "doc.text", promptText: "Summarize the main content of the web page visible on my screen. Be concise but capture the key points."),
                    QuickActionPreset(label: String(localized: "Explain this"), iconName: "questionmark.circle", promptText: "Explain what I'm looking at on this web page. What is the main content about?"),
                ]
            // Video editing
            case "com.adobe.premierepro", "com.apple.FinalCut":
                return [
                    QuickActionPreset(label: String(localized: "Edit suggestion"), iconName: "film", promptText: "Look at the video editing timeline on my screen. Suggest improvements to the current edit, transitions, or pacing."),
                    QuickActionPreset(label: String(localized: "Color advice"), iconName: "paintpalette", promptText: "Look at the color grading or correction on my screen. Suggest improvements to make the footage look better."),
                ]
            // Design tools
            case "com.figma.Desktop", "com.bohemiancoding.sketch3":
                return [
                    QuickActionPreset(label: String(localized: "Design feedback"), iconName: "paintbrush", promptText: "Look at the design on my screen. Give feedback on layout, spacing, typography, and visual hierarchy."),
                    QuickActionPreset(label: String(localized: "Accessibility check"), iconName: "accessibility", promptText: "Check the design on my screen for accessibility issues — contrast ratios, text size, touch targets, and color usage."),
                ]
            // Game engines
            case _ where bundleIdentifier.hasPrefix("com.unity3d"):
                return [
                    QuickActionPreset(label: String(localized: "Debug scene"), iconName: "ladybug", promptText: "Look at my Unity editor. Help me debug what's visible — check the scene, inspector, or console for issues."),
                    QuickActionPreset(label: String(localized: "Optimize"), iconName: "bolt", promptText: "Look at my Unity scene and suggest performance optimizations based on what you can see."),
                ]
            // Terminal
            case "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                 "io.alacritty", "com.mitchellh.ghostty":
                return [
                    QuickActionPreset(label: String(localized: "Explain output"), iconName: "terminal", promptText: "Explain the terminal output on my screen. What does it mean and what should I do next?"),
                    QuickActionPreset(label: String(localized: "Fix command"), iconName: "wrench", promptText: "Look at the command or error in my terminal. Suggest the correct command or fix."),
                ]
            default:
                return nil
            }
        }()

        guard let appSpecificPresets else {
            return defaultPresets
        }

        // Mix: 2 app-specific presets + first 2 defaults for a balanced set
        let defaultSubset = Array(defaultPresets.prefix(2))
        return appSpecificPresets + defaultSubset
    }

    // MARK: - Private

    /// Reads the focused window title of an application via AX API.
    /// Returns nil if the title can't be read (no focused window, no AX
    /// permission, or the app doesn't expose window titles).
    private static func windowTitleForApplication(processIdentifier: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(processIdentifier)

        var focusedWindowValue: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )
        guard focusedResult == .success, let focusedWindow = focusedWindowValue else {
            return nil
        }

        var titleValue: AnyObject?
        let titleResult = AXUIElementCopyAttributeValue(
            focusedWindow as! AXUIElement,
            kAXTitleAttribute as CFString,
            &titleValue
        )
        guard titleResult == .success, let title = titleValue as? String else {
            return nil
        }

        return title
    }
}
