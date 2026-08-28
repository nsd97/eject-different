// Sensor access adapted from shaircast/nocnoc and
// olvvier/apple-silicon-accelerometer, both MIT licensed.
import Foundation
import IOKit
import IOKit.hid

public enum SPUError: LocalizedError {
    case unavailable
    case openFailed(kern_return_t)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Apple SPU accelerometer is unavailable"
        case .openFailed(let status): return "Could not open Apple SPU accelerometer (\(status))"
        }
    }
}

public final class SPUAccelerometerService: @unchecked Sendable {
    public var onSample: (@Sendable (Double, Double, Double, TimeInterval) -> Void)?
    public var onGyroSample: (@Sendable (Double, Double, Double, TimeInterval) -> Void)?
    private let queue = DispatchQueue(label: "com.nsd97.eject-different.spu", qos: .userInteractive)
    private var handles: [DeviceHandle] = []
    private var running = false

    public init() {}

    public func start() throws {
        guard !running else { return }
        wakeDrivers()
        let services = matchingServices()
        guard !services.isEmpty else { throw SPUError.unavailable }
        for (service, usage) in services {
            defer { IOObjectRelease(service) }
            guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
            let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard status == kIOReturnSuccess else { throw SPUError.openFailed(status) }
            let handle = DeviceHandle(device: device, owner: self, usage: usage)
            handle.activate(queue: queue)
            handles.append(handle)
        }
        guard !handles.isEmpty else { throw SPUError.unavailable }
        running = true
    }

    public func stop() {
        handles.forEach { $0.stop() }
        handles.removeAll()
        running = false
    }

    fileprivate func deliver(usage: Int, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length == 22 else { return }
        func value(_ offset: Int) -> Double {
            let raw = UInt32(report[offset]) | UInt32(report[offset + 1]) << 8 | UInt32(report[offset + 2]) << 16 | UInt32(report[offset + 3]) << 24
            return Double(Int32(bitPattern: raw)) / 65536.0
        }
        let now = ProcessInfo.processInfo.systemUptime
        if usage == 3 { onSample?(value(6), value(10), value(14), now) }
        if usage == 9 { onGyroSample?(value(6), value(10), value(14), now) }
    }

    private func matchingServices() -> [(io_service_t, Int)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [(io_service_t, Int)] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            let page = property(service, "PrimaryUsagePage")
            let usage = property(service, "PrimaryUsage")
            if page == 0xFF00 && (usage == 3 || usage == 9) { result.append((service, usage!)) } else { IOObjectRelease(service) }
        }
        return result
    }

    private func property(_ service: io_service_t, _ key: String) -> Int? {
        guard let ref = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        return (ref as? NSNumber)?.intValue
    }

    private func wakeDrivers() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            IORegistryEntrySetCFProperty(service, "SensorPropertyReportingState" as CFString, 1 as CFNumber)
            IORegistryEntrySetCFProperty(service, "SensorPropertyPowerState" as CFString, 1 as CFNumber)
            IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString, 1000 as CFNumber)
            IOObjectRelease(service)
        }
    }
}

private final class DeviceHandle {
    let device: IOHIDDevice
    unowned let owner: SPUAccelerometerService
    let usage: Int
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    init(device: IOHIDDevice, owner: SPUAccelerometerService, usage: Int) {
        self.device = device; self.owner = owner; self.usage = usage
    }
    deinit { buffer.deallocate() }
    private static let callback: IOHIDReportWithTimeStampCallback = { context, _, _, _, _, report, length, _ in
        guard let context else { return }
        let handle = Unmanaged<DeviceHandle>.fromOpaque(context).takeUnretainedValue()
        handle.owner.deliver(usage: handle.usage, report: report, length: length)
    }
    func activate(queue: DispatchQueue) {
        IOHIDDeviceSetDispatchQueue(device, queue)
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, buffer, 4096, Self.callback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceActivate(device)
    }
    func stop() {
        IOHIDDeviceCancel(device)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}
