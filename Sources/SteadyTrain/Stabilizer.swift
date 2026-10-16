import AppKit
import Combine
import CoreMedia

/// Settings snapshot read by the camera queue.
struct StabilizerParams {
    var gain = 1.0
    var maxOffset = 40.0          // screen points
    var baselineHz = 0.8          // movement slower than this counts as "you", not shake
    var extraLookahead = 0.016    // seconds, on top of measured lag (covers display refresh)
    var invertX = false
    var invertY = false
    var enabled = true
    var pointsPerMM = 5.0
}

/// Glue: camera -> shake estimate -> window offset. Publishes live readouts for the UI.
final class Stabilizer: ObservableObject {

    // MARK: Live readouts (main thread)
    @Published private(set) var cameraRunning = false
    @Published private(set) var faceFound = false
    @Published private(set) var fps: Double = 0
    @Published private(set) var latencyMs: Double = 0
    @Published private(set) var shakeMM: Double = 0
    @Published private(set) var history: [CGPoint] = []
    @Published private(set) var lockedName: String?
    @Published private(set) var countdown: Int?
    @Published private(set) var accessibilityOK = WindowMover.isTrusted(prompt: false)
    @Published private(set) var errorText: String?

    // MARK: Settings (saved between launches)
    @Published var gain = 1.0 { didSet { settingsChanged() } }
    @Published var maxOffset = 40.0 { didSet { settingsChanged() } }
    @Published var baselineHz = 0.8 { didSet { settingsChanged() } }
    @Published var extraLookaheadMs = 16.0 { didSet { settingsChanged() } }
    @Published var invertX = false { didSet { settingsChanged() } }
    @Published var invertY = false { didSet { settingsChanged() } }
    @Published var enabled = true { didSet { settingsChanged() } }

    private let tracker = HeadTracker()
    private let mover = WindowMover()
    private let pointsPerMM = Stabilizer.screenPointsPerMM()
    private let paramLock = NSLock()
    private var params = StabilizerParams()
    private var hotkeyMonitor: Any?
    private var permissionTimer: Timer?

    // MARK: Camera-queue state (only touched on tracker.queue)
    private var estimator = ShakeEstimator()
    private var lastFrameTime: Double?
    private var noFaceFrames = 0
    private var offset = CGPoint.zero
    private var latencyEMA = 0.05
    private var fpsEMA = 0.0
    private var lastPublish = 0.0
    private var historyBuffer: [CGPoint] = []
    private var shakeSquares: [Double] = []
    private var wasLocked = false

    init() {
        loadSettings()
        syncParams()

        tracker.onSample = { [weak self] sample, time in self?.process(sample, time: time) }
        startCamera()
        installHotkey()

        // Pick up the Accessibility permission as soon as you grant it.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let ok = WindowMover.isTrusted(prompt: false)
            if ok != self.accessibilityOK { self.accessibilityOK = ok }
        }
    }

    // MARK: - Actions (main thread)

    func startCamera() {
        tracker.start { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success: self?.cameraRunning = true
                case .failure(let error): self?.errorText = error.localizedDescription
                }
            }
        }
    }

    /// Gives you 3 seconds to click the window you want steadied.
    func beginLockCountdown() {
        if lockedName != nil { releaseWindow(); return }
        errorText = nil
        countdown = 3
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, let count = self.countdown else { timer.invalidate(); return }
            if count <= 1 {
                timer.invalidate()
                self.countdown = nil
                self.lockFrontmostWindow()
            } else {
                self.countdown = count - 1
            }
        }
    }

    func toggleLock() {
        if lockedName != nil { releaseWindow() } else { lockFrontmostWindow() }
    }

    func lockFrontmostWindow() {
        accessibilityOK = WindowMover.isTrusted(prompt: true)
        guard accessibilityOK else {
            errorText = "Grant Accessibility permission first, then try again."
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            errorText = "Click the window you want to steady during the countdown."
            return
        }

        let pid = app.processIdentifier
        let name = app.localizedName ?? "window"
        tracker.queue.async { [weak self] in
            guard let self else { return }
            let ok = self.mover.lock(pid: pid)
            self.offset = .zero
            self.wasLocked = ok
            DispatchQueue.main.async {
                self.lockedName = ok ? name : nil
                self.errorText = ok ? nil : "Couldn't grab a window from \(name)."
            }
        }
    }

    func releaseWindow() {
        tracker.queue.async { [weak self] in
            guard let self else { return }
            self.mover.release()
            self.wasLocked = false
            DispatchQueue.main.async { self.lockedName = nil }
        }
    }

    func openAccessibilitySettings() {
        _ = WindowMover.isTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func resetSettings() {
        gain = 1.0; maxOffset = 40; baselineHz = 0.8; extraLookaheadMs = 16
        invertX = false; invertY = false; enabled = true
    }

    func quit() {
        tracker.queue.sync { mover.release() }   // put the window back first
        tracker.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Per frame (camera queue)

    private func process(_ sample: HeadSample?, time: Double) {
        paramLock.lock()
        let p = params
        paramLock.unlock()

        var dt = 1.0 / 30
        if let last = lastFrameTime { dt = time - last }
        lastFrameTime = time
        if dt > 0.0005 && dt < 1 {
            fpsEMA = fpsEMA == 0 ? 1 / dt : 0.9 * fpsEMA + 0.1 / dt
        }

        guard let sample else {
            // Face lost: glide the window home instead of freezing it off-centre.
            noFaceFrames += 1
            if noFaceFrames > 3 {
                offset = CGPoint(x: offset.x * 0.8, y: offset.y * 0.8)
                mover.setOffset(p.enabled ? offset : .zero)
                estimator.reset()
            }
            finishFrame(time: time, rawShake: nil)
            return
        }

        if dt > 0.25 || dt <= 0 { estimator.reset() }   // gap in frames: start fresh
        noFaceFrames = 0
        let safeDt = min(max(dt, 1.0 / 240), 0.1)

        let lookahead = min(max(latencyEMA + p.extraLookahead, 0), 0.15)
        let shake = estimator.update(sample, dt: safeDt, baselineHz: p.baselineHz, lookahead: lookahead)

        // The window follows your head relative to the screen, so the text stays
        // put in your field of view. AX screen coordinates have y pointing down.
        var dx = shake.rightMM * p.pointsPerMM * p.gain
        var dy = -shake.upMM * p.pointsPerMM * p.gain
        if p.invertX { dx = -dx }
        if p.invertY { dy = -dy }
        offset = CGPoint(x: softClamp(dx, p.maxOffset), y: softClamp(dy, p.maxOffset))

        mover.setOffset(p.enabled ? offset : .zero)

        // Measured lag: from the moment the frame was captured until the window moved.
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let lag = now - time
        if lag > 0 && lag < 0.5 { latencyEMA = 0.9 * latencyEMA + 0.1 * lag }

        finishFrame(time: time, rawShake: hypot(shake.rawRightMM, shake.rawUpMM))
    }

    private func finishFrame(time: Double, rawShake: Double?) {
        historyBuffer.append(offset)
        if historyBuffer.count > 120 { historyBuffer.removeFirst(historyBuffer.count - 120) }

        if let rawShake {
            shakeSquares.append(rawShake * rawShake)
            if shakeSquares.count > 60 { shakeSquares.removeFirst(shakeSquares.count - 60) }
        }

        let lostWindow = wasLocked && !mover.isLocked
        if lostWindow { wasLocked = false }

        // Update the UI ~30 times a second at most.
        guard time - lastPublish >= 1.0 / 30 || lostWindow else { return }
        lastPublish = time

        let face = rawShake != nil
        let history = historyBuffer
        let rms = shakeSquares.isEmpty ? 0 : (shakeSquares.reduce(0, +) / Double(shakeSquares.count)).squareRoot()
        let fps = fpsEMA
        let latency = latencyEMA * 1000

        DispatchQueue.main.async {
            self.faceFound = face
            self.history = history
            self.shakeMM = rms
            self.fps = fps
            self.latencyMs = latency
            if lostWindow { self.lockedName = nil }
        }
    }

    /// Smoothly limits the offset so big jolts don't throw the window across the screen.
    private func softClamp(_ value: Double, _ limit: Double) -> Double {
        guard limit > 0 else { return 0 }
        return limit * tanh(value / limit)
    }

    // MARK: - Hotkey: Control + Option + S

    private func installHotkey() {
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == [.control, .option], event.keyCode == 1 else { return }   // 1 = S
            DispatchQueue.main.async { self?.toggleLock() }
        }
    }

    // MARK: - Settings

    private func settingsChanged() {
        syncParams()
        let d = UserDefaults.standard
        d.set(gain, forKey: "gain")
        d.set(maxOffset, forKey: "maxOffset")
        d.set(baselineHz, forKey: "baselineHz")
        d.set(extraLookaheadMs, forKey: "extraLookaheadMs")
        d.set(invertX, forKey: "invertX")
        d.set(invertY, forKey: "invertY")
        d.set(enabled, forKey: "enabled")
    }

    private func loadSettings() {
        let d = UserDefaults.standard
        if d.object(forKey: "gain") != nil { gain = d.double(forKey: "gain") }
        if d.object(forKey: "maxOffset") != nil { maxOffset = d.double(forKey: "maxOffset") }
        if d.object(forKey: "baselineHz") != nil { baselineHz = d.double(forKey: "baselineHz") }
        if d.object(forKey: "extraLookaheadMs") != nil { extraLookaheadMs = d.double(forKey: "extraLookaheadMs") }
        if d.object(forKey: "invertX") != nil { invertX = d.bool(forKey: "invertX") }
        if d.object(forKey: "invertY") != nil { invertY = d.bool(forKey: "invertY") }
        if d.object(forKey: "enabled") != nil { enabled = d.bool(forKey: "enabled") }
    }

    private func syncParams() {
        paramLock.lock()
        params = StabilizerParams(gain: gain,
                                  maxOffset: maxOffset,
                                  baselineHz: baselineHz,
                                  extraLookahead: extraLookaheadMs / 1000,
                                  invertX: invertX,
                                  invertY: invertY,
                                  enabled: enabled,
                                  pointsPerMM: pointsPerMM)
        paramLock.unlock()
    }

    /// Screen points per physical millimetre, so 1 mm of head shake moves the window 1 mm.
    private static func screenPointsPerMM() -> Double {
        guard let screen = NSScreen.main,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return 5.0 }
        let size = CGDisplayScreenSize(id)
        guard size.width > 0 else { return 5.0 }
        return Double(screen.frame.width / size.width)
    }
}
