import DiskArbitration
import Foundation
import IOKit.storage
import Testing
@testable import EjectDifferent

/// A real 71-second session, recorded with the Mac on a lap: the accelerometer
/// as the detector sees it, step by step. Each reading is three little-endian
/// Int16s in units of 1/16384 g, taken 1.2545 ms apart.
struct LapCalibrationReplayTests {
    enum Step: String { case still, triple, single, typing, trackpad, shift, lid }
    static let steps: [(step: Step, firstReading: Int)] = [
        (.still, 0), (.triple, 4385), (.triple, 9169), (.triple, 13952),
        (.single, 18735), (.single, 21924), (.single, 25112), (.typing, 28301),
        (.trackpad, 36273), (.shift, 41057), (.shift, 45840), (.lid, 50623),
    ]

    /// Every knock the detector hears, by the index of the step it fell in.
    static let heard: [Int: [KnockDetector.Knock]] = {
        let file = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "lap-calibration.bin")
        let raw = try! Data(contentsOf: file)
        var detector = KnockDetector()
        var heard: [Int: [KnockDetector.Knock]] = [:]
        raw.withUnsafeBytes { bytes in
            for reading in 0..<(bytes.count / 6) {
                func axis(_ i: Int) -> Double {
                    Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: reading * 6 + i * 2, as: Int16.self))) / 16384
                }
                guard let knock = detector.hears(SIMD3(axis(0), axis(1), axis(2)), at: Double(reading) * 0.0012545) else { continue }
                let step = steps.lastIndex { $0.firstReading <= reading }!
                heard[step, default: []].append(knock)
            }
        }
        return heard
    }()

    @Test func everyTripleKnockFiresExactlyOnce() {
        for (index, step) in Self.steps.enumerated() {
            let triples = Self.heard[index, default: []].filter { $0.number == 3 }.count
            #expect(triples == (step.step == .triple ? 1 : 0), "step \(index + 1), \(step.step.rawValue)")
        }
    }

    @Test func aSingleKnockIsHeardAsOne() {
        for (index, step) in Self.steps.enumerated() where step.step == .single {
            #expect(Self.heard[index, default: []].map(\.number) == [1], "step \(index + 1)")
        }
    }

    @Test func typingClicksAndTheLidAreNotKnocks() {
        for (index, step) in Self.steps.enumerated() where [.still, .typing, .trackpad, .lid].contains(step.step) {
            #expect(Self.heard[index, default: []].isEmpty, "step \(index + 1), \(step.step.rawValue)")
        }
    }
}

/// The rhythm rules, on synthetic knocks shaped like the recorded ones: a 60 Hz
/// ring decaying over 10 ms (about 0.07 g in the knock band, ringing about
/// 26 ms) on top of gravity, at 800 readings a second.
struct KnockRhythmTests {
    private func triples(knocks: [TimeInterval], duration: TimeInterval = 6) -> Int {
        var detector = KnockDetector()
        var fired = 0
        for reading in 0..<Int(duration * 800) {
            let time = Double(reading) / 800
            let ring = knocks.reduce(0.0) { sum, start in
                let t = time - start
                return t < 0 ? sum : sum + 0.15 * exp(-t / 0.010) * sin(2 * .pi * 60 * t)
            }
            if detector.hears(SIMD3(0, 0, -1 + ring), at: time)?.number == 3 { fired += 1 }
        }
        return fired
    }

    @Test func threeKnocksAThirdOfASecondApartAreATriple() {
        #expect(triples(knocks: [1.0, 1.3, 1.6]) == 1)
    }

    @Test func knocksTooFarApartNeverAddUp() {
        #expect(triples(knocks: [1.0, 1.8, 2.6, 3.4]) == 0)
    }

    @Test func aSecondTripleDuringTheCooldownIsIgnored() {
        #expect(triples(knocks: [1.0, 1.3, 1.6, 1.9, 2.2, 2.5]) == 1)
        #expect(triples(knocks: [1.0, 1.3, 1.6, 4.0, 4.3, 4.6]) == 2)
    }

    @Test func drummingThatNeverStopsFiresOnce() {
        #expect(triples(knocks: Array(stride(from: 1.0, through: 5.5, by: 0.3))) == 1)
    }
}

struct SensorReportTests {
    @Test func readsLittleEndianQ16Axes() {
        var report = [UInt8](repeating: 0, count: MotionSensor.reportLength)
        for (offset, value) in [(6, Int32(65_536)), (10, Int32(-32_768)), (14, Int32(16_384))] {
            withUnsafeBytes(of: value.littleEndian) { report.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        #expect(report.withUnsafeBytes(MotionSensor.axes) == SIMD3(1, -0.5, 0.25))
        #expect([UInt8](repeating: 0, count: 21).withUnsafeBytes(MotionSensor.axes) == nil)
    }
}

/// Which disks are fair game, using the descriptions this Mac's own disks give.
struct DiskRuleTests {
    private func disk(protocol name: String?, internal isInternal: Bool?, removable isRemovable: Bool?) -> [String: Any] {
        var description: [String: Any] = [:]
        description[kDADiskDescriptionDeviceProtocolKey as String] = name
        description[kDADiskDescriptionDeviceInternalKey as String] = isInternal
        description[kDADiskDescriptionMediaRemovableKey as String] = isRemovable
        return description
    }

    @Test func ejectsExternalDrivesAndSDCards() {
        #expect(Eject.isUnpluggable(disk(protocol: "USB", internal: false, removable: false)))
        #expect(Eject.isUnpluggable(disk(protocol: "Thunderbolt", internal: false, removable: false)))
        #expect(Eject.isUnpluggable(disk(protocol: "Secure Digital", internal: true, removable: true)))
    }

    @Test func neverTheInternalDiskADiskImageOrAShare() {
        #expect(!Eject.isUnpluggable(disk(protocol: "Apple Fabric", internal: true, removable: false)))
        #expect(!Eject.isUnpluggable(disk(protocol: kIOPropertyPhysicalInterconnectTypeVirtual, internal: false, removable: true)))
        #expect(!Eject.isUnpluggable(disk(protocol: nil, internal: nil, removable: nil)))
    }

    @Test func onlyTimeMachineMayBeForced() {
        #expect(Eject.isTimeMachine("backupd"))
        #expect(Eject.isTimeMachine("backupd-helper"))
        #expect(!Eject.isTimeMachine("rsync"))
        #expect(!Eject.isTimeMachine(""))
    }
}
