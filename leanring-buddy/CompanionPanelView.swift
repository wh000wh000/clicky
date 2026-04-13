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
    @State private var invitationCode: String = ""
    @State private var isVerifyingInvitationCode: Bool = false
    @State private var invitationCodeErrorMessage: String? = nil
    /// True for 2 seconds after the user copies their personal invite code,
    /// used to animate the "复制" button into a "已复制" confirmation.
    @State private var didCopyInviteCode: Bool = false
    /// Controls presentation of the UserCenterView sheet.
    @State private var isShowingUserCenter: Bool = false
    @FocusState private var isTextQueryFieldFocused: Bool

    var body: some View {
        // Inline navigation: swap the entire panel content for UserCenterView when open.
        // Using a Group + if/else is more reliable than .sheet with a custom NSPanel.
        Group {
        if isShowingUserCenter {
            UserCenterView(onDismiss: { isShowingUserCenter = false })
        } else {
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
        } // end else (normal panel content)
        } // end Group (UserCenter / normal content switch)
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
                                .fill(DS.Colors.surface2)
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
                            .fill(DS.Colors.surface2)
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

            // Show Screen Content row whenever it hasn't been granted yet.
            // Previously gated on hasScreenRecordingPermission, but CGPreflightScreenCaptureAccess()
            // returns false-negatives on macOS 15 Sequoia, which hid this row permanently
            // and blocked allPermissionsGranted from ever becoming true.
            if !companionManager.hasScreenContentPermission {
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
                        // Calls AXIsProcessTrustedWithOptions to (re-)register the current
                        // build in TCC, then opens System Settings for the user to toggle.
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
                         : "Grant then tap again — or restart if granting for the first time")
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
                    // Calls CGRequestScreenCaptureAccess to (re-)register the current
                    // build in TCC, then opens System Settings if not yet authorized.
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
                            .fill(DS.Colors.surface1)
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
                        .fill(DS.Colors.surface2)
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
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
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
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(isSelected ? DS.Colors.surface3 : Color.clear)
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
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
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
                                .fill(DS.Colors.surface3)
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

    // Daily chat limits per plan — must stay in sync with the Worker's
    // PLAN_DAILY_CHAT_LIMITS constant and the public.plans table.
    private let planDailyLimits: [String: Int] = [
        "free":    20,
        "pro":     200,
        "premium": 999_999
    ]

    /// The current user's daily chat limit based on their plan.
    private var currentPlanDailyLimit: Int {
        let plan = supabaseAuthManager.userProfile?.plan ?? "free"
        return planDailyLimits[plan] ?? 20
    }

    /// Number of chat calls used today, from the cached userProfile.
    private var currentDailyUsed: Int {
        supabaseAuthManager.userProfile?.dailyChatCount ?? 0
    }

    /// Color reflecting how close the user is to their daily limit.
    private var dailyUsageColor: Color {
        let ratio = Double(currentDailyUsed) / Double(currentPlanDailyLimit)
        if ratio >= 1.0 { return DS.Colors.destructiveText }
        if ratio >= 0.75 { return DS.Colors.warning }
        return DS.Colors.success
    }

    /// True when the user is authenticated in proxy mode but has not yet
    /// redeemed an invitation code. In this state the invitation gate view
    /// is shown instead of the normal signed-in row.
    private var isInvitationGated: Bool {
        guard apiConfig.chatAPIMode == .proxy,
              supabaseAuthManager.isAuthenticated else { return false }
        // If the profile hasn't loaded yet, don't gate — avoids a brief flash
        // of the gate view on launch before the network call completes.
        guard let profile = supabaseAuthManager.userProfile else { return false }
        return !profile.invitationVerified
    }

    private var authSection: some View {
        Group {
            if supabaseAuthManager.isAuthenticated {
                if isInvitationGated {
                    invitationCodeEntrySection
                } else {
                    VStack(spacing: 8) {
                        signedInRow
                        // Show the upgrade card when the user is on the free plan and
                        // is using proxy mode (upgrade only applies to the managed service).
                        if apiConfig.chatAPIMode == .proxy,
                           supabaseAuthManager.userProfile?.plan == "free" {
                            planUpgradeSection
                        }
                    }
                }
            } else if awaitingEmailConfirmation {
                emailConfirmationPendingView
            } else {
                signInFormView
            }
        }
    }

    private var signedInRow: some View {
        VStack(spacing: 0) {
            // ── Top row: user email + sign out ──
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

                // Opens the full UserCenterView (account details, subscription, sign-out).
                Button(action: { isShowingUserCenter = true }) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 15))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            // ── Bottom row: personal invite code + copy (shown once profile loads) ──
            if let myInviteCode = supabaseAuthManager.userProfile?.inviteCode {
                Divider()
                    .background(DS.Colors.borderSubtle)
                    .padding(.vertical, 8)

                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)

                    Text("邀请码")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)

                    Text(myInviteCode)
                        .font(.system(size: 11, weight: .semibold).monospaced())
                        .foregroundColor(DS.Colors.textSecondary)

                    // Show invited-count badge when at least one person was invited
                    if let invitedCount = supabaseAuthManager.userProfile?.invitedCount,
                       invitedCount > 0 {
                        Text("· 已邀请 \(invitedCount) 人")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    }

                    Spacer()

                    Button(action: { copyInviteCodeToPasteboard(myInviteCode) }) {
                        Text(didCopyInviteCode ? "已复制" : "复制")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(didCopyInviteCode ? DS.Colors.success : DS.Colors.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                    .fill(DS.Colors.surface2)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .animation(.easeInOut(duration: DS.Animation.normal), value: didCopyInviteCode)
                }
            }
            // ── Usage row: today's count + progress bar (shown once profile loads) ──
            if supabaseAuthManager.userProfile != nil {
                Divider()
                    .background(DS.Colors.borderSubtle)
                    .padding(.vertical, 8)

                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)

                        Text("今日")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)

                        Text("\(currentDailyUsed) / \(currentPlanDailyLimit == 999_999 ? "∞" : "\(currentPlanDailyLimit)")")
                            .font(.system(size: 11, weight: .semibold).monospaced())
                            .foregroundColor(dailyUsageColor)

                        // Mini progress bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(DS.Colors.surface3)
                                    .frame(height: 4)
                                Capsule()
                                    .fill(dailyUsageColor)
                                    .frame(
                                        width: max(
                                            geo.size.width * min(
                                                Double(currentDailyUsed) / Double(max(currentPlanDailyLimit, 1)),
                                                1.0
                                            ),
                                            4
                                        ),
                                        height: 4
                                    )
                            }
                        }
                        .frame(height: 4)

                        Spacer()

                        Text((supabaseAuthManager.userProfile?.plan ?? "free").uppercased())
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                    }

                    // Quota-exceeded warning banner
                    if companionManager.isQuotaExceeded {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                            Text("今日额度已用完，明天自动恢复或升级套餐。")
                                .font(.system(size: 10))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundColor(DS.Colors.destructiveText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: DS.Animation.normal), value: currentDailyUsed)
                .animation(.easeInOut(duration: DS.Animation.normal), value: companionManager.isQuotaExceeded)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private func copyInviteCodeToPasteboard(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        didCopyInviteCode = true
        // Reset the button label after 2 seconds
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            didCopyInviteCode = false
        }
    }

    // MARK: - Plan upgrade (Phase 4)

    /// Card shown to free-plan users in proxy mode. Presents Pro and Premium
    /// upgrade options that open Stripe's hosted checkout in the browser.
    private var planUpgradeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.accent)

                Text("解锁更多次数")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()
            }

            // Pro and Premium buttons side by side
            HStack(spacing: 8) {
                planUpgradeButton(
                    planName: "pro",
                    displayName: "Pro",
                    dailyLimitLabel: "200 次/天"
                )
                planUpgradeButton(
                    planName: "premium",
                    displayName: "Premium",
                    dailyLimitLabel: "无限制"
                )
            }

            Text("微信扫码支付 · 安全便捷")
                .font(.system(size: 9))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                // Accent-tinted border distinguishes this card from the neutral signedInRow
                .stroke(DS.Colors.accent.opacity(0.25), lineWidth: 0.5)
        )
    }

    /// A single plan option button inside `planUpgradeSection`.
    /// Tapping any plan button opens UserCenterView where the WeChat Pay QR flow lives.
    @ViewBuilder
    private func planUpgradeButton(
        planName: String,
        displayName: String,
        dailyLimitLabel: String
    ) -> some View {
        Button(action: { isShowingUserCenter = true }) {
            VStack(spacing: 3) {
                Text(displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text(dailyLimitLabel)
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.textOnAccent.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.accent.opacity(0.65))
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
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
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
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
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
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
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(isSignUpMode ? DS.Colors.accent : DS.Colors.surface2)
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
                    .foregroundColor(DS.Colors.destructiveText)
                    .lineLimit(3)
                    .padding(.horizontal, 2)
            }
        }
    }

    /// Shown when the user is authenticated but `invitation_verified` is false.
    /// Blocks access to the app's proxy features until a valid code is entered.
    private var invitationCodeEntrySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header — accent color mirrors the sign-up header style
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.accent)
                Text("输入邀请码")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.accent)
            }

            // Code input field + verify button side-by-side
            HStack(spacing: 6) {
                TextField("邀请码（如 CLICKY01）", text: $invitationCode)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12).monospaced())
                    .foregroundColor(DS.Colors.textPrimary)
                    .autocorrectionDisabled()
                    // Auto-uppercase as the user types — invitation codes are always uppercase
                    .onChange(of: invitationCode) { _, newValue in
                        let uppercased = newValue.uppercased()
                        if uppercased != newValue { invitationCode = uppercased }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
                    .onSubmit { performUseInvitationCode() }

                Button(action: performUseInvitationCode) {
                    Group {
                        if isVerifyingInvitationCode {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            Text("验证")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(invitationCode.isEmpty ? DS.Colors.surface2 : DS.Colors.accent)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(isVerifyingInvitationCode || invitationCode.isEmpty)
            }

            Text("邀请码由邀请你的朋友提供，或联系开发者获取。")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)

            if let errorMessage = invitationCodeErrorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.destructiveText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Allow the user to sign out if they don't have a code
            Button(action: { supabaseAuthManager.signOut() }) {
                Text("退出登录")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .underline()
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.accent.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func performUseInvitationCode() {
        guard !invitationCode.isEmpty else { return }
        isVerifyingInvitationCode = true
        invitationCodeErrorMessage = nil
        Task {
            do {
                try await SupabaseAuthManager.shared.useInvitationCode(invitationCode)
                // Success: userProfile.invitationVerified is now true.
                // isInvitationGated flips to false and authSection automatically
                // transitions to signedInRow — no manual state update needed.
                invitationCode = ""
            } catch let supabaseError as SupabaseAuthError {
                invitationCodeErrorMessage = supabaseError.localizedDescription
            } catch {
                invitationCodeErrorMessage = error.localizedDescription
            }
            isVerifyingInvitationCode = false
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
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.surface1)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
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
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.surface1)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
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
