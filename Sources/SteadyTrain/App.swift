import SwiftUI

@main
struct SteadyTrainApp: App {
    @StateObject private var stabilizer = Stabilizer()

    var body: some Scene {
        MenuBarExtra {
            ControlPanel()
                .environmentObject(stabilizer)
        } label: {
            Image(systemName: stabilizer.lockedName == nil ? "tram" : "tram.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

struct ControlPanel: View {
    @EnvironmentObject var s: Stabilizer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ShakeGraph(points: s.history, range: s.maxOffset)
                .frame(height: 70)
            HStack(spacing: 12) {
                legend(.blue, "left / right")
                legend(.orange, "up / down")
                Spacer()
                Text(String(format: "shake %.1f mm", s.shakeMM))
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Divider()
            lockSection
            Divider()
            settings

            if !s.accessibilityOK {
                HStack {
                    Text("Moving windows needs Accessibility permission.")
                        .font(.caption)
                    Spacer()
                    Button("Grant…") { s.openAccessibilitySettings() }
                }
            }
            if let error = s.errorText {
                Text(error).font(.caption).foregroundStyle(.orange)
            }

            Divider()
            HStack {
                Button("Reset settings") { s.resetSettings() }
                Spacer()
                Button("Quit") { s.quit() }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 310)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(s.faceFound ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(s.faceFound ? "Tracking your head"
                 : (s.cameraRunning ? "Looking for your face…" : "Starting camera…"))
                .font(.headline)
            Spacer()
            Text("\(Int(s.fps.rounded())) fps · \(Int(s.latencyMs.rounded())) ms")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var lockSection: some View {
        if let name = s.lockedName {
            HStack {
                Label("Steadying \(name)", systemImage: "lock.fill")
                Spacer()
                Button("Release") { s.releaseWindow() }
            }
        } else if let count = s.countdown {
            Text("Click the window to steady… \(count)")
                .font(.headline)
        } else {
            Button("Steady a window") { s.beginLockCountdown() }
                .buttonStyle(.borderedProminent)
        }
        Text("Click the button, then click your window within 3 s. Or press ⌃⌥S in any window to lock or release it.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Toggle("Move the window (off = measure only)", isOn: $s.enabled)
            .font(.caption)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            slider("Strength", value: $s.gain, in: 0...2, format: "%.2f×")
            slider("Max shift", value: $s.maxOffset, in: 10...100, format: "%.0f pt")
            slider("Ignore movement slower than", value: $s.baselineHz, in: 0.2...2, format: "%.1f Hz")
            slider("Extra lookahead", value: $s.extraLookaheadMs, in: 0...80, format: "%.0f ms")
            HStack {
                Toggle("Flip left/right", isOn: $s.invertX)
                Toggle("Flip up/down", isOn: $s.invertY)
            }
            .font(.caption)
        }
    }

    private func slider(_ title: String, value: Binding<Double>,
                        in range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: value, in: range)
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 10, height: 3)
            Text(text)
        }
    }
}

/// Live plot of the window offset over the last few seconds.
struct ShakeGraph: View {
    let points: [CGPoint]
    let range: Double

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: mid))
            axis.addLine(to: CGPoint(x: size.width, y: mid))
            ctx.stroke(axis, with: .color(Color.secondary.opacity(0.3)), lineWidth: 1)

            guard points.count > 1, range > 0 else { return }

            func line(_ value: (CGPoint) -> CGFloat) -> Path {
                var path = Path()
                for (i, pt) in points.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(points.count - 1)
                    let y = mid - value(pt) / CGFloat(range) * mid
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                return path
            }

            ctx.stroke(line { $0.x }, with: .color(.blue), lineWidth: 1.5)
            ctx.stroke(line { $0.y }, with: .color(.orange), lineWidth: 1.5)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}
