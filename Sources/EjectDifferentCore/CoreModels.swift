import Foundation

public enum KnockPattern: Equatable, Sendable {
    case triple
}

public struct KnockSequence: Sendable {
    public let groupingWindow: TimeInterval
    public let minimumGap: TimeInterval
    private var impacts: [TimeInterval] = []

    public init(groupingWindow: TimeInterval = 0.40, minimumGap: TimeInterval = 0.10) {
        self.groupingWindow = groupingWindow
        self.minimumGap = minimumGap
    }

    @discardableResult
    public mutating func registerImpact(at time: TimeInterval) -> KnockPattern? {
        if let last = impacts.last, time - last < minimumGap { return nil }
        if let last = impacts.last, time - last > groupingWindow { impacts.removeAll() }
        impacts.append(time)
        return nil
    }

    public mutating func finishIfReady(at time: TimeInterval) -> KnockPattern? {
        guard let last = impacts.last, time - last > groupingWindow else { return nil }
        defer { impacts.removeAll() }
        return impacts.count == 3 ? .triple : nil
    }
}

public enum EjectionAction: Equatable, Sendable {
    case stopTimeMachine
    case eject(String)
}

public enum EjectionPlan {
    public static func make(timeMachineRunning: Bool, wholeDisks: [String]) -> [EjectionAction] {
        guard !wholeDisks.isEmpty else { return [] }
        var actions: [EjectionAction] = []
        if timeMachineRunning { actions.append(.stopTimeMachine) }
        actions.append(contentsOf: wholeDisks.sorted().map(EjectionAction.eject))
        return actions
    }
}

public enum DiskutilParser {
    public static func wholeDisks(from data: Data) throws -> [String] {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = plist as? [String: Any], let disks = dictionary["WholeDisks"] as? [String] else {
            return []
        }
        return disks
    }
}
