// Eject Different is one executable that plays three parts:
//
//   (no arguments)  the app: one window where you turn listening on or off
//   --daemon        the listener, run as root by launchd once you approve it
//   --list          a dry run that prints what a knock would eject, then exits
//
// Keeping the app and its daemon in one binary means they can never drift
// apart. The daemon's launchd plist (LaunchDaemons/) points back here.

import Foundation
import SwiftUI
import os

switch CommandLine.arguments.dropFirst().first {
case "--daemon":
    Daemon.run()
case "--list":
    for volume in Eject.unpluggableVolumes() { print(volume.url.path(percentEncoded: false)) }
    exit(0)
default:
    EjectDifferentApp.main()
}

/// The listener. It runs as root because the motion sensor has to be woken
/// through the I/O Registry, which only root may write. Everything happens on
/// the main actor: sensor readings arrive on the main queue, and ejecting
/// awaits rather than blocks, so the Mac keeps listening while a disk ejects.
enum Daemon {
    static let log = Logger(subsystem: "com.nsd97.EjectDifferent", category: "daemon")
    private static var detector = KnockDetector()
    private static var ejecting = false

    static func run() -> Never {
        // On AC power, keep the Mac awake, lid closed or not, so it can hear a
        // knock. caffeinate(8) documents -s as "valid only when system is
        // running on AC power", so on battery the Mac sleeps as usual. -w ends
        // the assertion when this process ends. Display sleep is untouched.
        _ = try? Process.run(URL(filePath: "/usr/bin/caffeinate"), arguments: ["-s", "-w", String(getpid())])
        Chime.load()

        do {
            try MotionSensor.start(heard)
        } catch {
            log.fault("Cannot read the motion sensor: \(String(describing: error), privacy: .public)")
            exit(1)
        }
        log.notice("Listening for three knocks")
        dispatchMain()
    }

    private static func heard(_ acceleration: SIMD3<Double>, _ time: TimeInterval) {
        guard let knock = detector.hears(acceleration, at: time) else { return }
        log.info("Knock \(knock.number): \(knock.strength, format: .fixed(precision: 3)) g")
        // Knocks while a previous knock is still ejecting are ignored. Time
        // Machine can hold an eject open for `Eject.timeMachineGrace`, far
        // longer than `KnockDetector.cooldown`.
        guard knock.number == 3, !ejecting else { return }
        ejecting = true
        log.notice("Three knocks")
        Task {
            let result = await Eject.everything()
            await Chime.play(result.succeeded ? .success : .refusal)
            ejecting = false
        }
    }
}
