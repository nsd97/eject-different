import DiskArbitration
import Foundation
import IOKit.storage
import Testing
@testable import EjectDifferent

/// Scores the detector against every recording in Evaluation/. Each recording's
/// labels say what must happen in each segment: a "triple" segment fires exactly
/// once, and every other segment never fires. The scorecard also shows the range
/// of triggers that would still pass, and how near the knocks came to failing.
struct EvaluationTests {
    struct Impact {
        let start: Int
        let knock: Int?  // nil when the detector didn't count it
        let peak: Double
    }

    struct Replay {
        let name: String
        let recording: Recording
        let levels: [Double]
        var triples: [Int] = []
        var impacts: [Impact] = []
        var gaps: [Double] = []
    }

    static let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Evaluation")

    /// Runs each recording once through the daemon's own code path.
    static func replays() throws -> [Replay] {
        let labels = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try labels.map { url in
            let recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url))
            let raw = try Data(contentsOf: url.deletingPathExtension().appendingPathExtension("bin"), options: .mappedIfSafe)
            let count = raw.count / 6
            var detector = KnockDetector()
            var levels = [Double](repeating: 0, count: count)
            var replay = Replay(name: url.deletingPathExtension().lastPathComponent, recording: recording, levels: [])
            var ringing: (start: Int, knock: Int?)?
            var run: [Int] = []
            raw.withUnsafeBytes { bytes in
                for reading in 0..<count {
                    func axis(_ i: Int) -> Double {
                        Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: reading * 6 + i * 2, as: Int16.self))) / 16384
                    }
                    let event = detector.hears(SIMD3(axis(0), axis(1), axis(2)), at: Double(reading) * recording.sampleSpacing)
                    levels[reading] = detector.level
                    switch event {
                    case .knock(let number):
                        ringing = (reading, number)
                        run = number == 1 ? [reading] : run + [reading]
                        if number == 3 {
                            replay.triples.append(reading)
                            replay.gaps += zip(run.dropFirst(), run).map { Double($0 - $1) * recording.sampleSpacing }
                        }
                    case .ignored:
                        ringing = (reading, nil)
                    case .ended(let peak):
                        if let ringing { replay.impacts.append(Impact(start: ringing.start, knock: ringing.knock, peak: peak)) }
                        ringing = nil
                    case nil:
                        break
                    }
                }
            }
            return Replay(name: replay.name, recording: recording, levels: levels, triples: replay.triples, impacts: replay.impacts, gaps: replay.gaps)
        }
    }

    /// Every segment where triples fired a different number of times than its label says.
    static func misfires(_ triples: [Int], in recording: Recording) -> [String] {
        recording.segments.enumerated().compactMap { index, segment in
            let fired = triples.filter { segment.start <= $0 && $0 < segment.end }.count
            let expected = segment.expect == .triple ? 1 : 0
            return fired == expected ? nil : "step \(index + 1) “\(segment.label)”: expected \(expected) triple, fired \(fired)"
        }
    }

    /// Triples from a recording's saved levels at another trigger, using the same rhythm rules.
    static func triples(_ replay: Replay, trigger: Double) -> [Int] {
        var detector = KnockDetector()
        detector.trigger = trigger
        return replay.levels.indices.filter { detector.hears(level: replay.levels[$0], at: Double($0) * replay.recording.sampleSpacing) == .knock(3) }
    }

    @Test func corpus() throws {
        let replays = try Self.replays()
        #expect(!replays.isEmpty, "Evaluation/ has no recordings")
        for replay in replays {
            for misfire in Self.misfires(replay.triples, in: replay.recording) {
                Issue.record("\(replay.name), \(misfire)")
            }
        }

        // The scorecard.
        func row(_ columns: String...) -> String {
            zip(columns, [26, 9, 9, 7, 9, 15, 0]).map { $0.padding(toLength: max($1, $0.count), withPad: " ", startingAt: 0) }.joined()
        }
        func grams(_ value: Double?) -> String { value.map { String(format: "%.3f g", $0) } ?? "–" }
        let trigger = KnockDetector().trigger
        var lines = [String(format: "Knock evaluation · trigger %.3f g", trigger),
                     row("recording", "split", "triples", "false", "singles", "weakest knock", "loudest other")]
        for replay in replays {
            let segments = replay.recording.segments
            func inside(_ index: Int, _ kinds: Set<Recording.Segment.Expect>) -> Bool {
                segments.contains { kinds.contains($0.expect) && $0.start <= index && index < $0.end }
            }
            let tripleSegments = segments.filter { $0.expect == .triple }
            let found = tripleSegments.filter { s in replay.triples.filter { s.start <= $0 && $0 < s.end }.count == 1 }.count
            let falseTriples = replay.triples.filter { !inside($0, [.triple]) }.count
            let singleSegments = segments.filter { $0.expect == .single }
            let singlesRight = singleSegments.filter { s in replay.impacts.filter { s.start <= $0.start && $0.start < s.end && $0.knock != nil }.count == 1 }.count
            let weakest = replay.impacts.filter { $0.knock != nil && inside($0.start, [.triple, .single]) }.map(\.peak).min()
            let loudest = replay.impacts.filter { inside($0.start, [.none]) }.map(\.peak).max()
            lines.append(row(replay.name, replay.recording.split.rawValue, "\(found)/\(tripleSegments.count)", "\(falseTriples)",
                             "\(singlesRight)/\(singleSegments.count)", grams(weakest), grams(loudest)))
        }
        for split in [Recording.Split.tuning, .holdout] {
            let group = replays.filter { $0.recording.split == split }
            guard !group.isEmpty else {
                lines.append("\(split.rawValue): no recordings yet")
                continue
            }
            let tried = Array(stride(from: 0.010, through: 0.100, by: 0.003))
            let working = tried.filter { candidate in
                group.allSatisfy { Self.misfires(Self.triples($0, trigger: candidate), in: $0.recording).isEmpty }
            }
            let quietSeconds = group.reduce(0.0) { total, replay in
                total + replay.recording.segments.filter { $0.expect == .none }.reduce(0.0) { $0 + Double($1.end - $1.start) * replay.recording.sampleSpacing }
            }
            let falseTriples = group.reduce(0) { total, replay in
                total + replay.triples.filter { index in replay.recording.segments.contains { $0.expect != .triple && $0.start <= index && index < $0.end } }.count
            }
            let range: String
            if let low = working.first, let high = working.last {
                range = "works from " + (low == tried.first ? "below " : "") + String(format: "%.3f to %.3f g", low, high) + (high == tried.last ? " and above" : "")
            } else {
                range = "no trigger works"
            }
            let quiet = quietSeconds < 3600 ? String(format: "%.1f min", quietSeconds / 60) : String(format: "%.1f h", quietSeconds / 3600)
            lines.append("\(split.rawValue): \(range) · \(falseTriples) false triples in \(quiet) without knocking")
        }
        let gaps = replays.flatMap(\.gaps)
        if let shortest = gaps.min(), let longest = gaps.max() {
            lines.append(String(format: "gaps between knocks in triples: %.2f–%.2f s (allowed %.2f–%.2f s)",
                                shortest, longest, KnockDetector.shortestGap, KnockDetector.longestGap))
        }
        // The test runs inside the app, whose output xcodebuild doesn't show, so
        // the scorecard is also attached to the result: Xcode's test report shows
        // it, and AGENTS.md has the command that exports it.
        let scorecard = lines.joined(separator: "\n")
        print(scorecard)
        Attachment.record(scorecard, named: "Knock evaluation.txt")
    }
}

/// The rhythm rules, on synthetic knocks shaped like the recorded ones: a 60 Hz
/// ring decaying over 10 ms (about 0.07 g in the knock band, ringing about
/// 26 ms) on top of gravity, at 800 readings a second.
struct KnockRhythmTests {
    private func events(knocks: [TimeInterval], duration: TimeInterval = 6) -> [KnockDetector.Event] {
        var detector = KnockDetector()
        var heard: [KnockDetector.Event] = []
        for reading in 0..<Int(duration * 800) {
            let time = Double(reading) / 800
            let ring = knocks.reduce(0.0) { sum, start in
                let t = time - start
                return t < 0 ? sum : sum + 0.15 * exp(-t / 0.010) * sin(2 * .pi * 60 * t)
            }
            if let event = detector.hears(SIMD3(0, 0, -1 + ring), at: time) { heard.append(event) }
        }
        return heard
    }

    private func triples(knocks: [TimeInterval], duration: TimeInterval = 6) -> Int {
        events(knocks: knocks, duration: duration).filter { $0 == .knock(3) }.count
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

    @Test func aBounceIsNotCountedAndEveryImpactReportsItsPeak() {
        // Each synthetic ring is along one axis, so its strength dips through zero
        // every half cycle; it must still count as one impact.
        let heard = events(knocks: [1.0, 1.08, 1.4], duration: 2)
        #expect(heard.filter { if case .ended = $0 { false } else { true } } == [.knock(1), .ignored(.tooSoon), .knock(2)])
        let peaks = heard.compactMap { if case .ended(let peak) = $0 { peak } else { nil } }
        #expect(peaks.count == 3)
        #expect(peaks.allSatisfy { (0.05...0.12).contains($0) }, "peaks \(peaks)")
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
