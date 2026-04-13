//
//  UserCenterView.swift
//  leanring-buddy
//
//  Account / user center. Inline panel swap triggered from the account icon
//  in the signed-in row. Shows:
//    - Email + plan badge
//    - Daily / cumulative usage
//    - Invite code + invited count
//    - Subscription: WeChat Pay QR code upgrade (free users) or plan info (paid)
//    - Sign-out
//

import CoreImage.CIFilterBuiltins
import SwiftUI

struct UserCenterView: View {
    @ObservedObject private var supabaseAuthManager = SupabaseAuthManager.shared
    @ObservedObject private var apiConfig = APIConfiguration.shared

    /// Dismisses this inline view back to the main panel.
    var onDismiss: () -> Void

    // MARK: - State

    /// True for 2 seconds after the user copies their invite code.
    @State private var didCopyInviteCode: Bool = false
    /// True while the sign-out request is in flight.
    @State private var isSigningOut: Bool = false

    // WeChat Pay order flow states
    /// Set when a WeChat Pay order has been successfully created. Triggers QR code display.
    @State private var activePendingOrder: WeChatPayOrder? = nil
    /// Plan ("pro"/"premium") currently being ordered — shows a spinner on that button.
    @State private var orderCreationLoadingPlan: String? = nil
    /// Shown when order creation fails.
    @State private var orderCreationErrorMessage: String? = nil
    /// True once polling confirms payment success.
    @State private var isPaymentConfirmed: Bool = false
    /// Background Task that polls payment status every 3 seconds.
    @State private var paymentPollingTask: Task<Void, Never>? = nil

    // MARK: - Plan limit helpers (must stay in sync with Worker)

    private let planDailyLimits: [String: Int] = ["free": 20, "pro": 200, "premium": 999_999]

    private var currentPlan: String { supabaseAuthManager.userProfile?.plan ?? "free" }

    private var currentPlanDailyLimit: Int { planDailyLimits[currentPlan] ?? 20 }

    private var currentDailyUsed: Int { supabaseAuthManager.userProfile?.dailyChatCount ?? 0 }

    private var dailyUsageRatio: Double {
        Double(currentDailyUsed) / Double(max(currentPlanDailyLimit, 1))
    }

    private var dailyUsageColor: Color {
        let ratio = dailyUsageRatio
        if ratio < 0.75 { return DS.Colors.success }
        if ratio < 1.0  { return .orange }
        return .red
    }

    // MARK: - Body

    var body: some View {
        // No ScrollView — let VStack size to its content so the panel height adapts
        // automatically. NSHostingView propagates the intrinsic content size to NSPanel.
        VStack(alignment: .leading, spacing: 16) {
            headerRow
            divider
            if hasInviteCode {
                inviteSection
                divider
            }
            subscriptionSection
            divider
            signOutButton
        }
        .padding(20)
        .frame(width: 320)
        // Clip content to the same rounded shape as the main panel, then apply the
        // panel background (dark fill + shadows) behind the clipped content.
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.background)
                .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
                .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
        )
        .animation(.easeInOut(duration: DS.Animation.normal), value: activePendingOrder == nil)
        .animation(.easeInOut(duration: DS.Animation.normal), value: isPaymentConfirmed)
        .onDisappear {
            // Cancel polling when the user navigates away.
            paymentPollingTask?.cancel()
        }
    }

    /// Only show the invite section when the user actually has an invite code to share.
    private var hasInviteCode: Bool {
        supabaseAuthManager.userProfile?.inviteCode != nil
    }

    /// Thin separator line using the DS border token.
    private var divider: some View {
        Rectangle()
            .fill(DS.Colors.borderSubtle)
            .frame(height: 0.5)
    }

    // MARK: - Header row

    private var headerRow: some View {
        HStack(spacing: 10) {
            Button(action: {
                paymentPollingTask?.cancel()
                onDismiss()
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(6)
                    .background(Circle().fill(DS.Colors.surface2))
            }
            .buttonStyle(.plain)
            .pointerCursor()

            // Manual profile refresh — lets the user pull the latest plan/quota
            // from Supabase without restarting the app (e.g. right after a payment).
            Button(action: {
                Task { await SupabaseAuthManager.shared.fetchUserProfile() }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .rotationEffect(supabaseAuthManager.isFetchingProfile ? .degrees(360) : .zero)
                    .animation(
                        supabaseAuthManager.isFetchingProfile
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : .default,
                        value: supabaseAuthManager.isFetchingProfile
                    )
                    .padding(6)
                    .background(Circle().fill(DS.Colors.surface2))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(supabaseAuthManager.isFetchingProfile)

            ZStack {
                Circle()
                    .fill(DS.Colors.accent.opacity(0.2))
                    .frame(width: 36, height: 36)
                Text(emailInitial)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(supabaseAuthManager.currentSession?.user.email ?? "已登录")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(planBadgeLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(planBadgeColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(planBadgeColor.opacity(0.15)))
            }

            Spacer()
        }
    }

    private var emailInitial: String {
        let email = supabaseAuthManager.currentSession?.user.email ?? ""
        let initial = String(email.prefix(1)).uppercased()
        return initial.isEmpty ? "?" : initial
    }

    private var planBadgeLabel: String {
        switch currentPlan {
        case "pro":     return "Pro"
        case "premium": return "Premium"
        default:        return "免费版"
        }
    }

    private var planBadgeColor: Color {
        switch currentPlan {
        case "premium": return .yellow
        case "pro":     return DS.Colors.accent
        default:        return DS.Colors.textTertiary
        }
    }

    // MARK: - Usage section

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("今日用量")

            VStack(spacing: 8) {
                HStack {
                    Text("对话次数")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Text("\(currentDailyUsed) / \(currentPlanDailyLimit == 999_999 ? "∞" : "\(currentPlanDailyLimit)")")
                        .font(.system(size: 11, weight: .semibold).monospaced())
                        .foregroundColor(dailyUsageColor)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Track
                        Capsule()
                            .fill(DS.Colors.surface3)
                            .frame(height: 5)
                        // Fill
                        Capsule()
                            .fill(dailyUsageColor)
                            .frame(width: max(geo.size.width * min(dailyUsageRatio, 1.0), 4), height: 5)
                    }
                }
                .frame(height: 5)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(DS.Colors.surface1)
            )

            if let profile = supabaseAuthManager.userProfile, profile.totalChatCount > 0 {
                HStack {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text("累计对话")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Text("\(profile.totalChatCount) 次")
                        .font(.system(size: 11, weight: .semibold).monospaced())
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(DS.Colors.surface1)
                )
            }
        }
    }

    // MARK: - Invite section

    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("邀请好友")

            if let profile = supabaseAuthManager.userProfile,
               let inviteCode = profile.inviteCode {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("我的邀请码")
                            .font(.system(size: 9))
                            .foregroundColor(DS.Colors.textTertiary)
                        Text(inviteCode)
                            .font(.system(size: 13, weight: .bold).monospaced())
                            .foregroundColor(DS.Colors.textPrimary)
                            .tracking(2)
                    }

                    Spacer()

                    if profile.invitedCount > 0 {
                        VStack(spacing: 1) {
                            Text("\(profile.invitedCount)")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(DS.Colors.accent)
                            Text("已邀请")
                                .font(.system(size: 9))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    }

                    Button(action: { copyInviteCodeToPasteboard(inviteCode) }) {
                        HStack(spacing: 4) {
                            Image(systemName: didCopyInviteCode ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                            Text(didCopyInviteCode ? "已复制" : "复制")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(didCopyInviteCode ? DS.Colors.success : DS.Colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.surface3)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .animation(.easeInOut(duration: DS.Animation.fast), value: didCopyInviteCode)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(DS.Colors.surface1)
                )
            }
        }
    }

    // MARK: - Subscription section

    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("套餐")

            if currentPlan == "free" {
                freeUserUpgradeCard
            } else {
                paidUserInfoCard
            }
        }
    }

    // MARK: Upgrade card (free users)

    private var freeUserUpgradeCard: some View {
        VStack(spacing: 10) {
            if let order = activePendingOrder {
                weChatQRCodeView(order: order)
            } else {
                // Compact daily usage row — shows free quota at a glance
                HStack {
                    Text("今日对话")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Text("\(currentDailyUsed) / \(currentPlanDailyLimit)")
                        .font(.system(size: 11, weight: .semibold).monospaced())
                        .foregroundColor(dailyUsageColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(DS.Colors.surface1)
                )

                HStack(spacing: 8) {
                    weChatUpgradeButton(planName: "pro",     displayName: "Pro",     priceLabel: "¥29/月", dailyLimitLabel: "200 次/天")
                    weChatUpgradeButton(planName: "premium", displayName: "Premium", priceLabel: "¥99/月", dailyLimitLabel: "无限制")
                }

                if let errorMessage = orderCreationErrorMessage {
                    Text(errorMessage)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.destructiveText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }

                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                    Text("微信支付 · 安全加密")
                }
                .font(.system(size: 9))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .animation(.easeInOut(duration: DS.Animation.normal), value: activePendingOrder == nil)
        .animation(.easeInOut(duration: DS.Animation.normal), value: orderCreationErrorMessage)
    }

    // MARK: WeChat Pay QR code view

    @ViewBuilder
    private func weChatQRCodeView(order: WeChatPayOrder) -> some View {
        VStack(spacing: 12) {
            if isPaymentConfirmed {
                // Success state
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(DS.Colors.success)
                    Text("支付成功！")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("\(order.plan.capitalized) 套餐已激活")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                // QR code display state
                VStack(spacing: 10) {
                    // Plan + price header
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(order.plan.capitalized) 套餐")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text("¥\(order.amountFen / 100) / 月")
                                .font(.system(size: 10))
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                        Spacer()
                        // Cancel — stops polling and returns to upgrade buttons
                        Button(action: cancelWeChatPayOrder) {
                            Text("取消")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                        .fill(DS.Colors.surface3)
                                )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }

                    // QR code image generated from the code_url
                    if let qrImage = makeQRCodeImage(from: order.codeURL, size: 200) {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 200, height: 200)
                            .background(Color.white)
                            .cornerRadius(DS.CornerRadius.large)
                    } else {
                        // Fallback: show the URL as text so the user can copy it
                        Text(order.codeURL)
                            .font(.system(size: 9).monospaced())
                            .foregroundColor(DS.Colors.textTertiary)
                            .frame(width: 200, height: 200, alignment: .topLeading)
                    }

                    HStack(spacing: 5) {
                        ProgressView().scaleEffect(0.55)
                        Text("请用微信扫码支付，完成后自动跳转")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.accent.opacity(0.3), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: DS.Animation.normal), value: isPaymentConfirmed)
    }

    // MARK: Paid user info card

    private var paidUserInfoCard: some View {
        VStack(spacing: 0) {
            // Plan + status row
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前套餐")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text(currentPlan.capitalized)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(planBadgeColor)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 20))
                        .foregroundColor(planBadgeColor.opacity(0.8))
                    Text("已激活")
                        .font(.system(size: 9))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Usage bar — shows daily quota progress inside the paid card too
            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 0.5)
                .padding(.horizontal, 12)

            VStack(spacing: 6) {
                HStack {
                    Text("今日对话")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Text("\(currentDailyUsed) / \(currentPlanDailyLimit == 999_999 ? "∞" : "\(currentPlanDailyLimit)")")
                        .font(.system(size: 11, weight: .semibold).monospaced())
                        .foregroundColor(dailyUsageColor)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(DS.Colors.surface3)
                            .frame(height: 4)
                        Capsule()
                            .fill(dailyUsageColor)
                            .frame(width: max(geo.size.width * min(dailyUsageRatio, 1.0), 4), height: 4)
                    }
                }
                .frame(height: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
    }

    // MARK: - Sign out

    private var signOutButton: some View {
        Button(action: performSignOut) {
            HStack(spacing: 6) {
                if isSigningOut {
                    ProgressView().scaleEffect(0.65)
                } else {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 11))
                }
                Text("退出登录")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(DS.Colors.destructiveText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.destructive.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.destructive.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isSigningOut)
        .pointerCursor()
    }

    // MARK: - Section title helper

    @ViewBuilder
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(DS.Colors.textTertiary)
            .textCase(.uppercase)
            .tracking(0.8)
    }

    // MARK: - WeChat Pay upgrade button

    @ViewBuilder
    private func weChatUpgradeButton(
        planName: String,
        displayName: String,
        priceLabel: String,
        dailyLimitLabel: String
    ) -> some View {
        let isThisPlanLoading = orderCreationLoadingPlan == planName
        let isAnyPlanLoading  = orderCreationLoadingPlan != nil

        Button(action: { performCreateWeChatOrder(plan: planName) }) {
            VStack(spacing: 3) {
                if isThisPlanLoading {
                    ProgressView().scaleEffect(0.7).frame(height: 20)
                } else {
                    Text(displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text(priceLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textOnAccent.opacity(0.9))
                    Text(dailyLimitLabel)
                        .font(.system(size: 9))
                        .foregroundColor(DS.Colors.textOnAccent.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(DS.Colors.accent.opacity(isAnyPlanLoading && !isThisPlanLoading ? 0.2 : 0.65))
            )
        }
        .buttonStyle(.plain)
        .disabled(isAnyPlanLoading)
        .pointerCursor()
        .animation(.easeInOut(duration: DS.Animation.fast), value: isThisPlanLoading)
    }

    // MARK: - QR code generation (CoreImage)

    /// Shared CIContext — creating one per call is expensive; reuse across renders.
    private static let ciContext = CIContext()

    /// Generates a high-contrast black-on-white QR code NSImage from a URL string.
    /// Scales the raw CIFilter output to `size` × `size` points using nearest-neighbor
    /// interpolation to keep pixels crisp at any display scale.
    private func makeQRCodeImage(from urlString: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message         = Data(urlString.utf8)
        filter.correctionLevel = "M"

        guard let rawCIImage = filter.outputImage else { return nil }

        let scaleFactor = size / rawCIImage.extent.width
        let scaledCIImage = rawCIImage.transformed(
            by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)
        )

        guard let cgImage = Self.ciContext.createCGImage(scaledCIImage, from: scaledCIImage.extent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    // MARK: - Actions

    private func copyInviteCodeToPasteboard(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        didCopyInviteCode = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            didCopyInviteCode = false
        }
    }

    /// Creates a WeChat Pay Native order and transitions to the QR code view.
    /// Starts background polling as soon as the order is confirmed by the Worker.
    private func performCreateWeChatOrder(plan: String) {
        guard orderCreationLoadingPlan == nil else { return }
        orderCreationErrorMessage = nil
        orderCreationLoadingPlan  = plan

        Task {
            do {
                let order = try await WeChatPayClient.shared.createOrder(plan: plan)
                activePendingOrder = order
                startPollingPaymentStatus(outTradeNo: order.outTradeNo)
            } catch {
                orderCreationErrorMessage = error.localizedDescription
            }
            orderCreationLoadingPlan = nil
        }
    }

    /// Cancels the active WeChat Pay order UI — stops polling and hides the QR code.
    /// Note: the WeChat Pay order itself stays open server-side and expires naturally.
    private func cancelWeChatPayOrder() {
        paymentPollingTask?.cancel()
        paymentPollingTask = nil
        activePendingOrder = nil
        isPaymentConfirmed = false
    }

    /// Polls GET /check-payment-status every 3 seconds until paid or 5-minute timeout.
    /// On success: refreshes the user profile so the plan badge updates, then dismisses.
    private func startPollingPaymentStatus(outTradeNo: String) {
        paymentPollingTask?.cancel()
        paymentPollingTask = Task { @MainActor in
            // Poll up to 100 times × 3 seconds = 5 minutes (WeChat Pay QR codes expire in
            // 2 hours, but 5 minutes is a practical UX timeout for this flow).
            for _ in 0..<100 {
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                } catch {
                    return // Task was cancelled
                }
                guard !Task.isCancelled else { return }

                let paid = (try? await WeChatPayClient.shared.checkPaymentStatus(outTradeNo: outTradeNo)) ?? false
                if paid {
                    isPaymentConfirmed = true
                    // Fetch latest profile before dismissing so plan badge shows the new plan.
                    await SupabaseAuthManager.shared.fetchUserProfile()
                    // Show the success state for 2 seconds, then auto-dismiss.
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    cancelWeChatPayOrder()
                    return
                }
            }
            // Polling timed out — show an error and reset so the user can retry.
            orderCreationErrorMessage = "支付超时，请重新发起支付。"
            cancelWeChatPayOrder()
        }
    }

    private func performSignOut() {
        isSigningOut = true
        paymentPollingTask?.cancel()
        Task {
            await SupabaseAuthManager.shared.signOut()
            isSigningOut = false
            onDismiss()
        }
    }
}
