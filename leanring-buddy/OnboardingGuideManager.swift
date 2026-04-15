//
//  OnboardingGuideManager.swift
//  leanring-buddy
//
//  Step-by-step text bubble onboarding system. Guides new users through
//  4 progressive steps: welcome → voice interaction → text input → cursor
//  popup. Each step has a completion condition that auto-advances to the
//  next step. Progress is persisted to UserDefaults.
//

import Combine
import Foundation

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case textInput = 1
    case cursorPopup = 2
    case voiceInteraction = 3
    case completed = 4

    var guideBubbleText: String {
        switch self {
        case .welcome:
            return String(localized: "hey! i'm clicky, your screen assistant. grant the permissions above to get started.")
        case .textInput:
            return String(localized: "click the menu bar icon and type your question to get started!")
        case .cursorPopup:
            return String(localized: "try cmd+shift+space to open a quick panel right at your cursor!")
        case .voiceInteraction:
            return String(localized: "hold control+option to talk to me! release when you're done.")
        case .completed:
            return ""
        }
    }
}

@MainActor
final class OnboardingGuideManager: ObservableObject {
    @Published private(set) var currentStep: OnboardingStep
    @Published var showGuideBubble: Bool = false
    @Published var guideBubbleOpacity: Double = 0.0

    /// The text currently displayed in the guide bubble. Updated when the
    /// step changes, streamed character-by-character for a natural feel.
    @Published var guideBubbleText: String = ""

    private var streamingTimer: Timer?

    init() {
        let savedStep = UserDefaults.standard.integer(forKey: "onboardingGuideStep")
        self.currentStep = OnboardingStep(rawValue: savedStep) ?? .welcome
    }

    /// Starts the guide from the current persisted step. Called when the
    /// overlay first appears after the user clicks "Start".
    /// Pass `allPermissionsGranted: true` when permissions are already
    /// satisfied so the welcome step auto-advances instead of getting stuck.
    func startGuide(allPermissionsGranted: Bool = false) {
        guard currentStep != .completed else { return }

        // If the welcome step's condition is already met (permissions were
        // granted in a previous session), skip straight to the next step
        // instead of showing "grant the permissions above" text.
        if currentStep == .welcome && allPermissionsGranted {
            advanceToNextStep()
            return
        }

        showGuideBubbleForCurrentStep()
    }

    /// Skips the current onboarding step. Useful for testing or when the
    /// user wants to move forward without completing the step's action.
    func skipCurrentStep() {
        guard currentStep != .completed else { return }
        advanceToNextStep()
    }

    /// Called by CompanionManager when an event occurs that might complete
    /// the current step. Checks the condition and advances if met.
    func notifyEvent(_ event: OnboardingEvent) {
        guard currentStep != .completed else { return }

        switch (currentStep, event) {
        case (.welcome, .allPermissionsGranted):
            advanceToNextStep()
        case (.textInput, .textQuerySent):
            advanceToNextStep()
        case (.cursorPopup, .cursorPopupOpened):
            advanceToNextStep()
        case (.voiceInteraction, .voiceInteractionCompleted):
            advanceToNextStep()
        default:
            break
        }
    }

    /// Resets onboarding to the beginning. Used for testing or if the user
    /// wants to re-do the guide.
    func resetGuide() {
        currentStep = .welcome
        UserDefaults.standard.set(currentStep.rawValue, forKey: "onboardingGuideStep")
        dismissBubble()
    }

    // MARK: - Private

    private func advanceToNextStep() {
        dismissBubble()

        guard let nextStepRawValue = OnboardingStep(rawValue: currentStep.rawValue + 1) else {
            currentStep = .completed
            UserDefaults.standard.set(currentStep.rawValue, forKey: "onboardingGuideStep")
            return
        }

        currentStep = nextStepRawValue
        UserDefaults.standard.set(currentStep.rawValue, forKey: "onboardingGuideStep")

        if currentStep != .completed {
            // Brief delay before showing next step for a natural transition
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showGuideBubbleForCurrentStep()
            }
        }
    }

    private func showGuideBubbleForCurrentStep() {
        let fullMessage = currentStep.guideBubbleText
        guard !fullMessage.isEmpty else { return }

        guideBubbleText = ""
        showGuideBubble = true
        guideBubbleOpacity = 0.0

        // Fade in the bubble
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.guideBubbleOpacity = 1.0
        }

        // Stream text character-by-character
        var currentIndex = 0
        streamingTimer?.invalidate()
        streamingTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
            guard let self, currentIndex < fullMessage.count else {
                timer.invalidate()
                return
            }
            let index = fullMessage.index(fullMessage.startIndex, offsetBy: currentIndex)
            self.guideBubbleText.append(fullMessage[index])
            currentIndex += 1
        }
    }

    private func dismissBubble() {
        streamingTimer?.invalidate()
        streamingTimer = nil
        guideBubbleOpacity = 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.showGuideBubble = false
            self?.guideBubbleText = ""
        }
    }
}

// MARK: - Onboarding Events

enum OnboardingEvent {
    case allPermissionsGranted
    case voiceInteractionCompleted
    case textQuerySent
    case cursorPopupOpened
}
