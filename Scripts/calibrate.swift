#!/usr/bin/env swift
// Records a guided calibration session: the raw accelerometer while you knock,
// type, click and shift around, one prompt at a time. This is how
// KnockDetector's constants were measured, and how to remeasure them on another
// Mac:
//
//   1. Turn Eject Different on. Its listener keeps the sensor awake, so this
//      script needs no sudo.
//   2. swift Scripts/calibrate.swift session.bin
//   3. Replay session.bin through KnockDetector the way
//      EjectDifferentTests/LapCalibrationReplayTests does, using the step
//      indices this script prints, and retune the constants until every step
//      behaves.
//
// The file holds one reading per 1.25 ms: x, y, z as little-endian Int16 in
// units of 1/16384 g, the same format as EjectDifferentTests/lap-calibration.bin.

import Foundation
import IOKit
import IOKit.hid

let steps: [(label: String, prompt: String, seconds: Double)] = [
    ("still", "Sit normally, hands off the Mac.", 5),
    ("triple", "Knock three times, wherever and however you'd naturally knock to eject.", 6),
    ("triple", "Again: knock three times.", 6),
    ("triple", "Once more: knock three times.", 6),
    ("single", "Knock once.", 4),
    ("single", "Knock once.", 4),
    ("single", "Knock once.", 4),
    ("typing", "Type anything, at your normal speed.", 10),
    ("trackpad", "Click the trackpad a few times.", 6),
    ("shift", "Shift in your seat, or move your legs.", 6),
    ("shift", "Again: shift around, like you would while working.", 6),
    ("lid", "Close the lid halfway, then open it again.", 8),
]

let path = CommandLine.arguments.dropFirst().first ?? "calibration.bin"
var readings = Data()

let callback: IOHIDReportCallback = { _, _, _, _, _, report, length in
    guard length == 22 else { return }
    let bytes = UnsafeRawBufferPointer(start: report, count: length)
    for offset in [6, 10, 14] {
        let g = Double(Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int32.self))) / 65536
        withUnsafeBytes(of: Int16(clamping: Int((g * 16384).rounded())).littleEndian) { readings.append(contentsOf: $0) }
    }
}

// The SPU accelerometer: usage page 0xFF00, usage 3.
var iterator: io_iterator_t = 0
IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &iterator)
var device: IOHIDDevice?
while case let service = IOIteratorNext(iterator), service != 0 {
    let page = IORegistryEntryCreateCFProperty(service, "PrimaryUsagePage" as CFString, nil, 0)?.takeRetainedValue() as? Int
    let usage = IORegistryEntryCreateCFProperty(service, "PrimaryUsage" as CFString, nil, 0)?.takeRetainedValue() as? Int
    if page == 0xFF00, usage == 3, let candidate = IOHIDDeviceCreate(nil, service), IOHIDDeviceOpen(candidate, 0) == kIOReturnSuccess {
        IOHIDDeviceRegisterInputReportCallback(candidate, UnsafeMutablePointer<UInt8>.allocate(capacity: 64), 64, callback, nil)
        IOHIDDeviceScheduleWithRunLoop(candidate, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        device = candidate
    }
}

RunLoop.main.run(until: Date().addingTimeInterval(0.5))
guard device != nil, readings.count > 100 * 6 else {
    print("No sensor readings. Turn Eject Different on first (it keeps the sensor awake), then run this again.")
    exit(1)
}

print("\nCalibration: \(steps.count) short steps, about 70 seconds.")
print("Use the Mac the way you want it to work (on your lap, or on a desk). Do each step when it appears.\n")
readings.removeAll()
var starts: [Int] = []
for (index, step) in steps.enumerated() {
    starts.append(readings.count / 6)
    print(String(format: "%2d/%d  %@", index + 1, steps.count, step.prompt), terminator: "  ")
    fflush(stdout)
    let end = Date().addingTimeInterval(step.seconds)
    var shown = Int(step.seconds) + 1
    while Date() < end {
        RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.05)))
        let left = Int(end.timeIntervalSinceNow.rounded(.up))
        if left < shown && left > 0 { print("\(left)…", terminator: " "); fflush(stdout); shown = left }
    }
    print("")
}
try readings.write(to: URL(filePath: path))
print("\nSaved \(readings.count / 6) readings to \(path).")
print("Steps start at readings:", zip(steps, starts).map { "\($0.label) \($1)" }.joined(separator: ", "))
