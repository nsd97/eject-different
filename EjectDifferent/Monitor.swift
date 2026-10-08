// The developer's view of the sensor, built into Debug builds only: a live
// chart of what the knock detector hears, and a recorder that captures labeled
// sessions for the evaluation in Evaluation/. Release builds leave all of this
// out, so the shipping window stays one sentence and one button.
//
// The app can read the accelerometer without root while the listener keeps it
// awake, so the monitor opens it too and runs its own copy of KnockDetector on
// the same readings. Same code, same input: what the chart shows is what the
// daemon hears. The daemon's own triples and chimes arrive as notify(3)
// notifications, so the two can be compared.

#if DEBUG

import AppKit
import Charts
import Foundation
import SwiftUI
import notify

/// The labels for one recorded session. They're saved as JSON next to the
/// readings (a .bin file: x, y and z for each reading as little-endian Int16 in
/// units of 1/16384 g), and the corpus test reads both back.
struct Recording: Codable {
    enum Split: String, Codable {
        /// The constants may be tuned on it.
        case tuning
        /// It only scores the constants. Every new recording starts here.
        case holdout
    }

    struct Segment: Codable {
        enum Expect: String, Codable { case triple, single, none }
        /// The prompt that was on screen.
        let label: String
        let expect: Expect
        /// Index of the segment's first reading, and the index after its last.
        let start: Int
        let end: Int
    }

    var scenario: String
    /// The Mac's model identifier (hw.model), such as Mac14,6.
    var mac: String
    var macOS: String
    /// Seconds between readings, measured over the whole session.
    var sampleSpacing: Double
    var split: Split
    var segments: [Segment]
}

/// The live state behind the monitor. It is deliberately not @Observable:
/// readings arrive 800 times a second, so the view samples it 30 times a second
/// through a TimelineView instead of redrawing on every change.
final class Monitor {
    static let shared = Monitor()

    struct Point { let time: Double; let level: Double }
    struct Mark: Identifiable {
        let id: Int
        let time: Double
        let knock: Int?  // nil when the detector didn't count it
        var peak: Double?
    }

    /// Seconds of history on the chart.
    static let window = 5.0
    /// The chart's top, in g; louder impacts are drawn at the top.
    static let ceiling = 0.12

    private(set) var detector = KnockDetector()
    private(set) var points: [Point] = []
    private(set) var marks: [Mark] = []
    private(set) var listenerFired: [Double] = []
    /// The latest impact, such as "Knock 2 · 0.072 g".
    private(set) var latest = ""
    /// What the listener (the daemon) last reported.
    private(set) var listener = ""
    private(set) var lastReading: Double?
    private(set) var recorder: Recorder?
    /// What happened to the last recording, with its file when it was saved.
    private(set) var note = ""
    private(set) var saved: URL?

    private var envelope = 0.0
    private var readingsInPoint = 0
    private var nextMark = 0
    private var started = false
    private var tokens: [Int32] = []

    /// Now, on the clock the readings carry.
    var now: Double { Double(mach_absolute_time()) * MotionSensor.secondsPerTick }
    var hasReadings: Bool { lastReading.map { now - $0 < 1 } ?? false }

    func start() {
        guard !started else { return }
        started = true
        try? MotionSensor.start { [unowned self] acceleration, time in heard(acceleration, at: time) }
        observe(Daemon.tripleNotification) { monitor in
            monitor.listenerFired.append(monitor.now)
            monitor.listener = "The listener heard three knocks."
        }
        observe(Daemon.chimedNotification) { $0.listener = "The chime played." }
    }

    func record(_ scenario: Recorder.Scenario) {
        do {
            recorder = try Recorder(scenario: scenario)
            note = ""
            saved = nil
        } catch {
            note = "Couldn’t start recording. \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard let recorder else { return }
        finish(recorder, early: true)
    }

    func showInFinder() {
        if let saved { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
    }

    private func observe(_ name: String, _ update: @escaping (Monitor) -> Void) {
        var token: Int32 = 0
        notify_register_dispatch(name, &token, .main) { _ in
            MainActor.assumeIsolated { update(Monitor.shared) }
        }
        tokens.append(token)
    }

    private func heard(_ acceleration: SIMD3<Double>, at time: Double) {
        lastReading = time
        if let recorder, recorder.record(acceleration, at: time) {
            finish(recorder, early: false)
        }

        let event = detector.hears(acceleration, at: time)
        envelope = max(envelope, detector.level)
        readingsInPoint += 1
        if readingsInPoint == 8 {
            points.append(Point(time: time, level: min(envelope, Self.ceiling)))
            envelope = 0
            readingsInPoint = 0
            let oldest = time - Self.window
            if let keep = points.firstIndex(where: { $0.time >= oldest }), keep > 0 { points.removeFirst(keep) }
            marks.removeAll { $0.time < oldest }
            listenerFired.removeAll { $0 < oldest }
        }

        switch event {
        case .knock(let number):
            marks.append(Mark(id: nextMark, time: time, knock: number))
            nextMark += 1
            latest = number == 3 ? "Three knocks" : "Knock \(number)"
            if number == 1 { listener = "" }
        case .ignored(let reason):
            marks.append(Mark(id: nextMark, time: time, knock: nil))
            nextMark += 1
            latest = "Not counted: \(reason.rawValue)"
        case .ended(let peak):
            if !marks.isEmpty { marks[marks.count - 1].peak = peak }
            latest += String(format: " · %.3f g", peak)
        case nil:
            break
        }
    }

    private func finish(_ recorder: Recorder, early: Bool) {
        self.recorder = nil
        do {
            if let url = try recorder.finish(early: early) {
                saved = url
                note = "Saved “\(url.deletingPathExtension().lastPathComponent)”."
            } else {
                note = "Stopped early. Nothing was saved."
            }
        } catch {
            note = "Couldn’t save the recording. \(error.localizedDescription)"
        }
    }
}

/// Writes readings to disk as they arrive and labels them: each prompt of a
/// guided session becomes a segment, and an everyday session is one segment.
/// A guided session is all or nothing, so its labels never describe half a step.
final class Recorder {
    enum Scenario: String, CaseIterable, Identifiable {
        case lap, desk, moving, everyday
        var id: Self { self }
        var title: String { rawValue.capitalized }

        /// The prompts, how long each lasts in seconds, and what each should produce.
        var steps: [(prompt: String, seconds: Double, expect: Recording.Segment.Expect)] {
            let knocks: [(String, Double, Recording.Segment.Expect)] = [
                ("Knock three times on the palm rest.", 6, .triple),
                ("Knock three times, softly.", 6, .triple),
                ("Knock three times, firmly.", 6, .triple),
                ("Knock three times on the back of the lid.", 8, .triple),
                ("Knock once.", 4, .single),
                ("Knock once.", 4, .single),
                ("Knock twice.", 4, .none),
                ("Type anything, at your usual speed.", 10, .none),
                ("Click the trackpad a few times.", 6, .none),
            ]
            switch self {
            case .lap:
                return [("Rest your hands in your lap.", 5, .none)] + knocks + [
                    ("Shift in your seat, or cross your legs.", 8, .none),
                    ("Close the lid halfway, then open it again.", 8, .none),
                ]
            case .desk:
                return [("Rest your hands on the desk.", 5, .none)] + knocks + [
                    ("Drum your fingers on the desk.", 6, .none),
                    ("Set a cup or your phone down next to the Mac.", 6, .none),
                    ("Close the lid halfway, then open it again.", 8, .none),
                ]
            case .moving:
                return [
                    ("Pick up the Mac and hold it.", 6, .none),
                    ("Walk around with it.", 20, .none),
                    ("Set it down on a table.", 5, .none),
                    ("Pick it up, then set it down again.", 6, .none),
                    ("Put it on your lap.", 6, .none),
                    ("Put it back on the table.", 5, .none),
                ]
            case .everyday:
                return []  // one segment, until Stop
            }
        }
    }

    static let folder = URL.applicationSupportDirectory.appending(path: "Eject Different/Recordings")

    let scenario: Scenario
    private let readingsURL: URL
    private let file: FileHandle
    private let activity: NSObjectProtocol
    private var pending = Data()
    private(set) var count = 0
    private var segments: [Recording.Segment] = []
    private(set) var step = 0
    private var stepStarted: (reading: Int, time: Double)?
    private var firstTime: Double?
    private var lastTime = 0.0

    init(scenario: Scenario, folder: URL = Recorder.folder) throws {
        self.scenario = scenario
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Date.now.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)", timeZone: .current, calendar: .current))
        readingsURL = folder.appending(path: "\(scenario.rawValue)-\(stamp).bin")
        FileManager.default.createFile(atPath: readingsURL.path(percentEncoded: false), contents: nil)
        file = try FileHandle(forWritingTo: readingsURL)
        // .userInitiated keeps App Nap and idle sleep from pausing the recording.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Recording the motion sensor")
    }

    /// The prompt on screen, or nil for an everyday session.
    var prompt: String? { step < scenario.steps.count ? scenario.steps[step].prompt : nil }
    /// How far through the current step, from 0 to 1.
    var progress: Double {
        guard step < scenario.steps.count, let started = stepStarted else { return 0 }
        return min(1, (lastTime - started.time) / scenario.steps[step].seconds)
    }
    var elapsed: Double { firstTime.map { lastTime - $0 } ?? 0 }

    /// Stores one reading. Returns true when a guided session has just finished.
    func record(_ acceleration: SIMD3<Double>, at time: Double) -> Bool {
        // ponytail: Int16 in 1/16384 g clips beyond ±2 g; widen the format if a recording ever peaks there.
        for axis in 0..<3 {
            withUnsafeBytes(of: Int16(clamping: Int((acceleration[axis] * 16384).rounded())).littleEndian) { pending.append(contentsOf: $0) }
        }
        if pending.count >= 800 * 6 {
            file.write(pending)
            pending.removeAll(keepingCapacity: true)
        }
        firstTime = firstTime ?? time
        lastTime = time
        count += 1

        let steps = scenario.steps
        guard step < steps.count else { return false }
        let started = stepStarted ?? (count - 1, time)
        stepStarted = started
        guard time - started.time >= steps[step].seconds else { return false }
        segments.append(Recording.Segment(label: steps[step].prompt, expect: steps[step].expect, start: started.reading, end: count))
        step += 1
        stepStarted = nil
        return step == steps.count
    }

    /// Closes the files. Returns the label file's location, or nil when an
    /// unfinished guided session was thrown away.
    func finish(early: Bool) throws -> URL? {
        defer { ProcessInfo.processInfo.endActivity(activity) }
        file.write(pending)
        try file.close()
        if scenario == .everyday {
            segments = [Recording.Segment(label: "Use your Mac as usual, and don't knock.", expect: .none, start: 0, end: count)]
        } else if early || step < scenario.steps.count {
            try? FileManager.default.removeItem(at: readingsURL)
            return nil
        }
        var model = [CChar](repeating: 0, count: 64)
        var size = model.count
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let recording = Recording(
            scenario: scenario.rawValue,
            mac: String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
            macOS: "\(version.majorVersion).\(version.minorVersion)",
            sampleSpacing: count > 1 ? elapsed / Double(count - 1) : 0,
            split: .holdout,
            segments: segments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let labelsURL = readingsURL.deletingPathExtension().appendingPathExtension("json")
        try encoder.encode(recording).write(to: labelsURL)
        return labelsURL
    }
}

/// The monitor's section of the main window.
struct MonitorView: View {
    let listenerOn: Bool
    @State private var scenario = Recorder.Scenario.lap

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let monitor = Monitor.shared
            VStack(alignment: .leading, spacing: 8) {
                if monitor.hasReadings {
                    chart(monitor)
                    Text(monitor.latest.isEmpty ? "Knock to see it here." : monitor.latest)
                        .font(.callout.monospacedDigit())
                    Text(monitor.listener.isEmpty ? " " : monitor.listener)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(listenerOn ? "No readings from the sensor." : "Turn on Eject Different to see the sensor.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 140)
                }
                recorder(monitor)
            }
        }
        .onAppear { Monitor.shared.start() }
    }

    private func chart(_ monitor: Monitor) -> some View {
        let newest = monitor.lastReading ?? 0
        return Chart {
            LinePlot(monitor.points, x: .value("Time", \.time), y: .value("Level", \.level))
            RuleMark(y: .value("Trigger", monitor.detector.trigger))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.secondary)
            RuleMark(y: .value("Settled", monitor.detector.rearm))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 3]))
                .foregroundStyle(.tertiary)
            ForEach(monitor.marks) { mark in
                PointMark(x: .value("Time", mark.time), y: .value("Peak", min(mark.peak ?? monitor.detector.trigger, Monitor.ceiling)))
                    .foregroundStyle(mark.knock == nil ? Color.gray : Color.accentColor)
                    .annotation(position: .top) {
                        if let knock = mark.knock { Text("\(knock)").font(.caption.bold()) }
                    }
            }
            ForEach(monitor.listenerFired, id: \.self) { time in
                RuleMark(x: .value("Listener", time))
                    .foregroundStyle(Color.accentColor.opacity(0.6))
                    .annotation(position: .top) {
                        Image(systemName: "eject.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .accessibilityLabel("The listener heard three knocks")
                    }
            }
        }
        .chartXScale(domain: (newest - Monitor.window)...newest)
        .chartYScale(domain: 0...Monitor.ceiling)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: [0, 0.05, 0.10]) { value in
                AxisGridLine()
                AxisValueLabel { Text(String(format: "%.2f g", value.as(Double.self) ?? 0)) }
            }
        }
        .frame(height: 140)
    }

    @ViewBuilder private func recorder(_ monitor: Monitor) -> some View {
        Group {
            if let recorder = monitor.recorder {
                HStack(spacing: 12) {
                    if let prompt = recorder.prompt {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(prompt).font(.title3)
                            ProgressView(value: recorder.progress)
                            Text("Step \(recorder.step + 1) of \(recorder.scenario.steps.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Use your Mac as usual, and don't knock. Keep this window open.")
                            Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Stop") { monitor.stopRecording() }
                }
            } else {
                HStack(spacing: 12) {
                    Picker("Session", selection: $scenario) {
                        ForEach(Recorder.Scenario.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Button("Record") { monitor.record(scenario) }
                        .disabled(!monitor.hasReadings)
                        .fixedSize()
                }
                if !monitor.note.isEmpty {
                    HStack {
                        Text(monitor.note).font(.callout)
                        if monitor.saved != nil { Button("Show in Finder") { monitor.showInFinder() } }
                    }
                }
            }
        }
        .frame(minHeight: 72, alignment: .top)
    }
}

#endif
