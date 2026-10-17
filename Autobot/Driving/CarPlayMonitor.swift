// CarPlayMonitor.swift
// Detects CarPlay by watching the audio route: when CarPlay is connected the
// iPhone's audio output becomes a "car audio" port.
//
// Every route change is re-checked after a settle delay (3 s), which
//   - gives the head unit time to finish connecting, and
//   - ignores short route blips (e.g. while this app switches its own audio mode).

import Combine
import AVFoundation
import SwiftUI

final class CarPlayMonitor: ObservableObject {

    @Published private(set) var isConnected = false

    private var observer: NSObjectProtocol?
    private var settleTask: Task<Void, Never>?

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.routeChanged() }
        }
        routeChanged()   // CarPlay may already be connected when the app starts
    }

    private func routeChanged() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: AppConfig.CarPlay.settleDelay)
            guard !Task.isCancelled, let self else { return }
            let connected = Self.isCarAudioRoute
            if connected != self.isConnected {
                self.isConnected = connected
            }
        }
    }

    private static var isCarAudioRoute: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
    }
}
