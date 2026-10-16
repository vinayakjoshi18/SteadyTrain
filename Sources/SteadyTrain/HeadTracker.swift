import AVFoundation
import CoreMedia
import Vision

/// One head position measurement from one camera frame.
struct HeadSample {
    /// Head point in normalized image coordinates (0...1, origin bottom-left, image NOT mirrored).
    let x: Double
    let y: Double
    /// Face width as a fraction of image width. Used to convert to millimetres.
    let faceWidth: Double
    /// Image height / width.
    let aspect: Double
}

enum TrackerError: LocalizedError {
    case denied, noCamera, configFailed

    var errorDescription: String? {
        switch self {
        case .denied: return "Camera access denied. Allow it in System Settings > Privacy & Security > Camera."
        case .noCamera: return "No camera found."
        case .configFailed: return "Couldn't set up the camera."
        }
    }
}

/// Runs the camera and finds a stable point on your face in every frame.
final class HeadTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "steadytrain.camera", qos: .userInteractive)

    /// Called on `queue` for every frame. Sample is nil when no face is visible.
    /// Time is the frame's capture time in host-clock seconds.
    var onSample: ((HeadSample?, Double) -> Void)?

    private let session = AVCaptureSession()
    private let sequenceHandler = VNSequenceRequestHandler()
    private let landmarksRequest = VNDetectFaceLandmarksRequest()

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { completion(.failure(TrackerError.denied)); return }
            self.queue.async {
                do {
                    try self.configureIfNeeded()
                    if !self.session.isRunning { self.session.startRunning() }
                    completion(.success(()))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    // MARK: - Setup

    private func configureIfNeeded() throws {
        guard session.inputs.isEmpty else { return }

        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
        guard let device else { throw TrackerError.noCamera }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw TrackerError.configFailed }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true   // never queue old frames: lag kills stabilization
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw TrackerError.configFailed }
        session.addOutput(output)

        // Make sure the frames are not mirrored, so the direction math below holds.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        selectFastestFormat(device)
    }

    /// Frame rate matters more than resolution here, so pick the fastest small format.
    private func selectFastestFormat(_ device: AVCaptureDevice) {
        var best: (format: AVCaptureDevice.Format, rate: Double, width: Int32)?
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width >= 640, dims.width <= 1280 else { continue }
            let rate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            if let b = best {
                let faster = rate > b.rate + 0.5
                let sameButSmaller = abs(rate - b.rate) <= 0.5 && dims.width < b.width
                if !(faster || sameButSmaller) { continue }
            }
            best = (format, rate, dims.width)
        }
        guard let best, best.rate > 0 else { return }

        do {
            try device.lockForConfiguration()
            device.activeFormat = best.format
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(best.rate.rounded()))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
        } catch {
            // Keep the default format. Tracking still works, just slower.
        }
    }

    // MARK: - Per frame

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        do {
            try sequenceHandler.perform([landmarksRequest], on: pixelBuffer, orientation: .up)
        } catch {
            onSample?(nil, time)
            return
        }

        // If several faces are visible, follow the biggest (closest) one.
        guard let face = landmarksRequest.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
            onSample?(nil, time)
            return
        }

        let point = headPoint(face)
        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let height = Double(CVPixelBufferGetHeight(pixelBuffer))

        onSample?(HeadSample(x: Double(point.x),
                             y: Double(point.y),
                             faceWidth: Double(face.boundingBox.width),
                             aspect: height / width), time)
    }

    /// Average of eyes, eyebrows and nose. These are rigid parts of the face,
    /// so talking or smiling (mouth, jaw) doesn't look like head movement.
    private func headPoint(_ face: VNFaceObservation) -> CGPoint {
        let box = face.boundingBox
        var sum = CGPoint.zero
        var count = 0

        if let lm = face.landmarks {
            for region in [lm.leftEye, lm.rightEye, lm.leftEyebrow, lm.rightEyebrow, lm.nose] {
                guard let region else { continue }
                for p in region.normalizedPoints {
                    sum.x += box.minX + p.x * box.width
                    sum.y += box.minY + p.y * box.height
                    count += 1
                }
            }
        }

        guard count > 0 else { return CGPoint(x: box.midX, y: box.midY) }
        return CGPoint(x: sum.x / CGFloat(count), y: sum.y / CGFloat(count))
    }
}
