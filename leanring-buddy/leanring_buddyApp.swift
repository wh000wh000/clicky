//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Clicky: Starting...")
        print("🎯 Clicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        // Restore any persisted Supabase session from Keychain before the
        // companion starts, so proxy-mode API calls are authenticated immediately.
        Task {
            await SupabaseAuthManager.shared.restoreSession()
        }

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        // startSparkleUpdater()

        // Register for the Apple Event that macOS fires when a URL matching our
        // custom scheme (clicky://) is opened — works for both fresh launches and
        // already-running instances. This is the reliable mechanism for URL scheme
        // handling in macOS, especially for LSUIElement agent apps.
        // Event class 0x4755524C ('GURL') + event ID 0x4755524C ('GURL') is the
        // standard kInternetEventClass/kAEGetURL pair from Carbon's Internet.h.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(0x4755524C),
            andEventID:    AEEventID(0x4755524C)
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Called by macOS when the user opens a `clicky://` URL (e.g. by clicking
    /// the Supabase email confirmation link). Extracts the URL string from the
    /// Apple Event descriptor and forwards it to `SupabaseAuthManager`.
    @objc private func handleGetURLAppleEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        // keyDirectObject = 0x2D2D2D2D ('----') — the primary parameter of the event.
        guard
            let urlString = event.paramDescriptor(forKeyword: AEKeyword(0x2D2D2D2D))?.stringValue,
            let url = URL(string: urlString)
        else { return }

        Task {
            await SupabaseAuthManager.shared.handleAuthCallback(url: url)
        }
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Clicky: Registered as login item")
            } catch {
                print("⚠️ Clicky: Failed to register as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Clicky: Sparkle updater failed to start: \(error)")
        }
    }
}
