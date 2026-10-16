import Foundation

/// Simple exponential low-pass.
struct LowPass {
    private(set) var value: Double?

    mutating func filter(_ x: Double, alpha: Double) -> Double {
        let out = value.map { alpha * x + (1 - alpha) * $0 } ?? x
        value = out
        return out
    }

    mutating func reset() { value = nil }
}

/// One Euro filter (Casiez et al., 2012).
/// Removes frame-to-frame landmark jitter while staying responsive to real motion.
/// Also gives a smoothed velocity, which we use to predict ahead and hide camera lag.
struct OneEuroFilter {
    var minCutoff: Double = 6.0   // Hz. Must stay above the shake frequency we want to keep.
    var beta: Double = 0.01       // How much the cutoff opens up during fast motion.
    var dCutoff: Double = 6.0     // Hz, for the velocity estimate.

    private var xFilter = LowPass()
    private var dxFilter = LowPass()
    private var lastRaw: Double?
    private(set) var velocity: Double = 0   // units per second

    static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    mutating func filter(_ x: Double, dt: Double) -> Double {
        let dx = lastRaw.map { (x - $0) / dt } ?? 0
        lastRaw = x
        velocity = dxFilter.filter(dx, alpha: Self.alpha(cutoff: dCutoff, dt: dt))
        let cutoff = minCutoff + beta * abs(velocity)
        return xFilter.filter(x, alpha: Self.alpha(cutoff: cutoff, dt: dt))
    }

    mutating func reset() {
        xFilter.reset()
        dxFilter.reset()
        lastRaw = nil
        velocity = 0
    }
}
