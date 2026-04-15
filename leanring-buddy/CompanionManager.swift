//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

struct QuickActionPreset: Identifiable {
    let id: String
    let label: String
    let iconName: String
    let promptText: String
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    /// True after the proxy Worker returns 429 daily_limit_exceeded.
    /// Cleared automatically when the user starts the next interaction.
    @Published private(set) var isQuotaExceeded: Bool = false
    /// A user-facing error message from the last API call, e.g. "API Key 未配置"
    /// Cleared automatically when the user starts the next interaction.
    @Published private(set) var lastAPIErrorMessage: String?
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let onboardingGuideManager = OnboardingGuideManager()
    /// Floating overlay that displays streaming response text near the cursor
    /// so the user can read Claude's explanation alongside the TTS audio.
    let responseOverlayManager = CompanionResponseOverlayManager()

    /// Manages the cursor-following text input popup (Cmd+Shift+Space).
    lazy var cursorInputPopupManager: CursorInputPopupManager = {
        CursorInputPopupManager(companionManager: self)
    }()

    // MARK: - API Clients (configurable via APIConfiguration)

    private lazy var claudeAPI: ClaudeAPI = {
        let config = APIConfiguration.shared
        return ClaudeAPI(
            proxyURL: config.resolvedChatURL,
            model: selectedModel,
            apiKey: config.chatAPIMode == .direct ? config.chatAPIKey : nil
        )
    }()

    private lazy var openAICompatibleChatAPI: OpenAICompatibleChatAPI = {
        let config = APIConfiguration.shared
        return OpenAICompatibleChatAPI(
            baseURL: config.resolvedChatURL,
            model: selectedModel,
            apiKey: config.chatAPIKey
        )
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        let config = APIConfiguration.shared
        return ElevenLabsTTSClient(
            proxyURL: config.resolvedTTSURL,
            apiKey: config.ttsAPIKey.isEmpty ? nil : config.ttsAPIKey,
            model: config.ttsAPIModel
        )
    }()

    private lazy var openAICompatibleTTSClient: OpenAICompatibleTTSClient = {
        let config = APIConfiguration.shared
        return OpenAICompatibleTTSClient(
            baseURL: config.resolvedTTSURL,
            apiKey: config.ttsAPIKey,
            model: config.ttsAPIModel,
            voice: config.ttsAPIVoiceID.isEmpty ? "alloy" : config.ttsAPIVoiceID
        )
    }()

    /// Optional element location detector for precise UI element coordinate detection.
    /// Lazily initialized from APIConfiguration on first use; replaced by reloadAPIClients()
    /// whenever the user changes settings. Non-nil only when an API key and base URL
    /// are both configured.
    private lazy var elementLocationDetector: ElementLocationDetector? = {
        let config = APIConfiguration.shared
        let apiKey = config.elementDetectionAPIKey
        guard !apiKey.isEmpty, !config.elementDetectionBaseURL.isEmpty else { return nil }
        return ElementLocationDetector(
            baseURL: config.elementDetectionBaseURL,
            apiKey: apiKey,
            model: config.elementDetectionModel
        )
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var textInputShortcutCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var whisperKitModelStateCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The chat model used for voice/text responses. Persisted to UserDefaults.
    /// Falls back to APIConfiguration's current model when no prior selection exists.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel")
        ?? APIConfiguration.shared.chatAPIModel

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
        openAICompatibleChatAPI.model = model
        APIConfiguration.shared.chatAPIModel = model
    }

    /// Default quick action presets shown in the panel and cursor popup.
    /// Each preset maps a short label to a full prompt sent to Claude.
    /// Computed so labels re-resolve against `appLocale` when the user switches language.
    var quickActionPresets: [QuickActionPreset] {
        [
            QuickActionPreset(
                id: "explain",
                label: String(localized: "Explain this", locale: appLocale),
                iconName: "questionmark.circle",
                promptText: "Look at where my cursor is on screen and explain what's there. Focus on the content near my cursor position — that's what I'm looking at."
            ),
            QuickActionPreset(
                id: "summarize",
                label: String(localized: "Summarize", locale: appLocale),
                iconName: "doc.text",
                promptText: "Summarize the main content visible on my screen. Be concise but capture the key points."
            ),
            QuickActionPreset(
                id: "help-write",
                label: String(localized: "Help me write", locale: appLocale),
                iconName: "pencil.line",
                promptText: "Look at what I'm writing on screen and help me improve it. Suggest better wording, fix any issues, and make it clearer."
            ),
            QuickActionPreset(
                id: "debug",
                label: String(localized: "Debug this", locale: appLocale),
                iconName: "ladybug",
                promptText: "Look at the code or error near my cursor on screen. Explain what's wrong and how to fix it."
            ),
        ]
    }

    /// Scene-aware quick action presets that adapt to the frontmost app.
    /// Refreshed each time the cursor input popup is shown.
    @Published private(set) var sceneAwareQuickActionPresets: [QuickActionPreset] = []

    /// Captures the current scene and regenerates app-specific quick action
    /// presets. Called by CursorInputPopupManager before showing the popup.
    func refreshSceneAwarePresets() {
        let sceneContext = SceneContextDetector.captureCurrentSceneContext()
        sceneAwareQuickActionPresets = SceneContextDetector.sceneAwareQuickActionPresets(
            for: sceneContext,
            defaultPresets: quickActionPresets
        )
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        // Validate selectedModel against the current API provider before any
        // API client is lazily initialized. Without this, a stale model ID
        // from a previous provider (e.g. "claude-sonnet-4-6" after switching
        // to SiliconFlow) would cause every request to fail.
        let pickerModels = APIConfiguration.shared.panelPickerModels
        if !pickerModels.contains(where: { $0.id == selectedModel }) {
            selectedModel = APIConfiguration.shared.chatAPIModel
            UserDefaults.standard.set(selectedModel, forKey: "selectedClaudeModel")
        }

        refreshAllPermissions()
        print("🔑 Clicky start — CGPreflight: \(CGPreflightScreenCaptureAccess()), AX: \(AXIsProcessTrusted()), screen: \(hasScreenRecordingPermission), screenContent: \(hasScreenContentPermission), mic: \(hasMicrophonePermission), onboarded: \(hasCompletedOnboarding)")

        // Validate screen capture permission with an actual capture attempt.
        // CGPreflightScreenCaptureAccess() returns false-negatives on macOS 15
        // even when ScreenCaptureKit works fine. A real capture is the only
        // reliable check.
        validateScreenCapturePermissionWithRealCapture()

        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindWhisperKitModelState()
        bindShortcutTransitions()
        bindTextInputShortcut()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // Rebuild overlay windows whenever the display configuration changes
        // (monitor hotplug, arrangement change, resolution change). Without this,
        // a screen added after app launch never gets an overlay window.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard self.isOverlayVisible else { return }
            // Recreate all overlay windows for the current screen layout.
            // hasShownOverlayBefore stays true so the welcome animation doesn't replay.
            self.overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        }

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        hasCompletedOnboarding = true
        ClickyAnalytics.trackOnboardingStarted()

        // Show the overlay — isFirstAppearance triggers the welcome animation
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true

        // Start the step-by-step text guide. Pass current permission state
        // so the welcome step auto-advances when permissions are already granted
        // (e.g. after resetting onboarding for testing).
        onboardingGuideManager.startGuide(allPermissionsGranted: allPermissionsGranted)
    }

    /// Resets onboarding state so the user can re-experience the tutorial.
    /// Hides the overlay and resets the guide steps back to the beginning.
    func resetOnboarding() {
        hasCompletedOnboarding = false
        onboardingGuideManager.resetGuide()
        overlayWindowManager.hideOverlay()
        isOverlayVisible = false
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        textInputShortcutCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        cursorInputPopupManager.dismissPopup()
    }

    /// Recreates API client instances after the user changes settings in
    /// APISettingsView. Called when the settings sheet is dismissed.
    func reloadAPIClients() {
        let config = APIConfiguration.shared

        // Ensure selectedModel is valid for the current API format.
        // If it doesn't match any picker model, reset to the config's default.
        let pickerModels = config.panelPickerModels
        if !pickerModels.contains(where: { $0.id == selectedModel }) {
            selectedModel = config.chatAPIModel
            UserDefaults.standard.set(selectedModel, forKey: "selectedClaudeModel")
        }

        claudeAPI = ClaudeAPI(
            proxyURL: config.resolvedChatURL,
            model: selectedModel,
            apiKey: config.chatAPIMode == .direct ? config.chatAPIKey : nil
        )
        openAICompatibleChatAPI = OpenAICompatibleChatAPI(
            baseURL: config.resolvedChatURL,
            model: selectedModel,
            apiKey: config.chatAPIKey
        )
        elevenLabsTTSClient = ElevenLabsTTSClient(
            proxyURL: config.resolvedTTSURL,
            apiKey: config.ttsAPIKey.isEmpty ? nil : config.ttsAPIKey,
            model: config.ttsAPIModel
        )
        openAICompatibleTTSClient = OpenAICompatibleTTSClient(
            baseURL: config.resolvedTTSURL,
            apiKey: config.ttsAPIKey,
            model: config.ttsAPIModel,
            voice: config.ttsAPIVoiceID.isEmpty ? "alloy" : config.ttsAPIVoiceID
        )

        // Recreate element location detector when settings change.
        // Only active when the user has provided an API key and base URL.
        let elementDetectionAPIKey = config.elementDetectionAPIKey
        if !elementDetectionAPIKey.isEmpty && !config.elementDetectionBaseURL.isEmpty {
            elementLocationDetector = ElementLocationDetector(
                baseURL: config.elementDetectionBaseURL,
                apiKey: elementDetectionAPIKey,
                model: config.elementDetectionModel
            )
        } else {
            elementLocationDetector = nil
        }

        // Auto-sync CosyVoice2 voice ID to the current language when the user is already
        // using a known language variant. Does not override custom / non-standard voice IDs.
        let knownCosyVoiceIDs = Set(AppLanguage.allCases.map { $0.cosyVoice2VoiceID })
        if config.ttsProvider == .openaiCompatible && knownCosyVoiceIDs.contains(config.ttsAPIVoiceID) {
            config.ttsAPIVoiceID = LocalizationManager.shared.currentLanguage.cosyVoice2VoiceID
        }
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadScreenContent = hasScreenContentPermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        // Screen recording permission is validated at startup by a real
        // capture test (validateScreenCapturePermissionWithRealCapture).
        // CGPreflightScreenCaptureAccess() is unreliable on macOS 15 (false
        // negatives), so we only let it UPGRADE the state (false → true),
        // never downgrade (true → false) if the real capture already confirmed.
        if !hasScreenRecordingPermission {
            hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        }

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on ANY change (including screenContent)
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission
            || previouslyHadScreenContent != hasScreenContentPermission {
            print("🔑 Permissions changed — accessibility: \(previouslyHadAccessibility)→\(hasAccessibilityPermission), screen: \(previouslyHadScreenRecording)→\(hasScreenRecordingPermission), mic: \(previouslyHadMicrophone)→\(hasMicrophonePermission), screenContent: \(previouslyHadScreenContent)→\(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is determined by the real capture test
        // at startup (validateScreenCapturePermissionWithRealCapture).
        // No UserDefaults fallback — stale caches caused false positives
        // across Xcode rebuilds where the TCC entry no longer matched.

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
            onboardingGuideManager.notifyEvent(.allPermissionsGranted)

            // If the user already completed onboarding and cursor is enabled, show the
            // overlay immediately now that all four permissions are satisfied. Without
            // this, a returning user who re-granted permissions (e.g., after a new build
            // invalidated TCC) would need to restart the app to see the cursor.
            if hasCompletedOnboarding && isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — \(image.width)x\(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error.localizedDescription)")
                // ScreenCaptureKit throws -3801 when the underlying screen
                // recording TCC isn't granted for this build's code signature.
                // Reset in-memory permission state and prompt for Screen Recording.
                await MainActor.run {
                    isRequestingScreenContent = false
                    hasScreenRecordingPermission = false
                    hasScreenContentPermission = false
                    WindowPositionManager.requestScreenRecordingPermission()
                }
            }
        }
    }

    /// Performs a real lightweight screen capture at startup to determine
    /// whether ScreenCaptureKit actually works for this build. This is the
    /// only reliable permission check on macOS 15, where
    /// CGPreflightScreenCaptureAccess() returns false-negatives even when
    /// the user has already granted Screen Recording in System Settings.
    ///
    /// If the capture succeeds, both hasScreenRecordingPermission and
    /// hasScreenContentPermission are set to true (regardless of what
    /// CGPreflight says). If it fails with -3801, both are set to false
    /// so the panel shows Grant buttons.
    private func validateScreenCapturePermissionWithRealCapture() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { return }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 160
                config.height = 120
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let didCapture = image.width > 0 && image.height > 0

                if didCapture {
                    // Real capture works — trust this over CGPreflight.
                    // No UserDefaults persistence — re-validated each launch.
                    hasScreenRecordingPermission = true
                    hasScreenContentPermission = true
                    print("🔑 Screen capture validated — permission granted (CGPreflight was \(CGPreflightScreenCaptureAccess()))")

                    // Show overlay if all other conditions are met
                    if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled && !isOverlayVisible {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                // Real capture failed — permission is genuinely not granted.
                print("🔑 Screen capture validation failed — \(error.localizedDescription)")
                hasScreenRecordingPermission = false
                hasScreenContentPermission = false
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    // MARK: - WhisperKit Forwarding

    /// Starts the WhisperKit model download. Forwarded to WhisperKitModelManager.
    func startWhisperKitDownload() {
        WhisperKitModelManager.shared.startDownload()
    }

    /// Cancels an in-progress WhisperKit model download.
    func cancelWhisperKitDownload() {
        WhisperKitModelManager.shared.cancelDownload()
    }

    private func bindWhisperKitModelState() {
        whisperKitModelStateCancellable = WhisperKitModelManager.shared.$modelState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                guard let self else { return }
                // When the model finishes downloading, automatically upgrade
                // the transcription provider so push-to-talk uses WhisperKit
                // without requiring an app restart.
                if case .ready = newState {
                    buddyDictationManager.reloadTranscriptionProvider()
                }
            }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func bindTextInputShortcut() {
        textInputShortcutCancellable = globalPushToTalkShortcutMonitor
            .textInputShortcutPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.cursorInputPopupManager.showPopupAtCursor()
                self.onboardingGuideManager.notifyEvent(.cursorPopupOpened)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            openAICompatibleTTSClient.stopPlayback()
            clearDetectedElementLocation()

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    /// The core system prompt without a language instruction. The computed property
    /// `companionVoiceResponseSystemPrompt` appends the active language directive at runtime.
    private static let companionVoiceResponseBaseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen. your reply will be spoken aloud via text-to-speech AND displayed as text near the cursor. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write naturally for speech — short sentences, no abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - since your response is also displayed as text, use paragraph breaks between distinct ideas so it's easy to scan visually. still no bullet points, lists, markdown, or formatting — just natural paragraphs.
    - the screenshot label includes the cursor's pixel position. this tells you what area of the screen the user is focused on. when they ask you to explain or look at something, prioritize the content near their cursor — that's what they're looking at. describe the broader screen context only if it adds useful information.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button").

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    """

    /// The effective system prompt, appending a language instruction so Claude always
    /// responds in the language selected in General Settings.
    private var companionVoiceResponseSystemPrompt: String {
        let languageInstruction = LocalizationManager.shared.currentLanguage.claudeResponseLanguageInstruction
        return Self.companionVoiceResponseBaseSystemPrompt + "\n\nlanguage: \(languageInstruction)"
    }

    // MARK: - AI Response Pipeline

    /// Sends a text query to Claude with a screenshot of the user's screen(s).
    /// This is the unified entry point for ALL non-voice input methods — typed
    /// text and preset quick actions all flow through here. Dismisses the menu
    /// bar panel, cancels any in-progress response, and shows the transient
    /// cursor overlay before starting.
    func sendTextQueryToClaudeWithScreenshot(textQuery: String) {
        let trimmedTextQuery = textQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTextQuery.isEmpty else { return }

        // Dismiss the menu bar panel so it doesn't cover the screen
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Cancel any in-progress response and TTS from a previous utterance
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        clearDetectedElementLocation()

        // Cancel any pending transient hide so the overlay stays visible
        transientHideTask?.cancel()
        transientHideTask = nil

        // If the cursor is hidden, bring it back transiently for this interaction
        if !isClickyCursorEnabled && !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        ClickyAnalytics.trackUserMessageSent(transcript: trimmedTextQuery)
        onboardingGuideManager.notifyEvent(.textQuerySent)
        sendTranscriptToClaudeWithScreenshot(transcript: trimmedTextQuery)
    }

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        responseOverlayManager.hideOverlay()

        currentResponseTask = Task {
            // Stay in processing (spinner) state while waiting for Claude's response
            voiceState = .processing
            isQuotaExceeded = false   // Clear any previous quota-exceeded banner
            lastAPIErrorMessage = nil // Clear any previous API error banner
            let pipelineStartTime = CFAbsoluteTimeGetCurrent()

            do {
                // Capture the user's current scene (frontmost app + window title)
                // so Claude knows what app the user is working in.
                let sceneContext = SceneContextDetector.captureCurrentSceneContext()
                let systemPromptWithContext = companionVoiceResponseSystemPrompt + sceneContext.contextSummaryForSystemPrompt

                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                let captureElapsedMs = Int((CFAbsoluteTimeGetCurrent() - pipelineStartTime) * 1000)
                print("⏱ Pipeline: screenshot capture done in \(captureElapsedMs)ms")

                guard !Task.isCancelled else { return }

                // Only send the cursor screen — the user's attention is always
                // on the screen where their mouse is. Sending all screens wastes
                // upload bandwidth, token budget, and AI processing time.
                let cursorScreenCaptures = screenCaptures.filter { $0.isCursorScreen }
                let effectiveCaptures = cursorScreenCaptures.isEmpty ? screenCaptures : cursorScreenCaptures

                // Build image labels with pixel dimensions and the cursor's pixel
                // position so the AI knows exactly where on screen the user is focused.
                let mouseLocation = NSEvent.mouseLocation
                let labeledImages = effectiveCaptures.map { capture in
                    var label = capture.label
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"

                    // Convert the mouse's global AppKit coordinates to the screenshot's
                    // pixel space (top-left origin) so the AI can locate the cursor area.
                    if capture.isCursorScreen {
                        let localX = mouseLocation.x - capture.displayFrame.origin.x
                        let localY = (capture.displayFrame.origin.y + capture.displayFrame.height) - mouseLocation.y
                        let pixelX = Int(localX * CGFloat(capture.screenshotWidthInPixels) / capture.displayFrame.width)
                        let pixelY = Int(localY * CGFloat(capture.screenshotHeightInPixels) / capture.displayFrame.height)
                        label += " (cursor at pixel \(pixelX), \(pixelY))"
                    }

                    label += dimensionInfo
                    return (data: capture.imageData, label: label)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                // Use the appropriate chat API based on configured format.
                // Show the response text overlay so the user can read along
                // while TTS audio plays.
                var accumulatedStreamingText = ""
                responseOverlayManager.showOverlayAndBeginStreaming()

                let fullResponseText: String
                let chatAPIFormat = APIConfiguration.shared.effectiveChatAPIFormat
                if chatAPIFormat == .openaiCompatible {
                    let (responseText, _) = try await openAICompatibleChatAPI.analyzeImageStreaming(
                        images: labeledImages,
                        systemPrompt: systemPromptWithContext,
                        conversationHistory: historyForAPI,
                        userPrompt: transcript,
                        bearerToken: APIConfiguration.shared.chatAPIMode == .proxy
                            ? await SupabaseAuthManager.shared.validAccessToken()
                            : nil,
                        onTextChunk: { [weak self] chunk in
                            accumulatedStreamingText += chunk
                            self?.responseOverlayManager.updateStreamingText(accumulatedStreamingText)
                        }
                    )
                    fullResponseText = responseText
                } else {
                    let (responseText, _) = try await claudeAPI.analyzeImageStreaming(
                        images: labeledImages,
                        systemPrompt: systemPromptWithContext,
                        conversationHistory: historyForAPI,
                        userPrompt: transcript,
                        bearerToken: APIConfiguration.shared.chatAPIMode == .proxy
                            ? SupabaseAuthManager.shared.currentSession?.accessToken
                            : nil,
                        onTextChunk: { [weak self] chunk in
                            accumulatedStreamingText += chunk
                            self?.responseOverlayManager.updateStreamingText(accumulatedStreamingText)
                        }
                    )
                    fullResponseText = responseText
                }

                let apiElapsedMs = Int((CFAbsoluteTimeGetCurrent() - pipelineStartTime) * 1000)
                let imageDataSizeKB = labeledImages.reduce(0) { $0 + $1.data.count } / 1024
                print("⏱ Pipeline: Claude API done in \(apiElapsedMs)ms (sent \(labeledImages.count) image(s), \(imageDataSizeKB)KB total)")

                guard !Task.isCancelled else {
                    responseOverlayManager.hideOverlay()
                    return
                }

                // Refresh userProfile in the background so the panel usage
                // counter reflects the incremented daily_chat_count from the DB.
                // Fire-and-forget — does not block the response/TTS pipeline.
                if APIConfiguration.shared.chatAPIMode == .proxy {
                    Task { await SupabaseAuthManager.shared.fetchUserProfile() }
                }

                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Update the overlay with the clean text (POINT tag stripped)
                responseOverlayManager.updateStreamingText(spokenText)

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= effectiveCaptures.count {
                        return effectiveCaptures[screenNumber - 1]
                    }
                    return effectiveCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Claude's rough estimate in global AppKit coordinates
                    let claudeGlobalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    // Use Claude's rough estimate immediately so the cursor
                    // starts flying while the precise detector runs in parallel.
                    detectedElementScreenLocation = claudeGlobalLocation
                    detectedElementDisplayFrame = displayFrame

                    // If an element location detector is configured (e.g. UI-TARS),
                    // refine the coordinate in the background. The detector's result
                    // updates the location after the cursor has already started its
                    // flight, so there's no added latency to the TTS pipeline.
                    if let detector = elementLocationDetector,
                       let elementLabel = parseResult.elementLabel,
                       !elementLabel.isEmpty {
                        let capturedDisplayFrame = displayFrame
                        let capturedScreenCapture = targetScreenCapture
                        Task {
                            print("🎯 Element pointing: running precise detection for \"\(elementLabel)\"...")
                            if let refinedDisplayLocalCoordinate = await detector.detectElementLocation(
                                screenshotData: capturedScreenCapture.imageData,
                                elementQuery: elementLabel,
                                displayWidthInPoints: capturedScreenCapture.displayWidthInPoints,
                                displayHeightInPoints: capturedScreenCapture.displayHeightInPoints
                            ) {
                                let refinedGlobalLocation = CGPoint(
                                    x: refinedDisplayLocalCoordinate.x + capturedDisplayFrame.origin.x,
                                    y: refinedDisplayLocalCoordinate.y + capturedDisplayFrame.origin.y
                                )
                                self.detectedElementScreenLocation = refinedGlobalLocation
                                print("🎯 Element pointing: refined (\(Int(claudeGlobalLocation.x)), \(Int(claudeGlobalLocation.y))) → (\(Int(refinedGlobalLocation.x)), \(Int(refinedGlobalLocation.y)))")
                            } else {
                                print("🎯 Element pointing: detector returned nil, using Claude's estimate")
                            }
                        }
                    }
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        // Use the appropriate TTS provider
                        if APIConfiguration.shared.ttsProvider == .openaiCompatible {
                            try await openAICompatibleTTSClient.speakText(
                                spokenText,
                                bearerToken: APIConfiguration.shared.chatAPIMode == .proxy
                                    ? await SupabaseAuthManager.shared.validAccessToken()
                                    : nil
                            )
                        } else {
                            try await elevenLabsTTSClient.speakText(
                                spokenText,
                                bearerToken: APIConfiguration.shared.chatAPIMode == .proxy
                                    ? SupabaseAuthManager.shared.currentSession?.accessToken
                                    : nil
                            )
                        }
                        // speakText returns after player.play() — audio is now playing
                        let ttsElapsedMs = Int((CFAbsoluteTimeGetCurrent() - pipelineStartTime) * 1000)
                        print("⏱ Pipeline: TTS ready in \(ttsElapsedMs)ms (total from start)")
                        voiceState = .responding
                        // Begin auto-hide countdown for the text overlay
                        responseOverlayManager.finishStreaming()
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ TTS error: \(error)")
                        responseOverlayManager.finishStreaming()
                        speakContextualErrorFallback(error)
                    }
                } else {
                    // No spoken text — hide the overlay immediately
                    responseOverlayManager.finishStreaming()
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
                responseOverlayManager.hideOverlay()
            } catch let quotaError as ChatQuotaExceededError {
                // 429 daily_limit_exceeded: show a panel banner instead of
                // speaking the credits-error fallback, since the user is not
                // "out of credits" — they just need to wait until tomorrow.
                responseOverlayManager.hideOverlay()
                isQuotaExceeded = true
                voiceState = .idle
                print("⚠️ Quota exceeded: \(quotaError.message)")
                // Refresh profile so the usage counter in the panel reflects
                // the actual used_today count from the DB.
                await SupabaseAuthManager.shared.fetchUserProfile()
            } catch let nsError as NSError where nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
                // TCC permission was revoked (e.g. new Xcode build
                // invalidated the signing identity). Reset in-memory
                // permission state so the panel shows Grant buttons.
                responseOverlayManager.hideOverlay()
                print("⚠️ Screen capture TCC denied (code \(nsError.code)) — resetting permission state")
                hasScreenContentPermission = false
                hasScreenRecordingPermission = false
                voiceState = .idle
                speakScreenPermissionErrorFallback()
            } catch {
                responseOverlayManager.hideOverlay()
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakContextualErrorFallback(error)
            }

            if !Task.isCancelled {
                voiceState = .idle
                onboardingGuideManager.notifyEvent(.voiceInteractionCompleted)
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying || openAICompatibleTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a short message when screen capture permission is denied,
    /// telling the user to re-grant access in System Settings.
    private func speakScreenPermissionErrorFallback() {
        let utterance = String(localized: "I can't see your screen right now. Please open the Clicky panel and re-grant screen recording permission.", locale: appLocale)
        let voiceIdentifier = LocalizationManager.shared.currentLanguage.nsSpeechSynthesizerVoiceIdentifier
        let synthesizer = NSSpeechSynthesizer(voice: NSSpeechSynthesizer.VoiceName(rawValue: voiceIdentifier)) ?? NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out (proxy mode only). Uses NSSpeechSynthesizer so it
    /// works even when ElevenLabs is down.
    private func speakCreditsErrorFallback() {
        let utterance = String(localized: "I'm all out of credits. Please DM Farza and tell him to bring me back to life.", locale: appLocale)
        let voiceIdentifier = LocalizationManager.shared.currentLanguage.nsSpeechSynthesizerVoiceIdentifier
        let synthesizer = NSSpeechSynthesizer(voice: NSSpeechSynthesizer.VoiceName(rawValue: voiceIdentifier)) ?? NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    /// Speaks a contextual error message and shows a visible banner in the panel
    /// based on the HTTP status code. The banner persists until the next interaction.
    private func speakContextualErrorFallback(_ error: Error) {
        let isDirectMode = APIConfiguration.shared.chatAPIMode == .direct

        // Extract HTTP status code from NSError if available.
        // Check all API client domains (chat and TTS).
        let nsError = error as NSError
        let apiDomains: Set<String> = [
            "OpenAICompatibleChatAPI", "ClaudeAPI", "OpenAICompatibleTTS"
        ]
        let statusCode: Int? = apiDomains.contains(nsError.domain) ? nsError.code : nil

        let utterance: String
        let bannerMessage: String

        if !isDirectMode {
            // Proxy mode: Worker handles auth/quota, generic message for unexpected errors.
            utterance = String(localized: "Something went wrong. Please try again later.", locale: appLocale)
            bannerMessage = String(localized: "服务出错，请稍后重试。", locale: appLocale)
        } else if let code = statusCode {
            switch code {
            case 400:
                utterance = String(localized: "The API rejected the request. Please check the model and voice settings.", locale: appLocale)
                bannerMessage = String(localized: "请求被拒绝，请检查模型名称和参数设置。", locale: appLocale)
            case 401, 403:
                utterance = String(localized: "API key is invalid or expired. Please check your API key in the settings.", locale: appLocale)
                bannerMessage = String(localized: "API Key 无效或未配置，请在设置中填写正确的 Key。", locale: appLocale)
            case 402:
                utterance = String(localized: "Your API account balance is insufficient. Please top up your account.", locale: appLocale)
                bannerMessage = String(localized: "API 账户余额不足，请充值后重试。", locale: appLocale)
            case 404:
                utterance = String(localized: "The selected model was not found. Please check the model name in settings.", locale: appLocale)
                bannerMessage = String(localized: "模型未找到，请检查设置中的模型名称。", locale: appLocale)
            case 429:
                utterance = String(localized: "Too many requests. Please wait a moment and try again.", locale: appLocale)
                bannerMessage = String(localized: "请求过于频繁，请稍后重试。", locale: appLocale)
            default:
                utterance = String(localized: "Something went wrong with the API request. Please check the settings and try again.", locale: appLocale)
                bannerMessage = String(localized: "API 请求出错（\(code)），请检查设置后重试。", locale: appLocale)
            }
        } else {
            // Network error or other non-HTTP error
            utterance = String(localized: "I couldn't reach the API server. Please check your network connection and settings.", locale: appLocale)
            bannerMessage = String(localized: "无法连接到 API 服务器，请检查网络和设置。", locale: appLocale)
        }

        // Show a visible banner in the panel so the user sees the error even if
        // they miss the spoken message or have their volume muted.
        lastAPIErrorMessage = bannerMessage

        let voiceIdentifier = LocalizationManager.shared.currentLanguage.nsSpeechSynthesizerVoiceIdentifier
        let synthesizer = NSSpeechSynthesizer(voice: NSSpeechSynthesizer.VoiceName(rawValue: voiceIdentifier)) ?? NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // Onboarding video, music, and demo interaction have been removed.
    // Onboarding is now handled by OnboardingGuideManager with step-by-step
    // text bubble guidance.

    /// Placeholder kept for BlueCursorView compatibility — no longer triggers
    /// a video-based demo. The guide system handles onboarding instead.
    func performOnboardingDemoInteraction() {
        // No-op: onboarding demo removed. Kept as empty stub for
        // BlueCursorView compatibility.
    }
}
