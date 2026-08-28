import Foundation
import simd

/// Sharp-impulse filtering adapted from shaircast/nocnoc (MIT).
public final class TripleKnockDetector: @unchecked Sendable {
    public var onTripleKnock: (@Sendable (Double) -> Void)?

    private let threshold: Double
    private var lowPass = SIMD3<Double>(repeating: 0)
    private var previous = SIMD3<Double>(repeating: 0)
    private var initialized = false
    private var lastAccepted = -Double.infinity
    private var sequence = KnockSequence()
    private var cooldownUntil = -Double.infinity
    private let gyroThreshold = 4.0

    public init(threshold: Double = 0.14) { self.threshold = threshold }

    public func process(x: Double, y: Double, z: Double, at now: TimeInterval) {
        let sample = SIMD3<Double>(x, y, z)
        if !initialized {
            lowPass = sample
            previous = sample
            initialized = true
            return
        }

        lowPass += (sample - lowPass) * 0.08
        let highPass = simd_length(sample - lowPass)
        let jerk = simd_length(sample - previous)
        previous = sample
        let impulse = max(highPass, jerk * 0.92)

        if impulse > threshold, jerk > threshold * 0.70 { acceptImpulse(impulse, at: now) }

        finishSequence(at: now, strength: impulse)
    }

    /// Rotational impulse path from Apple SPU gyroscope usage 9 (degrees/second).
    public func processGyro(x: Double, y: Double, z: Double, at now: TimeInterval) {
        let impulse = simd_length(SIMD3<Double>(x, y, z))
        if impulse > gyroThreshold { acceptImpulse(impulse, at: now) }
        finishSequence(at: now, strength: impulse)
    }

    private func acceptImpulse(_ impulse: Double, at now: TimeInterval) {
        guard now >= cooldownUntil, now - lastAccepted >= sequence.minimumGap else { return }
        sequence.registerImpact(at: now)
        lastAccepted = now
    }

    private func finishSequence(at now: TimeInterval, strength: Double) {
        if sequence.finishIfReady(at: now) == .triple {
            cooldownUntil = now + 1.5
            onTripleKnock?(strength)
        }
    }
}
