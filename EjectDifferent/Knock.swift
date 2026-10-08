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
// that leaves typing, clicks and the lid well under the weakest knock. A shove
// can still land harder than a knock; the rhythm, not loudness, turns it away.
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

    /// Seconds per tick of the report timestamps, which count in mach absolute time.
    nonisolated static let secondsPerTick: Double = {
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()

    /// Wakes the accelerometer so it reports 800 times a second. Needs root,
    /// so only the daemon calls it; while the daemon runs, any process can read.
    static func wake() throws {
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
    }

    /// Calls `handler` on the main actor for every reading: acceleration in g,
    /// and the time the report arrived, in seconds. Opening the device doesn't
    /// seize it, so the daemon and the app's monitor can both read at once.
    static func start(_ handler: @escaping (SIMD3<Double>, TimeInterval) -> Void) throws {
        self.handler = handler
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

    fileprivate static func deliver(_ value: SIMD3<Double>, at time: TimeInterval) {
        handler?(value, time)
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
/// values cross into it. Its own timestamp is used rather than the time the
/// callback runs, because in the app the main thread is shared with the UI and
/// reports can arrive in bursts.
private nonisolated func reportArrived(_ context: UnsafeMutableRawPointer?, _ result: IOReturn, _ sender: UnsafeMutableRawPointer?, _ type: IOHIDReportType, _ id: UInt32, _ report: UnsafeMutablePointer<UInt8>, _ length: CFIndex, _ timeStamp: UInt64) {
    guard let value = MotionSensor.axes(UnsafeRawBufferPointer(start: report, count: length)) else { return }
    let time = Double(timeStamp) * MotionSensor.secondsPerTick
    MainActor.assumeIsolated { MotionSensor.deliver(value, at: time) }
}

/// Hears three knocks in a row, on a lap or a desk, and nothing else: not
/// typing, not clicking, not shifting around, not one knock or two. It answers
/// the moment the third knock lands.
///
/// The daemon, the Debug build's live monitor and the evaluation in the tests
/// all run this same code. The constants were measured on 2026-10-08 with an
/// M2 Max MacBook Pro on a lap; Evaluation/ holds that recording and every one
/// since, and the corpus test scores the detector against all of them. Tune
/// only against recordings marked "tuning" (see AGENTS.md).
struct KnockDetector {
    /// What one reading meant, when it meant something.
    enum Event: Equatable {
        /// A knock began. Number 3 completes a triple, reported the instant it lands.
        case knock(Int)
        /// An impact began that doesn't count, and why.
        case ignored(Reason)
        /// The impact that began last has stopped ringing; its loudest, in g.
        case ended(peak: Double)
    }

    enum Reason: String {
        case tooSoon = "too soon after the last impact"
        case noPause = "no pause before it"
        case coolingDown = "just after three knocks"
    }

    /// Readings per second, the sensor's fastest rate.
    static let sampleRate = 800.0
    /// Motion slower than this, in Hz, is ignored. On a lap that is nearly all
    /// of the motion; the energy of a knock sits above it.
    static let cutoff = 40.0
    /// An impact is over once the band has stayed under `rearm` this long
    /// (seconds). A ring isn't over just because it dips through zero, as a
    /// vibration along one axis does every half cycle, and a shove that lands
    /// in parts 0.01 to 0.02 s apart stays one impact.
    static let settle = 0.02
    /// Knocks in a triple come at least this far apart (seconds); a bounce
    /// sooner than that doesn't count. Measured knocks came 0.27 to 0.36 s apart.
    static let shortestGap = 0.10
    /// Knocks further apart than this don't belong together (seconds). A run of
    /// knocks also has to start after at least this long without an impact, so
    /// something that keeps jolting the Mac can't start one.
    static let longestGap = 0.60
    /// After a triple knock, everything is ignored for this long (seconds).
    static let cooldown = 1.5

    /// An impact starts when knock-band acceleration crosses this, in g.
    /// Measured on the lap: the weakest real knock reached 0.054, a hard Return
    /// keypress 0.031, the lid 0.018, shifting in the seat 0.014, typing 0.011,
    /// trackpad clicks 0.006. One shove reached 0.155, but as a single impact.
    /// The corpus test reports the range of triggers that work.
    var trigger = 0.041
    /// An impact is over, and the next one can count, once the band has stayed
    /// below this for `settle`. Measured knocks ring for about 30 ms above it.
    var rearm: Double { trigger / 3 }
    /// Knock-band acceleration at the latest reading, in g.
    private(set) var level = 0.0

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
    private var peak = 0.0
    private var quietSince: TimeInterval?
    private var knocks: [TimeInterval] = []
    private var lastImpact = -Double.infinity
    private var quietUntil = -Double.infinity

    /// Feeds one accelerometer reading, in g, taken at `time` seconds.
    mutating func hears(_ acceleration: SIMD3<Double>, at time: TimeInterval) -> Event? {
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
        return hears(level: simd_length(shake), at: time)
    }

    /// The rhythm alone, fed an already-filtered level. The evaluation uses it to
    /// try other triggers without filtering a recording again.
    mutating func hears(level: Double, at time: TimeInterval) -> Event? {
        self.level = level
        if !armed {
            peak = max(peak, level)
            guard level < rearm else {
                quietSince = nil
                return nil
            }
            let quiet = quietSince ?? time
            quietSince = quiet
            guard time - quiet >= Self.settle else { return nil }
            armed = true
            quietSince = nil
            return .ended(peak: peak)
        }
        guard level >= trigger else { return nil }
        armed = false
        peak = level

        let sinceLast = time - lastImpact
        lastImpact = time
        guard time >= quietUntil else { return .ignored(.coolingDown) }
        if !knocks.isEmpty, sinceLast >= Self.shortestGap, sinceLast <= Self.longestGap {
            knocks.append(time)
        } else if sinceLast > Self.longestGap {
            knocks = [time]
        } else {
            return .ignored(sinceLast < Self.shortestGap ? .tooSoon : .noPause)
        }
        let number = knocks.count
        if number == 3 {
            knocks.removeAll()
            quietUntil = time + Self.cooldown
        }
        return .knock(number)
    }
}
