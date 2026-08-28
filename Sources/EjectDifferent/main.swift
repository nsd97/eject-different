import Foundation
import EjectDifferentCore

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }; return body(&value)
    }
}

private enum Feedback {
    static func play(_ path: String) {
        let script = """
        on run argv
          set soundPath to item 1 of argv
          set prior to get volume settings
          set priorVolume to output volume of prior
          set priorMuted to output muted of prior
          try
            set volume output volume 100 without output muted
            do shell script "/usr/bin/afplay -v 1 " & quoted form of soundPath
          on error messageText
            set volume output volume priorVolume
            if priorMuted then set volume with output muted
            error messageText
          end try
          set volume output volume priorVolume
          if priorMuted then set volume with output muted
        end run
        """
        do {
            let console = try Shell.run("/usr/bin/stat", ["-f", "%Su", "/dev/console"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let uid = try Shell.run("/usr/bin/id", ["-u", console]).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try Shell.run("/bin/launchctl", ["asuser", uid, "/usr/bin/sudo", "-u", console, "/usr/bin/osascript", "-e", script, "--", path])
            if result.status != 0 { fputs("audio error: \(result.text)\n", stderr) }
        } catch { fputs("audio error: \(error)\n", stderr) }
    }

    static func success() {
        if let url = Bundle.module.url(forResource: "different", withExtension: "wav") { play(url.path) }
    }
    static func failure() { play("/System/Library/Sounds/Sosumi.aiff") }
}

private func log(_ message: String) {
    let formatter = ISO8601DateFormatter()
    print("[\(formatter.string(from: Date()))] \(message)")
    fflush(stdout)
}

if CommandLine.arguments.contains("--probe") {
    let sensor = SPUAccelerometerService()
    let samples = LockedBox(0)
    sensor.onSample = { _, _, _, _ in samples.mutate { $0 += 1 } }
    sensor.onGyroSample = { _, _, _, _ in samples.mutate { $0 += 1 } }
    do {
        try sensor.start()
        Thread.sleep(forTimeInterval: 2)
        sensor.stop()
        let count = samples.read()
        print("SPU accelerometer samples in 2s: \(count)")
        exit(count > 0 ? 0 : 2)
    } catch {
        fputs("probe failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--sound-test-success") { Feedback.success(); exit(0) }
if CommandLine.arguments.contains("--sound-test-failure") { Feedback.failure(); exit(0) }

let sensor = SPUAccelerometerService()
let detector = TripleKnockDetector()
let ejecting = LockedBox(false)

detector.onTripleKnock = { strength in
    let accepted = ejecting.mutate { state in
        guard !state else { return false }
        state = true
        return true
    }
    guard accepted else { return }

    DispatchQueue.global(qos: .userInitiated).async {
        log(String(format: "Triple knock detected (%.3f g); ejecting differently", strength))
        let report = SafeEjector.ejectAllExternal()
        if report.succeeded {
            let tm = report.interruptedTimeMachine ? "; Time Machine interrupted safely" : ""
            log("Ejected \(report.ejected.joined(separator: ", "))\(tm)")
            Feedback.success()
        } else {
            log("Ejection refused: \(report.failures.joined(separator: " | "))")
            Feedback.failure()
        }
        ejecting.mutate { $0 = false }
    }
}

sensor.onSample = { x, y, z, time in detector.process(x: x, y: y, z: z, at: time) }
sensor.onGyroSample = { x, y, z, time in detector.processGyro(x: x, y: y, z: z, at: time) }

do {
    try sensor.start()
    log("Eject Different is listening for three knocks")
    dispatchMain()
} catch {
    fputs("fatal: \(error.localizedDescription)\n", stderr)
    exit(1)
}
