// CarPlayMonitor.swift
// Detects CarPlay through the audio system: when CarPlay is connected the iPhone gets a
// "car audio" port, as an output and/or as an input (the car's microphone).
//
//   - connected:    reported once car audio has been present for AppConfig.CarPlay.connectDelay
//                   (0.5 s), so the head unit is ready before the greeting starts
//   - disconnected: reported only after car audio has been gone for a few seconds
//                   (AppConfig.CarPlay.disconnectGrace), so short blips don't count
//
// It re-checks on every route-change notification and also polls once a second, because
// with nothing playing iOS may not send a route change when CarPlay connects.

import AVFoundation
import Combine
import SwiftUI

final class CarPlayMonitor: ObservableObject {

    @Published private(set) var isConnected = false

    private var observer: NSObjectProtocol?
    private var pollTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var disconnectTask: Task<Void, Never>?

    func start() {
        if AppConfig.TestMode.enabled {
            isConnected = true
            return
        }
        guard observer == nil else { return }
        prepareSessionForInputDetection()

        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                try? await Task.sleep(for: AppConfig.CarPlay.pollInterval)
            }
        }
    }

    // MARK: Detection

    private func check() {
        if Self.carAudioPresent {
            disconnectTask?.cancel()
            disconnectTask = nil
            if !isConnected, connectTask == nil { scheduleConnect() }
        } else {
            connectTask?.cancel()                // gone before the delay passed
            connectTask = nil
            if isConnected, disconnectTask == nil { scheduleDisconnect() }
        }
    }

    /// Connected once car audio is still there after the short connect delay.
    private func scheduleConnect() {
        connectTask = Task { [weak self] in
            try? await Task.sleep(for: AppConfig.CarPlay.connectDelay)
            guard !Task.isCancelled, let self else { return }
            self.connectTask = nil
            if Self.carAudioPresent { self.isConnected = true }
        }
    }

    /// Disconnected only if car audio is still gone after the grace period.
    private func scheduleDisconnect() {
        disconnectTask = Task { [weak self] in
            try? await Task.sleep(for: AppConfig.CarPlay.disconnectGrace)
            guard !Task.isCancelled, let self else { return }
            self.disconnectTask = nil
            if !Self.carAudioPresent { self.isConnected = false }
        }
    }

    private static var carAudioPresent: Bool {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.contains { $0.portType == .carAudio }
        let inputs = session.availableInputs?.contains { $0.portType == .carAudio } ?? false
        return outputs || inputs
    }

    /// `availableInputs` is only filled in for a record-capable category. Setting the category
    /// without activating the session has no effect on other apps' audio; AudioSessionManager
    /// sets the real category whenever it activates the session.
    private func prepareSessionForInputDetection() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .default,
                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        } catch {
            print("CarPlay detection category error:", error)
        }
    }
}
