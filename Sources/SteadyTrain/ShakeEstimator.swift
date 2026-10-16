import Foundation

struct ShakeOutput {
    /// Predicted head shake relative to the screen, in millimetres (what we correct with).
    var rightMM: Double
    var upMM: Double
    /// Current (unpredicted) shake, for the readout.
    var rawRightMM: Double
    var rawUpMM: Double

    static let zero = ShakeOutput(rightMM: 0, upMM: 0, rawRightMM: 0, rawUpMM: 0)
}

/// Turns raw head positions into "shake": fast motion only, in millimetres.
///
/// Pipeline per axis:
///   raw position -> One Euro filter (removes landmark jitter)
///                -> minus a slow baseline (removes intentional movement, leaning, slouching)
///                -> plus velocity * lookahead (predicts ahead to hide camera + processing lag)
struct ShakeEstimator {
    /// Rough width of the face box Vision returns. The strength slider corrects for your face.
    static let faceWidthMM = 150.0

    private var filterX = OneEuroFilter()
    private var filterY = OneEuroFilter()
    private var baselineX = LowPass()
    private var baselineY = LowPass()
    private var faceWidth = LowPass()

    mutating func reset() {
        filterX.reset(); filterY.reset()
        baselineX.reset(); baselineY.reset()
        faceWidth.reset()
    }

    mutating func update(_ s: HeadSample, dt: Double, baselineHz: Double, lookahead: Double) -> ShakeOutput {
        // Face size changes slowly (leaning in or out); smooth it hard so it doesn't add noise.
        let width = faceWidth.filter(s.faceWidth, alpha: OneEuroFilter.alpha(cutoff: 0.5, dt: dt))
        guard width > 0.02 else { return .zero }

        // Put both axes in image-width units so x and y share one scale.
        let x = filterX.filter(s.x, dt: dt)
        let y = filterY.filter(s.y * s.aspect, dt: dt)

        let a = OneEuroFilter.alpha(cutoff: baselineHz, dt: dt)
        let shakeX = x - baselineX.filter(x, alpha: a)
        let shakeY = y - baselineY.filter(y, alpha: a)

        let predictedX = shakeX + filterX.velocity * lookahead
        let predictedY = shakeY + filterY.velocity * lookahead

        let mmPerUnit = Self.faceWidthMM / width

        // The camera image is not mirrored: when you move to your right,
        // your face moves left in the image. Vision's y already points up.
        return ShakeOutput(rightMM: -predictedX * mmPerUnit,
                           upMM: predictedY * mmPerUnit,
                           rawRightMM: -shakeX * mmPerUnit,
                           rawUpMM: shakeY * mmPerUnit)
    }
}
