// BootView.swift
// Start screen. A big ENGINE START STOP button in the middle of the screen; pressing it cranks the
// engine (click, haptics, sound, screen shake), and when the engine fires there's a flash,
// shockwaves and sparks while the button folds into a tachometer-style progress ring.
// The ring then fills as the lamp, the OBD2 adapter and car audio connect: it waits at 30 / 60 / 90 %
// for each in turn (rules in BootSequence).
//
// Everything is drawn from the time since the press (TimelineView), so the button → ring morph,
// the effects and the shake are one continuous animation that stays in sync with the sound.

import SwiftUI

struct BootView: View {
    @ObservedObject var boot: BootSequence
    let onIgnite: () -> Void

    var body: some View {
        // Frozen once the dashboard takes over: the exit transition then only moves one still
        // image instead of redrawing the whole gauge every frame.
        TimelineView(.animation(minimumInterval: 1 / 60, paused: boot.phase == .finished)) { timeline in
            let frame = BootFrame(boot: boot, now: timeline.date)
            GeometryReader { geo in
                let diameter = min((geo.size.width - 40) / 1.2, geo.size.height * 0.5, 340)
                ZStack {
                    IgnitionEffects(frame: frame, diameter: diameter)
                    Gauge(frame: frame, diameter: diameter,
                          onPressBegan: boot.pressBegan, onIgnite: onIgnite)
                }
                .offset(frame.shake)
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay(alignment: .top) {
                    BootHeader().padding(.top, 28)
                }
                .overlay(alignment: .bottom) {
                    BootFooter(frame: frame).padding(.bottom, 36)
                }
            }
            .background {
                BootBackground(frame: frame).ignoresSafeArea()
            }
        }
        .statusBarHidden()
    }
}

// MARK: - Frame

/// Everything the screen needs for one frame, derived from the boot state and the time.
private struct BootFrame {
    let t: Double?                // seconds since the press (nil = not pressed yet)
    let clock: Double             // free-running seconds, for idle loops
    let progress: Double          // 0…100
    let completedAgo: Double?
    let holding: Bool
    let lampConnected: Bool
    let obdConnected: Bool
    let detailStatus: String
    let carAudioConnected: Bool
    let status: String

    init(boot: BootSequence, now: Date) {
        t = boot.ignitedAt.map { now.timeIntervalSince($0) }
        clock = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
        progress = boot.progress
        completedAgo = boot.completedAt.map { now.timeIntervalSince($0) }
        holding = boot.isHolding
        lampConnected = boot.lampConnected
        obdConnected = boot.obdConnected
        detailStatus = boot.detailStatus
        carAudioConnected = boot.carAudioConnected
        status = boot.statusText
    }

    var ignited: Bool { t != nil }

    private var sinceFire: Double? { t.map { $0 - AppConfig.Boot.catchTime } }

    /// 0 = button, 1 = progress ring.
    var morph: Double { sinceFire.map { smoothstep($0 / AppConfig.Boot.morphDuration) } ?? 0 }

    /// Percentage readout and status chips.
    var readout: Double { sinceFire.map { smoothstep(($0 - 0.25) / 0.6) } ?? 0 }

    /// "PUSH TO START" hint.
    var hint: Double { 1 - smoothstep((t ?? 0) / 0.3) }

    /// Flash when the engine fires.
    var fireFlash: Double {
        guard let s = sinceFire, s >= 0 else { return 0 }
        return exp(-s * 3.5)
    }

    /// Flash when 100 % is reached.
    var completeFlash: Double { completedAgo.map { exp(-$0 * 3) } ?? 0 }

    /// LED ring brightness: slow breathing before the press, flickering while cranking.
    var led: Double {
        guard let t else { return 0.45 + 0.3 * sin(clock * 2 * .pi / 2.6) }
        if t < AppConfig.Boot.crankStart { return 1 }
        if t < AppConfig.Boot.catchTime { return 0.65 + 0.35 * sin(t * 2 * .pi * 7.3) }
        return 1
    }

    /// Light shake while cranking, a jolt when the engine fires.
    var shake: CGSize {
        guard let t, t >= AppConfig.Boot.crankStart else { return .zero }
        let amplitude: Double
        if t < AppConfig.Boot.catchTime {
            amplitude = 1.8 * (0.5 + 0.5 * sin(t * 2 * .pi * 7.3))
        } else {
            amplitude = 7 * exp(-(t - AppConfig.Boot.catchTime) * 5)
        }
        guard amplitude > 0.05 else { return .zero }
        let x = sin(t * 2 * .pi * 23) * amplitude
        let y = cos(t * 2 * .pi * 29 + 1) * amplitude * 0.6
        return CGSize(width: x, height: y)
    }

    /// Slow pulse while waiting at a checkpoint (1 when not waiting).
    var holdPulse: Double { holding ? 0.5 + 0.5 * sin(clock * 2 * .pi * 1.2) : 1 }
}

// MARK: - Gauge (button + ring)

private struct Gauge: View {
    let frame: BootFrame
    let diameter: CGFloat
    let onPressBegan: () -> Void
    let onIgnite: () -> Void

    var body: some View {
        let d = diameter
        let m = frame.morph
        let track = d * 0.86
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Palette.red.opacity(0.6), Palette.red.opacity(0)],
                                     center: .center, startRadius: d * 0.3, endRadius: d * 0.78))
                .frame(width: d * 1.6, height: d * 1.6)
                .opacity(halo)
                .allowsHitTesting(false)

            TickRing(progress: frame.progress, visibility: m, diameter: d)
            Bezel(diameter: d, clock: frame.clock)

            // Groove that holds the LED ring, and later the progress arc
            Circle()
                .stroke(Color.black, lineWidth: d * 0.075)
                .frame(width: track, height: track)
            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
                .frame(width: track + d * 0.075, height: track + d * 0.075)

            // LED ring: retracts clockwise into 12 o'clock, where the progress arc then starts
            Circle()
                .trim(from: m, to: 1)
                .stroke(Palette.red, style: StrokeStyle(lineWidth: d * 0.022, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: track, height: track)
                .shadow(color: Palette.red.opacity(0.9 * frame.led), radius: 3 + 9 * frame.led)
                .opacity((0.25 + 0.75 * frame.led) * (1 - smoothstep((m - 0.85) / 0.15)))

            ProgressArc(frame: frame, diameter: track, lineWidth: d * 0.042)

            Button(action: onIgnite) {
                EngineButtonFace(diameter: d * 0.72, led: frame.led)
            }
            .buttonStyle(IgnitionButtonStyle(onPressBegan: onPressBegan))
            .scaleEffect(1 - 0.22 * m)
            .opacity(1 - m)
            .allowsHitTesting(!frame.ignited)
            .accessibilityLabel("Engine start")

            Readout(frame: frame, diameter: d)
        }
        .frame(width: d * 1.2, height: d * 1.2)
    }

    private var halo: Double {
        let idle = 0.18 + 0.3 * frame.led * (1 - frame.morph)
        let ring = 0.25 * frame.morph * frame.progress / 100
        return min(1, idle + ring + 0.7 * frame.fireFlash + 0.6 * frame.completeFlash)
    }
}

private struct EngineButtonFace: View {
    let diameter: CGFloat
    let led: Double

    var body: some View {
        let d = diameter
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.21), Color(white: 0.05)],
                                     startPoint: .top, endPoint: .bottom)
                    .shadow(.inner(color: .black.opacity(0.85), radius: d * 0.04, y: -d * 0.012)))
            Circle()
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.3), Color.white.opacity(0.03),
                                                      Color.black.opacity(0.6)],
                                             startPoint: .top, endPoint: .bottom),
                              lineWidth: 1.5)
            Ellipse()
                .fill(LinearGradient(colors: [Color.white.opacity(0.11), Color.white.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: d * 0.74, height: d * 0.42)
                .offset(y: -d * 0.24)

            VStack(spacing: d * 0.018) {
                Image(systemName: "power")
                    .font(.system(size: d * 0.14, weight: .bold))
                    .foregroundStyle(Palette.red)
                    .shadow(color: Palette.red.opacity(led), radius: 2 + 8 * led)
                    .opacity(0.45 + 0.55 * led)
                Text("ENGINE")
                    .font(.system(size: d * 0.08, weight: .heavy))
                    .tracking(d * 0.018)
                Text("START")
                    .font(.system(size: d * 0.12, weight: .black))
                    .tracking(d * 0.012)
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: d * 0.3, height: 1.5)
                Text("STOP")
                    .font(.system(size: d * 0.07, weight: .heavy))
                    .tracking(d * 0.018)
                    .opacity(0.65)
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .offset(y: d * 0.01)
        }
        .frame(width: d, height: d)
        .contentShape(Circle())
    }
}

/// Presses in like a real button; reports the touch-down so audio/haptics can get ready.
private struct IgnitionButtonStyle: ButtonStyle {
    let onPressBegan: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.55), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { onPressBegan() }
            }
    }
}

private struct Bezel: View {
    let diameter: CGFloat
    let clock: Double

    var body: some View {
        let width = diameter * 0.05
        let metal = [0.55, 0.18, 0.7, 0.22, 0.62, 0.16, 0.55].map { Color(white: $0) }
        ZStack {
            Circle()
                .strokeBorder(AngularGradient(colors: metal, center: .center,
                                              startAngle: .degrees(0), endAngle: .degrees(360)),
                              lineWidth: width)
            // Moving reflection
            Circle()
                .strokeBorder(AngularGradient(colors: [Color.white.opacity(0), Color.white.opacity(0.6),
                                                       Color.white.opacity(0)],
                                              center: .center,
                                              startAngle: .degrees(0), endAngle: .degrees(70)),
                              lineWidth: width)
                .rotationEffect(.degrees((clock * 24).truncatingRemainder(dividingBy: 360)))
                .blendMode(.plusLighter)
            Circle()
                .strokeBorder(Color.black.opacity(0.7), lineWidth: 1)
            Circle()
                .stroke(Color.black.opacity(0.8), lineWidth: 1.5)
                .frame(width: diameter - width * 2, height: diameter - width * 2)
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }
}

/// Tachometer ticks around the bezel; they light up with the progress.
/// The checkpoint ticks (30 / 60 / 90 %, where it can wait) are longer.
private struct TickRing: View {
    let progress: Double
    let visibility: Double
    let diameter: CGFloat

    var body: some View {
        Canvas { context, size in
            let cx = Double(size.width) / 2
            let cy = Double(size.height) / 2
            let d = Double(diameter)
            let count = 50
            let checkpoints = [AppConfig.Boot.lampCheckpoint, AppConfig.Boot.obdCheckpoint,
                               AppConfig.Boot.carAudioCheckpoint].map { Int(($0 / 100 * Double(count)).rounded()) }
            for i in 0..<count {
                let fraction = Double(i) / Double(count)
                let angle = -Double.pi / 2 + fraction * 2 * Double.pi
                let milestone = checkpoints.contains(i)
                let major = i % 5 == 0
                let inner = d * (milestone ? 0.528 : (major ? 0.535 : 0.545))
                let outer = d * (milestone ? 0.59 : 0.575)
                var path = Path()
                path.move(to: CGPoint(x: cx + cos(angle) * inner, y: cy + sin(angle) * inner))
                path.addLine(to: CGPoint(x: cx + cos(angle) * outer, y: cy + sin(angle) * outer))
                let lit = visibility > 0.5 && progress > fraction * 100
                let dim = (milestone ? 0.35 : 0.13) + 0.12 * visibility
                let color = lit ? Palette.gauge(fraction) : Color.white.opacity(dim)
                let width: CGFloat = (major || milestone) ? 2.5 : 1.4
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
        .frame(width: diameter * 1.2, height: diameter * 1.2)
        .allowsHitTesting(false)
    }
}

private struct ProgressArc: View {
    let frame: BootFrame
    let diameter: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        let p = frame.progress / 100
        let visible = p > 0.0005
        let gradient = AngularGradient(colors: [Palette.red, Palette.orange, Palette.amber], center: .center,
                                       startAngle: .degrees(0), endAngle: .degrees(360))
        let angle = (-90 + 360 * p) * Double.pi / 180
        let radius = Double(diameter) / 2
        ZStack {
            // Scanning sweep while waiting at a checkpoint (30 / 60 / 90 %)
            Circle()
                .trim(from: 0, to: 0.16)
                .stroke(AngularGradient(colors: [Palette.orange.opacity(0), Palette.orange.opacity(0.55)],
                                        center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(0.16 * 360)),
                        style: StrokeStyle(lineWidth: lineWidth * 0.8, lineCap: .butt))
                .rotationEffect(.degrees((frame.clock * 200).truncatingRemainder(dividingBy: 360)))
                .opacity(frame.holding ? 0.9 : 0)

            Group {
                Circle()
                    .trim(from: 0, to: p)
                    .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth * 1.4, lineCap: .round))
                    .blur(radius: lineWidth * 0.5)
                    .opacity(0.85)
                Circle()
                    .trim(from: 0, to: p)
                    .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            .rotationEffect(.degrees(-90))
            .brightness(0.35 * frame.completeFlash)
            .opacity(visible ? 1 : 0)

            // Glowing tip
            Circle()
                .fill(Color.white)
                .frame(width: lineWidth * 0.62, height: lineWidth * 0.62)
                .shadow(color: Palette.amber, radius: lineWidth * 0.5)
                .shadow(color: Palette.orange, radius: lineWidth)
                .offset(x: cos(angle) * radius, y: sin(angle) * radius)
                .opacity(visible ? frame.holdPulse : 0)
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }
}

private struct Readout: View {
    let frame: BootFrame
    let diameter: CGFloat

    var body: some View {
        let d = diameter
        VStack(spacing: d * 0.012) {
            HStack(alignment: .firstTextBaseline, spacing: d * 0.006) {
                Text(verbatim: "\(Int(frame.progress))")
                    .font(.system(size: d * 0.21, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text(verbatim: "%")
                    .font(.system(size: d * 0.07, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .foregroundStyle(Color.white)
            .shadow(color: Palette.orange.opacity(0.35), radius: 12)

            Text(frame.status.uppercased())
                .font(.system(size: d * 0.034, weight: .semibold))
                .tracking(d * 0.006)
                .foregroundStyle(Palette.amber)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: d * 0.6)
                .opacity(0.4 + 0.6 * frame.holdPulse)
        }
        .scaleEffect(0.85 + 0.15 * frame.readout)
        .opacity(frame.readout)
        .allowsHitTesting(false)
    }
}

// MARK: - Effects

/// Press ripple; flash, shockwaves and sparks when the engine fires; a burst at 100 %.
private struct IgnitionEffects: View {
    let frame: BootFrame
    let diameter: CGFloat

    var body: some View {
        Canvas { context, size in
            guard let t = frame.t else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let d = Double(diameter)
            let completedAgo = frame.completedAgo
            context.blendMode = .plusLighter
            context.drawLayer { glow in
                glow.addFilter(.blur(radius: 7))
                Self.draw(in: glow, t: t, completedAgo: completedAgo, center: center, d: d)
            }
            Self.draw(in: context, t: t, completedAgo: completedAgo, center: center, d: d)
        }
        .allowsHitTesting(false)
    }

    private static func draw(in context: GraphicsContext, t: Double, completedAgo: Double?,
                             center: CGPoint, d: Double) {
        // Press ripple
        if t < 0.7 {
            let p = t / 0.7
            ring(context, center, radius: d / 2 * (1 + 0.3 * easeOut(p)), width: 1 + 3 * (1 - p),
                 color: Color.white.opacity(0.5 * (1 - p)))
        }

        let s = t - AppConfig.Boot.catchTime
        if s >= 0 && s < 1.6 {
            // Bloom
            let bloom = exp(-s * 4)
            if bloom > 0.01 {
                let rect = CGRect(x: Double(center.x) - d, y: Double(center.y) - d, width: d * 2, height: d * 2)
                let colors = [Palette.amber.opacity(0.5 * bloom), Palette.red.opacity(0.25 * bloom),
                              Palette.red.opacity(0)]
                context.fill(Path(ellipseIn: rect),
                             with: .radialGradient(Gradient(colors: colors), center: center,
                                                   startRadius: d * 0.2, endRadius: d))
            }
            // Shockwaves
            for k in 0..<3 {
                let p = s - Double(k) * 0.11
                guard p > 0, p < 1 else { continue }
                let color = k == 0 ? Palette.amber : Palette.red
                ring(context, center, radius: d / 2 * (1 + 1.5 * easeOut(p)), width: 1 + d * 0.035 * (1 - p),
                     color: color.opacity(0.85 * pow(1 - p, 1.5)))
            }
            // Sparks
            let cx = Double(center.x)
            let cy = Double(center.y)
            for i in 0..<44 {
                let life = 0.5 + 0.5 * hash01(i, 1)
                let p = s / life
                guard p < 1 else { continue }
                let angle = Double(i) / 44 * 2 * Double.pi + (hash01(i, 2) - 0.5) * 0.35
                let speed = d * (0.8 + 1.7 * hash01(i, 3))
                let distance = d * 0.5 + speed * s * (1 - 0.45 * p)
                let trail = d * 0.07 * (1 - p) + 2
                let dx = cos(angle)
                let dy = sin(angle)
                var path = Path()
                path.move(to: CGPoint(x: cx + dx * (distance - trail), y: cy + dy * (distance - trail)))
                path.addLine(to: CGPoint(x: cx + dx * distance, y: cy + dy * distance))
                let color = p < 0.25 ? Color.white : (p < 0.6 ? Palette.amber : Palette.red)
                context.stroke(path, with: .color(color.opacity(1 - p)),
                               style: StrokeStyle(lineWidth: 1 + 2 * (1 - p), lineCap: .round))
            }
        }

        // 100 %
        if let p = completedAgo, p < 1 {
            ring(context, center, radius: d * 0.43 + d * 0.55 * easeOut(p), width: 1 + d * 0.03 * (1 - p),
                 color: Color.white.opacity(0.8 * pow(1 - p, 1.4)))
            ring(context, center, radius: d * 0.43 + d * 0.35 * easeOut(p), width: 1 + d * 0.02 * (1 - p),
                 color: Palette.amber.opacity(0.6 * (1 - p)))
        }
    }

    private static func ring(_ context: GraphicsContext, _ center: CGPoint, radius: Double, width: Double,
                             color: Color) {
        let rect = CGRect(x: Double(center.x) - radius, y: Double(center.y) - radius,
                          width: radius * 2, height: radius * 2)
        context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: width)
    }
}

// MARK: - Header, footer, background

private struct BootHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(LinearGradient(colors: [Palette.red.opacity(0), Palette.red.opacity(0.7)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 44, height: 1)
            Text("AUTOBOT")
                .font(.system(size: 13, weight: .heavy))
                .tracking(7)
                .foregroundStyle(Color.white.opacity(0.55))
            Rectangle()
                .fill(LinearGradient(colors: [Palette.red.opacity(0.7), Palette.red.opacity(0)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 44, height: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct BootFooter: View {
    let frame: BootFrame

    var body: some View {
        ZStack {
            Text("PUSH TO START")
                .font(.system(size: 13, weight: .bold))
                .tracking(5)
                .foregroundStyle(Color.white.opacity(0.75))
                .opacity(frame.hint * (0.55 + 0.45 * frame.led))

            VStack(spacing: 10) {
                // All three in a row when they fit, otherwise lamp + OBD2 above car audio
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        lampChip
                        obdChip
                        carAudioChip
                    }
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            lampChip
                            obdChip
                        }
                        carAudioChip
                    }
                }
                .padding(.horizontal, 16)
                // What the connection being waited for is doing, so a problem is visible on this screen
                Text(frame.detailStatus)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 24)
            }
            .opacity(frame.readout)
            .offset(y: 12 * (1 - frame.readout))
        }
        .allowsHitTesting(false)
    }

    private var lampChip: some View {
        StatusChip(icon: "lightbulb.fill", title: "Lamp",
                   detail: frame.lampConnected ? "Connected" : "Searching…",
                   connected: frame.lampConnected, clock: frame.clock)
    }

    private var obdChip: some View {
        StatusChip(icon: "gauge.with.dots.needle.33percent", title: "OBD2",
                   detail: frame.obdConnected ? "Connected" : (frame.lampConnected ? "Searching…" : "Next"),
                   connected: frame.obdConnected, clock: frame.clock)
    }

    private var carAudioChip: some View {
        StatusChip(icon: "car.fill", title: "Car audio",
                   detail: frame.carAudioConnected ? "Connected" : "Waiting…",
                   connected: frame.carAudioConnected, clock: frame.clock)
    }
}

private struct StatusChip: View {
    let icon: String
    let title: String
    let detail: String
    let connected: Bool
    let clock: Double

    var body: some View {
        let tint = connected ? Palette.green : Palette.amber
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.5)
                    .foregroundStyle(Color.white.opacity(0.85))
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .shadow(color: tint, radius: 4)
                .opacity(connected ? 1 : 0.35 + 0.65 * (0.5 + 0.5 * sin(clock * 2 * .pi * 1.5)))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(connected ? Palette.green.opacity(0.45) : Color.white.opacity(0.12),
                                        lineWidth: 1))
    }
}

private struct BootBackground: View {
    let frame: BootFrame

    var body: some View {
        let idle = 0.35 * frame.led * (1 - frame.morph)
        let ring = 0.3 * frame.morph * frame.progress / 100
        let energy = min(1, idle + ring + 0.8 * frame.fireFlash + 0.5 * frame.completeFlash)
        ZStack {
            Color.black
            RadialGradient(colors: [Color(red: 0.22, green: 0.04, blue: 0.03),
                                    Color(red: 0.06, green: 0.01, blue: 0.01), Color.black],
                           center: .center, startRadius: 0, endRadius: 520)
                .opacity(0.45 + 0.55 * energy)
        }
    }
}

// MARK: - Helpers

private enum Palette {
    static let red = Color(red: 1.0, green: 0.16, blue: 0.12)
    static let orange = Color(red: 1.0, green: 0.45, blue: 0.10)
    static let amber = Color(red: 1.0, green: 0.76, blue: 0.28)
    static let green = Color(red: 0.35, green: 0.92, blue: 0.55)

    /// Red → orange → amber along the ring (0…1).
    static func gauge(_ fraction: Double) -> Color {
        let f = min(max(fraction, 0), 1)
        let red = (1.0, 0.16, 0.12), orange = (1.0, 0.45, 0.10), amber = (1.0, 0.76, 0.28)
        let (a, b, k) = f < 0.5 ? (red, orange, f / 0.5) : (orange, amber, (f - 0.5) / 0.5)
        return Color(red: a.0 + (b.0 - a.0) * k, green: a.1 + (b.1 - a.1) * k, blue: a.2 + (b.2 - a.2) * k)
    }
}

private func smoothstep(_ x: Double) -> Double {
    let x = min(max(x, 0), 1)
    return x * x * (3 - 2 * x)
}

private func easeOut(_ x: Double) -> Double {
    let x = min(max(x, 0), 1)
    return 1 - pow(1 - x, 3)
}

/// Stable pseudo-random 0…1 for particle `index`.
private func hash01(_ index: Int, _ salt: Double) -> Double {
    let x = sin(Double(index) * 12.9898 + salt * 78.233) * 43758.5453
    return x - x.rounded(.down)
}
