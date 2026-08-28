import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: Data
    public var text: String { String(data: output, encoding: .utf8) ?? "" }
}

public enum Shell {
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: pipe.fileHandleForReading.readDataToEndOfFile())
    }
}

public struct EjectionReport: Sendable {
    public let ejected: [String]
    public let failures: [String]
    public let interruptedTimeMachine: Bool
    public var succeeded: Bool { !ejected.isEmpty && failures.isEmpty }
}

public enum SafeEjector {
    public static func ejectAllExternal() -> EjectionReport {
        do {
            let listing = try Shell.run("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"])
            guard listing.status == 0 else { return EjectionReport(ejected: [], failures: [listing.text], interruptedTimeMachine: false) }
            let disks = try DiskutilParser.wholeDisks(from: listing.output)
            guard !disks.isEmpty else { return EjectionReport(ejected: [], failures: ["No external physical disks are mounted"], interruptedTimeMachine: false) }

            let status = try Shell.run("/usr/bin/tmutil", ["status"])
            let tmRunning = status.text.contains("Running = 1")
            if tmRunning {
                let stop = try Shell.run("/usr/bin/tmutil", ["stopbackup"])
                guard stop.status == 0 else { return EjectionReport(ejected: [], failures: ["Time Machine would not stop: \(stop.text)"], interruptedTimeMachine: false) }
                for _ in 0..<30 {
                    Thread.sleep(forTimeInterval: 1)
                    let check = try Shell.run("/usr/bin/tmutil", ["status"])
                    if !check.text.contains("Running = 1") { break }
                }
                let final = try Shell.run("/usr/bin/tmutil", ["status"])
                guard !final.text.contains("Running = 1") else { return EjectionReport(ejected: [], failures: ["Time Machine did not stop within 30 seconds"], interruptedTimeMachine: false) }
            }

            var ejected: [String] = []
            var failures: [String] = []
            for disk in disks.sorted() {
                let result = try Shell.run("/usr/sbin/diskutil", ["eject", disk])
                if result.status == 0 { ejected.append(disk) } else { failures.append("\(disk): \(result.text)") }
            }
            return EjectionReport(ejected: ejected, failures: failures, interruptedTimeMachine: tmRunning)
        } catch {
            return EjectionReport(ejected: [], failures: [error.localizedDescription], interruptedTimeMachine: false)
        }
    }
}
