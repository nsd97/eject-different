// The motion sensor, and what a knock looks like to it.
//
// Apple silicon MacBooks carry a Bosch IMU behind the Sensor Processing Unit
// (SPU). There is no public API for it. macOS shows its accelerometer only as a
// vendor-defined HID device (AppleSPUHIDDevice, usage page 0xFF00, usage 3)
// reporting in g. The report layout and the properties that wake the driver
// come from olvvier/apple-silicon-accelerometer and shaircast/nocnoc (MIT; see
// THIRD_PARTY_NOTICES.md). Mac mini and Mac Studio have no IMU at all.
//
// Knocks are told apart by frequency. A Mac on a lap is never still, but that
// motion is slow, under about 15 Hz. A knuckle on aluminum is an impact whose
// energy sits between about 15 and 80 Hz; the sensor reports little above that.
// So the detector listens only above `KnockDetector.cutoff`. Measured on a lap,
// that leaves typing, clicks and shifting around well under the weakest knock.
// The gyroscope is not used: on a lap it mostly measures the lap.

import Accelerate
import Foundation
import IOKit
import IOKit.hid
import simd

enum MotionSensor {
    enum Failure: Error {
        case missing
        case wake(kern_return_t)  // kIOReturnNotPrivileged means not running as root
        case open(IOReturn)
    }

    /// Every accelerometer report is 22 bytes (MaxInputReportSize in the I/O Registry).
    nonisolated static let reportLength = 22

    /// True when this Mac has the sensor. The app uses it to say so plainly.
    static var isPresent: Bool {
        let found = accelerometers("AppleSPUHIDDevice")
        found.forEach { IOObjectRelease($0) }
        return !found.isEmpty
    }

    private static var handler: ((SIMD3<Double>, TimeInterval) -> Void)?
    private static var device: IOHIDDevice?  // kept open for the life of the process

    /// Wakes the accelerometer and calls `handler` on the main actor for every
    /// reading, in g, 800 times a second. Needs root.
    static func start(_ handler: @escaping (SIMD3<Double>, TimeInterval) -> Void) throws {
        self.handler = handler

        // Ask the driver to report every millisecond (ReportInterval is in
        // microseconds). Its fastest rate is 800 a second (the driver's
        // sensor_rates property), and that is what arrives. The knock filter is
        // designed for that rate. The SPU's other sensors stay asleep.
        for driver in accelerometers("AppleSPUHIDDriver") {
            defer { IOObjectRelease(driver) }
            for (key, value) in [("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1), ("ReportInterval", 1000)] {
                let status = IORegistryEntrySetCFProperty(driver, key as CFString, value as CFNumber)
                guard status == KERN_SUCCESS else { throw Failure.wake(status) }
            }
        }

        guard let service = accelerometers("AppleSPUHIDDevice").first else { throw Failure.missing }
        defer { IOObjectRelease(service) }
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { throw Failure.missing }
        let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else { throw Failure.open(status) }
        // IOHIDDevice.h: set the queue once, register the callback, then activate.
        // The report buffer and device live as long as the process does.
        IOHIDDeviceSetDispatchQueue(device, .main)
        let report = UnsafeMutablePointer<UInt8>.allocate(capacity: reportLength)
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, report, reportLength, reportArrived, nil)
        IOHIDDeviceActivate(device)
        self.device = device
    }

    /// x, y and z from one report: little-endian Q16.16 fixed point at bytes 6, 10 and 14.
    nonisolated static func axes(_ report: UnsafeRawBufferPointer) -> SIMD3<Double>? {
        guard report.count == reportLength else { return nil }
        func axis(_ offset: Int) -> Double {
            Double(Int32(littleEndian: report.loadUnaligned(fromByteOffset: offset, as: Int32.self))) / 65536
        }
        return SIMD3(axis(6), axis(10), axis(14))
    }

    fileprivate static func deliver(_ value: SIMD3<Double>) {
        handler?(value, ProcessInfo.processInfo.systemUptime)
    }

    /// The SPU accelerometer's entries of an I/O Kit class. Its driver and device
    /// both carry usage page 0xFF00, usage 3. The caller releases each service.
    private static func accelerometers(_ className: String) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            func number(_ key: String) -> Int? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            }
            if number("PrimaryUsagePage") == 0xFF00, number("PrimaryUsage") == 3 {
                found.append(service)
            } else {
                IOObjectRelease(service)
            }
        }
        return found
    }
}

/// The HID callback. The device is scheduled on the main queue, so the main
/// actor is already running here. The report is parsed first, so only plain
/// values cross into it.
private nonisolated func reportArrived(_ context: UnsafeMutableRawPointer?, _ result: IOReturn, _ sender: UnsafeMutableRawPointer?, _ type: IOHIDReportType, _ id: UInt32, _ report: UnsafeMutablePointer<UInt8>, _ length: CFIndex, _ timeStamp: UInt64) {
    guard let value = MotionSensor.axes(UnsafeRawBufferPointer(start: report, count: length)) else { return }
    MainActor.assumeIsolated { MotionSensor.deliver(value) }
}

/// Hears three knocks in a row, on a lap or a desk, and nothing else: not
/// typing, not clicking, not shifting around, not one knock or two. It answers
/// the moment the third knock lands.
///
/// The thresholds were measured on 2026-10-08 with an M2 Max MacBook Pro on a
/// lap: three triple knocks, three single knocks, typing, trackpad clicks,
/// shifting in a seat, and moving the lid. That recording is replayed in the
/// tests (EjectDifferentTests/lap-calibration.bin). To recalibrate, record a new
/// session with Scripts/calibrate.swift, retune these constants, and keep the
/// replay test passing.
struct KnockDetector {
    /// One knock as heard: its place in the current run (3 completes a triple)
    /// and the knock-band acceleration, in g, at the reading that crossed the trigger.
    struct Knock {
        let number: Int
        let strength: Double
    }

    /// Readings per second, the sensor's fastest rate.
    static let sampleRate = 800.0
    /// Motion slower than this, in Hz, is ignored. On a lap that is nearly all
    /// of the motion; the energy of a knock sits above it.
    static let cutoff = 40.0
    /// A knock starts when knock-band acceleration crosses this, in g. Measured:
    /// the weakest real knock reached 0.054, a hard Return keypress 0.031,
    /// shifting in the seat 0.014, typing 0.011, trackpad clicks 0.006. The
    /// trigger sits halfway between the knock and the keypress, in ratio.
    static let trigger = 0.041
    /// A knock is over, and the next impact can count, once the band falls below
    /// this. Measured knocks ring for about 30 ms above it.
    static let rearm = trigger / 3
    /// Knocks in a triple come at least this far apart (seconds). One shove of
    /// the Mac can break into impacts 0.01 to 0.02 s apart; measured knocks came
    /// 0.27 to 0.36 s apart.
    static let shortestGap = 0.10
    /// Knocks further apart than this don't belong together (seconds). A run of
    /// knocks also has to start after at least this long without an impact, so
    /// something that keeps jolting the Mac can't start one.
    static let longestGap = 0.60
    /// After a triple knock, everything is ignored for this long (seconds).
    static let cooldown = 1.5

    /// Second-order Butterworth high-pass at `cutoff` (the Audio EQ Cookbook
    /// form, Q = 1/√2), one per axis, run by Accelerate.
    private var filters: [vDSP.Biquad<Double>] = {
        let w = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w) / 2.0.squareRoot()  // sin(w) / (2Q) with Q = 1/√2
        let a0 = 1 + alpha
        let coefficients = [(1 + cos(w)) / 2 / a0, -(1 + cos(w)) / a0, (1 + cos(w)) / 2 / a0, -2 * cos(w) / a0, (1 - alpha) / a0]
        return (0..<3).map { _ in vDSP.Biquad(coefficients: coefficients, channelCount: 1, sectionCount: 1, ofType: Double.self)! }
    }()
    private var input = [0.0], output = [0.0]
    private var origin: SIMD3<Double>?
    private var armed = true
    private var knocks: [TimeInterval] = []
    private var lastImpact = -Double.infinity
    private var quietUntil = -Double.infinity

    /// Feeds one accelerometer reading, in g. Returns the knock it starts, if it
    /// starts one; a knock numbered 3 is a triple knock, reported the instant it lands.
    mutating func hears(_ acceleration: SIMD3<Double>, at time: TimeInterval) -> Knock? {
        // Measuring from the first reading keeps the filter from mistaking
        // switch-on, a jump from zero to gravity, for an impact.
        let origin = self.origin ?? acceleration
        self.origin = origin
        var shake = SIMD3<Double>.zero
        for axis in 0..<3 {
            input[0] = acceleration[axis] - origin[axis]
            filters[axis].apply(input: input, output: &output)
            shake[axis] = output[0]
        }
        let level = simd_length(shake)

        if !armed {
            if level < Self.rearm { armed = true }  // the last impact has stopped ringing
            return nil
        }
        guard level >= Self.trigger else { return nil }
        armed = false

        let sinceLast = time - lastImpact
        lastImpact = time
        guard time >= quietUntil else { return nil }
        if !knocks.isEmpty, sinceLast >= Self.shortestGap, sinceLast <= Self.longestGap {
            knocks.append(time)
        } else if sinceLast > Self.longestGap {
            knocks = [time]
        } else {
            return nil  // too close on the heels of another impact to be a knock
        }
        let knock = Knock(number: knocks.count, strength: level)
        if knocks.count == 3 {
            knocks.removeAll()
            quietUntil = time + Self.cooldown
        }
        return knock
    }
}
