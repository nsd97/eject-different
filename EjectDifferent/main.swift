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
import notify
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
    /// Posted with notify(3), which reaches processes of every user, so the app's
    /// monitor can show what the listener heard and whether the chime played.
    /// Watch them with `notifyutil -w <name>`.
    static let tripleNotification = "com.nsd97.EjectDifferent.triple"
    static let chimedNotification = "com.nsd97.EjectDifferent.chimed"
    private static var detector = KnockDetector()
    private static var ejecting = false
    /// How the impact still ringing was heard, logged with its peak when it ends.
    private static var impact = ""

    static func run() -> Never {
        // On AC power, keep the Mac awake, lid closed or not, so it can hear a
        // knock. caffeinate(8) documents -s as "valid only when system is
        // running on AC power", so on battery the Mac sleeps as usual. -w ends
        // the assertion when this process ends. Display sleep is untouched.
        _ = try? Process.run(URL(filePath: "/usr/bin/caffeinate"), arguments: ["-s", "-w", String(getpid())])
        Chime.load()

        do {
            try MotionSensor.wake()
            try MotionSensor.start(heard)
        } catch {
            log.fault("Cannot read the motion sensor: \(String(describing: error), privacy: .public)")
            exit(1)
        }
        log.notice("Listening for three knocks")
        dispatchMain()
    }

    private static func heard(_ acceleration: SIMD3<Double>, _ time: TimeInterval) {
        switch detector.hears(acceleration, at: time) {
        case .knock(let number):
            impact = "Knock \(number)"
            if number == 3 { tripleKnocked() }
        case .ignored(let reason):
            impact = "Not counted, \(reason.rawValue)"
        case .ended(let peak):
            // One saved line per impact, written once its true peak is known.
            log.notice("\(impact, privacy: .public): peak \(peak, format: .fixed(precision: 3)) g")
        case nil:
            break
        }
    }

    private static func tripleKnocked() {
        log.notice("Three knocks")
        // Start a full wake now, before anything else. Lid closed on AC the Mac
        // is in DarkWake with the speakers off; this overlaps the wake with the
        // ejection so the chime is audible the moment the disk leaves.
        Chime.wake()
        notify_post(tripleNotification)
        // Knocks while a previous knock is still ejecting are ignored. Time
        // Machine can hold an eject open for `Eject.timeMachineGrace`, far
        // longer than `KnockDetector.cooldown`.
        guard !ejecting else { return }
        ejecting = true
        Task {
            let result = await Eject.everything()
            if await Chime.play(result.succeeded ? .success : .refusal) {
                notify_post(chimedNotification)
            }
            ejecting = false
        }
    }
}
