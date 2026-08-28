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

public enum TimeMachinePolicy {
    /// The wired Time Machine exception: a disk dissented by `backupd` is an
    /// in-progress backup, and the user asked for those disks to be ejected
    /// anyway. Only `backupd` dissents are force-eligible — an rsync, mds, or
    /// app transfer still gets a polite refusal.
    public static func forceEjectEligible(failureOutput: String) -> Bool {
        failureOutput.localizedCaseInsensitiveContains("backupd")
    }
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
                _ = try? Shell.run("/usr/bin/tmutil", ["stopbackup"])
                // Give the backup a graceful chance to park, then proceed
                // regardless — a wired Time Machine disk must not block the
                // knock. If backupd still dissents at eject time, the
                // force-eject exception below handles it.
                for _ in 0..<15 {
                    Thread.sleep(forTimeInterval: 1)
                    guard let check = try? Shell.run("/usr/bin/tmutil", ["status"]),
                          check.text.contains("Running = 1") else { break }
                }
            }

            var ejected: [String] = []
            var failures: [String] = []
            for disk in disks.sorted() {
                let result = try Shell.run("/usr/sbin/diskutil", ["eject", disk])
                if result.status == 0 {
                    ejected.append(disk)
                } else if TimeMachinePolicy.forceEjectEligible(failureOutput: result.text) {
                    // Time Machine exception: interrupt again and force the
                    // wired backup disk loose so the knock still ejects it.
                    _ = try? Shell.run("/usr/bin/tmutil", ["stopbackup"])
                    Thread.sleep(forTimeInterval: 2)
                    let force = try Shell.run("/usr/sbin/diskutil", ["unmountDisk", "force", disk])
                    let ejectAgain = try Shell.run("/usr/sbin/diskutil", ["eject", disk])
                    if force.status == 0 || ejectAgain.status == 0 {
                        ejected.append(disk)
                    } else {
                        failures.append("\(disk): \(result.text)")
                    }
                } else {
                    failures.append("\(disk): \(result.text)")
                }
            }
            return EjectionReport(ejected: ejected, failures: failures, interruptedTimeMachine: tmRunning)
        } catch {
            return EjectionReport(ejected: [], failures: [error.localizedDescription], interruptedTimeMachine: false)
        }
    }
}
