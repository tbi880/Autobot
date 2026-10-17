// ContentView.swift
// Dashboard: connection status, speed, lamp state, assistant status, packet log.

import SwiftUI

struct ContentView: View {
    @StateObject private var app = AppModel()
    @State private var showingPlaces = false

    var body: some View {
        VStack(spacing: 16) {
            ConnectionStatusView(lamp: app.lamp, carPlay: app.carPlay)
            SpeedView(speed: app.speed)
            LampStateView(speed: app.speed, lamp: app.lamp)
            AssistantView(assistant: app.assistant, onTest: app.testWelcome)
            VoiceTestView(onTest: app.testPowerVoice)
            SavedPlacesButton(store: app.places) { showingPlaces = true }
            PacketLogView(lamp: app.lamp)
        }
        .padding()
        .onAppear { app.start() }
        .sheet(isPresented: $showingPlaces) {
            SavedPlacesView(store: app.places)
        }
    }
}

// MARK: - Sections

private struct ConnectionStatusView: View {
    @ObservedObject var lamp: LampController
    @ObservedObject var carPlay: CarPlayMonitor

    var body: some View {
        VStack(spacing: 4) {
            Text(lamp.status).font(.headline)
            Label(carPlay.isConnected ? "CarPlay connected" : "CarPlay not detected",
                  systemImage: carPlay.isConnected ? "car.fill" : "car")
                .font(.subheadline)
                .foregroundColor(carPlay.isConnected ? .green : .secondary)
        }
        .multilineTextAlignment(.center)
    }
}

private struct SpeedView: View {
    @ObservedObject var speed: SpeedMonitor

    var body: some View {
        VStack(spacing: 4) {
            Text(speed.speedKmh.map { String(format: "%.0f", $0) } ?? "--")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("km/h  ·  Power Mode at \(Int(AppConfig.Speed.powerModeThresholdKmh))")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Location: \(speed.authorization)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

private struct LampStateView: View {
    @ObservedObject var speed: SpeedMonitor
    @ObservedObject var lamp: LampController

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Circle()
                    .fill(speed.state == .redBreathing ? Color.red : Color(red: 0.5, green: 0, blue: 1))
                    .frame(width: 16, height: 16)
                Text(speed.state.label).font(.title3.bold())
            }
            Text(lamp.appliedState == speed.state ? "Sent to lamp" : "Waiting for lamp…")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

private struct AssistantView: View {
    @ObservedObject var assistant: WelcomeAssistant
    let onTest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Assistant").font(.headline)
                Spacer()
                Button("Test welcome", action: onTest)
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
            Text(assistant.status).font(.subheadline)
            if let heard = assistant.lastHeard {
                Text("Heard: \"\(heard)\"").font(.caption)
            }
            if let destination = assistant.lastDestination {
                Text("Destination: \(destination)").font(.caption.bold())
            }
            Text("Understanding: \(assistant.understandingEngine)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(10)
    }
}

private struct VoiceTestView: View {
    let onTest: (LampState) -> Void

    var body: some View {
        HStack {
            Text("Voice test").font(.headline)
            Spacer()
            Button("Power ON") { onTest(.redBreathing) }
                .tint(.red)
            Button("Power OFF") { onTest(.purpleSteady) }
                .tint(Color(red: 0.5, green: 0, blue: 1))
        }
        .font(.caption)
        .buttonStyle(.bordered)
    }
}

private struct SavedPlacesButton: View {
    @ObservedObject var store: SavedPlacesStore
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Label("Saved places", systemImage: "mappin.and.ellipse")
                Spacer()
                Text("\(store.places.count)").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .font(.headline)
        }
        .buttonStyle(.plain)
    }
}

private struct PacketLogView: View {
    @ObservedObject var lamp: LampController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lamp.log.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.caption, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
