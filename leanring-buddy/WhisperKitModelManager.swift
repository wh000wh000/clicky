//
//  WhisperKitModelManager.swift
//  leanring-buddy
//
//  Singleton that manages the WhisperKit model download and load lifecycle.
//  The model is never auto-downloaded — it must be explicitly triggered by
//  the user via the Voice Engine row in the panel. Once downloaded it
//  persists on disk and survives app restarts.
//

import Combine
import Foundation
import WhisperKit

// MARK: - Model State

enum WhisperKitModelState: Equatable {
    /// WhisperKit has never been downloaded on this device.
    case notDownloaded
    /// A download is in progress. Progress is 0.0–1.0.
    case downloading(progress: Double)
    /// The model files are on disk and WhisperKit is loaded and ready.
    case ready
    /// A download or load failed. The message is user-readable.
    case failed(message: String)
}

// MARK: - WhisperKitModelManager

@MainActor
final class WhisperKitModelManager: ObservableObject {

    static let shared = WhisperKitModelManager()

    // MARK: - Published State

    @Published private(set) var modelState: WhisperKitModelState = .notDownloaded

    // MARK: - Configuration

    /// The variant to download. "large-v3-turbo" is ~800MB and gives the
    /// best accuracy-to-speed ratio on Apple Neural Engine hardware.
    static let modelVariant = "large-v3-turbo"

    /// Approximate download size shown in the UI.
    static let approximateModelSizeDescription = "~800 MB"

    // MARK: - Internal

    /// The loaded WhisperKit instance, available when modelState == .ready.
    private(set) var whisperKit: WhisperKit?

    private var downloadTask: Task<Void, Never>?

    // MARK: - Init

    private init() {
        checkIfModelAlreadyDownloaded()
    }

    // MARK: - Public API

    /// Starts a model download if not already downloading or ready.
    /// Safe to call multiple times — subsequent calls are no-ops if a
    /// download is already in progress or the model is already ready.
    func startDownload() {
        guard case .notDownloaded = modelState else { return }
        guard downloadTask == nil else { return }

        downloadTask = Task {
            modelState = .downloading(progress: 0)
            do {
                let whisperKitInstance = try await WhisperKit(
                    WhisperKitConfig(
                        model: Self.modelVariant,
                        verbose: true,
                        prewarm: true,
                        load: true
                    )
                )
                self.whisperKit = whisperKitInstance
                modelState = .ready
                print("🎙️ WhisperKit: model downloaded and ready (\(Self.modelVariant))")
            } catch is CancellationError {
                modelState = .notDownloaded
            } catch {
                modelState = .failed(message: error.localizedDescription)
                print("❌ WhisperKit: download/load failed: \(error)")
            }
            downloadTask = nil
        }
    }

    /// Cancels an in-progress download and resets state to notDownloaded.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        modelState = .notDownloaded
    }

    /// Whether WhisperKit is ready to transcribe audio right now.
    var isReady: Bool {
        if case .ready = modelState { return true }
        return false
    }

    // MARK: - Private

    /// Called on init — if the model folder already exists on disk, load it
    /// so the app is ready after a restart without re-downloading.
    private func checkIfModelAlreadyDownloaded() {
        Task {
            do {
                let whisperKitInstance = try await WhisperKit(
                    WhisperKitConfig(
                        model: Self.modelVariant,
                        verbose: false,
                        prewarm: true,
                        load: true
                    )
                )
                self.whisperKit = whisperKitInstance
                modelState = .ready
                print("🎙️ WhisperKit: existing model loaded on startup (\(Self.modelVariant))")
            } catch {
                // Model not present or failed to load — stay in notDownloaded.
                // This is the normal path on first launch.
                modelState = .notDownloaded
            }
        }
    }
}
