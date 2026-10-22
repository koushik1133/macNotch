import CoreGraphics
import Foundation

// Pure geometry for Screen Distance: eye-to-camera distance from the
// pixel distance between the eyes (pinhole camera model). No Vision and no
// AVFoundation here, so the harness can test it with synthetic landmarks.
// See DESIGN.md for the derivation.

/// One face as seen in one frame, in image pixels.
struct ScreenDistanceFace: Equatable, Sendable {
    /// Eye centres (pupil when Vision finds one, else the eye contour's centroid).
    var leftEye: CGPoint
    var rightEye: CGPoint
    /// Head yaw in radians from Vision, nil when unknown.
    var yaw: Double?

    /// Interocular distance in pixels. Roll needs no correction: hypot is
    /// rotation invariant.
    var ipdPixels: Double {
        Double(hypot(leftEye.x - rightEye.x, leftEye.y - rightEye.y))
    }
}

/// One analysed camera frame.
struct ScreenDistanceFrame: Equatable, Sendable {
    var faces: [ScreenDistanceFace]
    var frameWidthPixels: Double
    /// Horizontal field of view of the capture format, degrees (0 if unknown).
    var horizontalFOVDegrees: Double
    var timestamp: Date
    /// Center Stage (or another automatic reframing) was active, so the
    /// effective field of view is unknown and the frame can't give a distance.
    var isReframed: Bool = false
}

/// What a single frame says about the distance.
enum ScreenDistanceReading: Equatable, Sendable {
    case distance(Double)
    case noFace
    /// The closest face is turned too far for its eye spacing to be trusted.
    case faceTurned

    var centimeters: Double? {
        if case .distance(let value) = self { return value }
        return nil
    }
}

enum ScreenDistanceMath {
    /// Mean adult interpupillary distance, cm (Dodgson 2004: 63 mm).
    static let defaultIPDCentimeters: Double = 6.3
    /// macOS has no `videoFieldOfView` (API_UNAVAILABLE(macos)), so this is a
    /// nominal horizontal FOV for the 16:9 1080p FaceTime HD camera (about
    /// 80° diagonal). Calibration absorbs any error in it.
    static let fallbackHorizontalFOVDegrees: Double = 72

    /// Nominal horizontal FOV for a format of the given aspect ratio, assuming
    /// narrower formats are side crops of the 16:9 sensor at full height.
    static func nominalHorizontalFOV(aspectRatio: Double) -> Double {
        let wide = 16.0 / 9.0
        guard aspectRatio > 0, aspectRatio < wide - 0.01 else { return fallbackHorizontalFOVDegrees }
        let half = fallbackHorizontalFOVDegrees * .pi / 360
        return 2 * atan(tan(half) * aspectRatio / wide) * 180 / .pi
    }
    /// Faces turned further than this are rejected (cos 35° = 0.82, so the
    /// correction never multiplies by more than 1.22).
    static let maxYawRadians: Double = 35 * .pi / 180
    /// Readings outside this range are treated as detection errors.
    static let plausibleRange: ClosedRange<Double> = 10...200

    /// f = (W / 2) / tan(FOV / 2).
    static func focalLengthPixels(horizontalFOVDegrees: Double, frameWidthPixels: Double) -> Double? {
        guard frameWidthPixels > 0, horizontalFOVDegrees > 1, horizontalFOVDegrees < 179 else { return nil }
        return (frameWidthPixels / 2) / tan(horizontalFOVDegrees * .pi / 360)
    }

    /// distance = f × IPD / ipd_px, with ipd_px divided by cos(yaw) to undo
    /// foreshortening. Nil when the face is turned past `maxYawRadians`.
    static func distanceCentimeters(
        ipdPixels: Double,
        focalPixels: Double,
        ipdCentimeters: Double = defaultIPDCentimeters,
        yawRadians: Double? = nil
    ) -> Double? {
        guard ipdPixels > 1, focalPixels > 0, ipdCentimeters > 0 else { return nil }
        var corrected = ipdPixels
        if let yaw = yawRadians {
            guard yaw.isFinite, abs(yaw) <= maxYawRadians else { return nil }
            corrected = ipdPixels / cos(yaw)
        }
        return focalPixels * ipdCentimeters / corrected
    }

    /// The face whose eyes are farthest apart in pixels, i.e. the closest one.
    static func closestFace(in faces: [ScreenDistanceFace]) -> ScreenDistanceFace? {
        faces.max { $0.ipdPixels < $1.ipdPixels }
    }

    /// Distance for one frame, after `calibrationScale` (1 = uncalibrated).
    static func reading(
        for frame: ScreenDistanceFrame,
        calibrationScale: Double = 1,
        ipdCentimeters: Double = defaultIPDCentimeters
    ) -> ScreenDistanceReading {
        guard !frame.isReframed, let face = closestFace(in: frame.faces) else { return .noFace }
        let fov = frame.horizontalFOVDegrees > 1 ? frame.horizontalFOVDegrees : fallbackHorizontalFOVDegrees
        guard let focal = focalLengthPixels(horizontalFOVDegrees: fov, frameWidthPixels: frame.frameWidthPixels) else {
            return .noFace
        }
        guard let raw = distanceCentimeters(
            ipdPixels: face.ipdPixels, focalPixels: focal, ipdCentimeters: ipdCentimeters, yawRadians: face.yaw
        ) else {
            return .faceTurned
        }
        // Off-axis: a face seen at horizontal angle θ from the optical axis
        // projects its eye spacing as f·IPD·cos ψ / (Z·cos θ), where ψ is the
        // yaw Vision sees (relative to the line of sight). Dividing by cos θ
        // turns the estimate back into depth Z, the distance from the screen
        // plane.
        let midX = Double(face.leftEye.x + face.rightEye.x) / 2
        let theta = atan(abs(midX - frame.frameWidthPixels / 2) / focal)
        let value = raw / cos(theta) * calibrationScale
        return plausibleRange.contains(value) ? .distance(value) : .noFace
    }

    /// Median of a burst: robust to one blinking or mis-detected frame.
    /// Nil when fewer than `minimumCount` frames had a distance.
    static func burstReading(
        _ frames: [ScreenDistanceFrame],
        calibrationScale: Double = 1,
        minimumCount: Int = 2
    ) -> ScreenDistanceReading {
        let readings = frames.map { reading(for: $0, calibrationScale: calibrationScale) }
        let values = readings.compactMap(\.centimeters)
        if values.count >= max(1, minimumCount), let middle = median(values) { return .distance(middle) }
        return readings.contains(.faceTurned) ? .faceTurned : .noFace
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Calibration: the factor that turns what was measured (uncalibrated)
    /// into the distance the user says they sit at. Clamped to 0.5...2 so a
    /// bad measurement can't make the feature useless.
    static func calibrationScale(measuredCentimeters: Double, actualCentimeters: Double) -> Double? {
        guard measuredCentimeters > 0, actualCentimeters > 0 else { return nil }
        return min(2, max(0.5, actualCentimeters / measuredCentimeters))
    }

    static func inches(_ centimeters: Double) -> Double { centimeters / 2.54 }
}

/// Median of the last few readings, dropping ones older than `maxAge`.
struct ScreenDistanceSmoother: Sendable {
    var capacity: Int = 3
    var maxAge: TimeInterval = 7
    private(set) var samples: [(date: Date, value: Double)] = []

    init(capacity: Int = 3, maxAge: TimeInterval = 7) {
        self.capacity = max(1, capacity)
        self.maxAge = maxAge
    }

    /// Adds a value and returns the smoothed one.
    @discardableResult
    mutating func add(_ value: Double, at date: Date) -> Double {
        samples.append((date, value))
        samples.removeAll { date.timeIntervalSince($0.date) > maxAge }
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        return ScreenDistanceMath.median(samples.map(\.value)) ?? value
    }

    mutating func reset() { samples.removeAll() }
}
