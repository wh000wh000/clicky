//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var supabaseAuthManager = SupabaseAuthManager.shared
    @ObservedObject private var apiConfig = APIConfiguration.shared
    @ObservedObject private var whisperKitManager = WhisperKitModelManager.shared
    @State private var textQueryInput: String = ""
    @State private var showAPISettings: Bool = false
    @State private var signInEmail: String = ""
    @State private var signInPassword: String = ""
    @State private var isSigningIn: Bool = false
    @State private var signInErrorMessage: String? = nil
    @State private var isSignUpMode: Bool = false
    @State private var awaitingEmailConfirmation: Bool = false
    @State private var confirmationEmail: String = ""
    @FocusState private var isTextQueryFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 12)

                modelPickerRow
                    .padding(.horizontal, 16)

                if apiConfig.sttProvider == .whisperKit {
                    Spacer()
                        .frame(height: 8)

                    voiceEngineRow
                        .padding(.horizontal, 16)
                }
            }

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                settingsSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, 16)
            }

            // Show Clicky toggle — hidden for now
            // if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            //     Spacer()
            //         .frame(height: 16)
            //
            //     showClickyCursorToggleRow
            //         .padding(.horizontal, 16)
            // }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 12)

                textInputSection
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 10)

                quickActionsGrid
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                dmFarzaButton
                    .padding(.horizontal, 16)
            }

            // Show auth row only in proxy mode (direct mode users supply their own keys).
            if apiConfig.chatAPIMode == .proxy {
                Spacer()
                    .frame(height: 12)

                authSection
                    .padding(.horizontal, 16)
            }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
        .sheet(isPresented: $showAPISettings) {
            APISettingsView(apiConfiguration: APIConfiguration.shared)
                .onDisappear {
                    companionManager.reloadAPIClients()
                }
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Clicky")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Button(action: { showAPISettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            Button(action: {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Hold Control+Option to talk, or type below.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Clicky.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant all four below to keep using Clicky.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, I'm Farza. This is Clicky.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("A side project I made for fun to help me learn stuff as I use my computer.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Nothing runs in the background. Clicky will only take a screenshot when you press the hot key. So, you can give that permission in peace. If you are still sus, eh, I can't do much there champ.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Button(action: {
                companionManager.triggerOnboarding()
            }) {
                Text("Start")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you use the hotkey"
                         : "Quit and reopen after granting")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager.requestScreenRecordingPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }



    // MARK: - Show Clicky Cursor Toggle

    private var showClickyCursorToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show Clicky")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isClickyCursorEnabled },
                set: { companionManager.setClickyCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var speechToTextProviderRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Speech to Text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Quick Actions

    private var quickActionsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ], spacing: 8) {
            ForEach(companionManager.quickActionPresets) { preset in
                Button(action: {
                    companionManager.sendTextQueryToClaudeWithScreenshot(textQuery: preset.promptText)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: preset.iconName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.accentText)
                        Text(preset.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Text Input

    private var textInputSection: some View {
        HStack(spacing: 8) {
            TextField("Ask Clicky anything...", text: $textQueryInput)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .focused($isTextQueryFieldFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(
                            isTextQueryFieldFocused ? DS.Colors.accent.opacity(0.5) : DS.Colors.borderSubtle,
                            lineWidth: 0.5
                        )
                )
                .onSubmit {
                    submitTextQuery()
                }

            Button(action: { submitTextQuery() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(
                        textQueryInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? DS.Colors.textTertiary
                            : DS.Colors.accent
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(textQueryInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func submitTextQuery() {
        let queryText = textQueryInput
        textQueryInput = ""
        isTextQueryFieldFocused = false
        companionManager.sendTextQueryToClaudeWithScreenshot(textQuery: queryText)
    }

    // MARK: - Model Picker

    private var modelPickerRow: some View {
        HStack {
            Text("Model")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            HStack(spacing: 0) {
                modelOptionButton(label: "Sonnet", modelID: "claude-sonnet-4-6")
                modelOptionButton(label: "Opus", modelID: "claude-opus-4-6")
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private func modelOptionButton(label: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return Button(action: {
            companionManager.setSelectedModel(modelID)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - DM Farza Button

    private var dmFarzaButton: some View {
        Button(action: {
            if let url = URL(string: "https://x.com/farzatv") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 12, weight: .medium))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Got feedback? DM me")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Bugs, ideas, anything — I read every message.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Auth Section

    /// Compact authentication row shown in proxy mode.
    /// Displays an Apple Sign In button when signed out, or the user's email
    /// with a sign-out affordance when signed in.
    // MARK: - Voice Engine Row

    @ViewBuilder
    private var voiceEngineRow: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "waveform.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Voice Engine")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            switch whisperKitManager.modelState {
            case .notDownloaded:
                Button(action: { companionManager.startWhisperKitDownload() }) {
                    Text("Download")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(DS.Colors.accent))
                }
                .buttonStyle(.plain)
                .pointerCursor()

            case .downloading(let progress):
                HStack(spacing: 6) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.1))
                                .frame(height: 6)
                            Capsule()
                                .fill(DS.Colors.accent)
                                .frame(
                                    width: max(geometry.size.width * progress, 4),
                                    height: 6
                                )
                        }
                    }
                    .frame(width: 70, height: 6)

                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 28, alignment: .trailing)

                    Button(action: { companionManager.cancelWhisperKitDownload() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

            case .ready:
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Ready")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }

            case .failed:
                Button(action: { companionManager.startWhisperKitDownload() }) {
                    Text("Retry")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.warning)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .stroke(DS.Colors.warning.opacity(0.5), lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: DS.Animation.normal), value: whisperKitManager.modelState)
    }

    // MARK: - Auth Section

    private var authSection: some View {
        Group {
            if supabaseAuthManager.isAuthenticated {
                signedInRow
            } else if awaitingEmailConfirmation {
                emailConfirmationPendingView
            } else {
                signInFormView
            }
        }
    }

    private var signedInRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)

            Text(supabaseAuthManager.currentSession?.user.email ?? "已登录")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button(action: {
                supabaseAuthManager.signOut()
            }) {
                Text("退出")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private var signInFormView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Signup mode header — accent color signals this is a different flow from login
            if isSignUpMode {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.accent)
                    Text("创建账号")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.accent)
                }
                .padding(.bottom, 2)
            }

            // Email field
            TextField("邮箱", text: $signInEmail)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
                .autocorrectionDisabled()

            // Password field — with minimum length hint shown only in signup mode
            VStack(alignment: .leading, spacing: 3) {
                SecureField("密码", text: $signInPassword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
                    .onSubmit { performAuthAction() }

                if isSignUpMode {
                    Text("至少 6 个字符")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, 2)
                }
            }

            // Submit button — accent fill in signup mode for visual distinction,
            // neutral fill in login mode to avoid confusion between the two flows.
            Button(action: performAuthAction) {
                HStack(spacing: 6) {
                    if isSigningIn {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    }
                    Text(isSigningIn
                         ? (isSignUpMode ? "注册中…" : "登录中…")
                         : (isSignUpMode ? "注册" : "登录"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(isSignUpMode ? DS.Colors.textOnAccent : DS.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSignUpMode ? DS.Colors.accent : Color.white.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(isSigningIn || signInEmail.isEmpty || signInPassword.isEmpty)

            // Toggle between login and signup modes
            HStack {
                Text(isSignUpMode ? "已有账号？" : "没有账号？")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)

                Button(action: {
                    isSignUpMode.toggle()
                    signInErrorMessage = nil
                }) {
                    Text(isSignUpMode ? "去登录" : "去注册")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .underline()
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            if let errorMessage = signInErrorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundColor(.red.opacity(0.8))
                    .lineLimit(3)
                    .padding(.horizontal, 2)
            }
        }
    }

    private var emailConfirmationPendingView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "envelope.badge.fill")
                    .font(.system(size: 16))
                    .foregroundColor(DS.Colors.accent)

                VStack(alignment: .leading, spacing: 3) {
                    Text("确认邮箱")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("确认邮件已发送至 \(confirmationEmail)")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
            }

            HStack(spacing: 6) {
                Button(action: {
                    Task { await SupabaseAuthManager.shared.resendConfirmationEmail(email: confirmationEmail) }
                }) {
                    Text("重新发送")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button(action: {
                    awaitingEmailConfirmation = false
                    confirmationEmail = ""
                    isSignUpMode = false
                }) {
                    Text("返回登录")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.accent.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func performAuthAction() {
        guard !signInEmail.isEmpty, !signInPassword.isEmpty else { return }
        isSigningIn = true
        signInErrorMessage = nil
        Task {
            do {
                if isSignUpMode {
                    try await SupabaseAuthManager.shared.signUp(
                        email: signInEmail,
                        password: signInPassword
                    )
                } else {
                    try await SupabaseAuthManager.shared.signIn(
                        email: signInEmail,
                        password: signInPassword
                    )
                }
                signInPassword = "" // clear password from memory after success
            } catch let supabaseError as SupabaseAuthError {
                if case .emailConfirmationRequired(let email) = supabaseError {
                    // Switch to the confirmation-pending view instead of showing an error.
                    confirmationEmail = email
                    awaitingEmailConfirmation = true
                    signInPassword = ""
                } else {
                    signInErrorMessage = supabaseError.localizedDescription
                }
            } catch {
                signInErrorMessage = error.localizedDescription
            }
            isSigningIn = false
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit Clicky")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return String(localized: "Setup")
        }
        if !companionManager.isOverlayVisible {
            return String(localized: "Ready")
        }
        switch companionManager.voiceState {
        case .idle:
            return String(localized: "Active")
        case .listening:
            return String(localized: "Listening")
        case .processing:
            return String(localized: "Processing")
        case .responding:
            return String(localized: "Responding")
        }
    }

}
