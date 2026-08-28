import XCTest
@testable import EjectDifferentCore

final class KnockSequenceTests: XCTestCase {
    func testOnlyTripleKnockEmitsAfterGroupingWindow() {
        var sequence = KnockSequence(groupingWindow: 0.40, minimumGap: 0.10)
        XCTAssertNil(sequence.registerImpact(at: 10.00))
        XCTAssertNil(sequence.registerImpact(at: 10.15))
        XCTAssertNil(sequence.registerImpact(at: 10.30))
        XCTAssertNil(sequence.finishIfReady(at: 10.69))
        XCTAssertEqual(sequence.finishIfReady(at: 10.71), .triple)
    }

    func testSingleAndDoubleKnocksAreIgnored() {
        var single = KnockSequence(groupingWindow: 0.40, minimumGap: 0.10)
        _ = single.registerImpact(at: 1.0)
        XCTAssertNil(single.finishIfReady(at: 1.5))

        var double = KnockSequence(groupingWindow: 0.40, minimumGap: 0.10)
        _ = double.registerImpact(at: 2.0)
        _ = double.registerImpact(at: 2.2)
        XCTAssertNil(double.finishIfReady(at: 2.7))
    }

    func testBounceInsideMinimumGapDoesNotCount() {
        var sequence = KnockSequence(groupingWindow: 0.40, minimumGap: 0.10)
        _ = sequence.registerImpact(at: 1.00)
        _ = sequence.registerImpact(at: 1.03)
        _ = sequence.registerImpact(at: 1.20)
        XCTAssertNil(sequence.finishIfReady(at: 1.70))
    }
}

final class GyroscopeKnockTests: XCTestCase {
    func testThreeGyroscopeImpulsesTriggerTripleKnock() {
        let detector = TripleKnockDetector()
        let triggered = expectation(description: "triple gyro knock")
        detector.onTripleKnock = { _ in triggered.fulfill() }

        detector.processGyro(x: 8, y: 0, z: 0, at: 10.00)
        detector.processGyro(x: 9, y: 0, z: 0, at: 10.15)
        detector.processGyro(x: 8, y: 0, z: 0, at: 10.30)
        detector.processGyro(x: 0, y: 0, z: 0, at: 10.71)

        wait(for: [triggered], timeout: 0.1)
    }
}

final class TimeMachinePolicyTests: XCTestCase {
    func testBackupdDissentIsForceEligible() {
        let output = "Unmount was dissented by PID 123 (/System/Library/CoreServices/backupd.bundle/Contents/Resources/backupd)"
        XCTAssertTrue(TimeMachinePolicy.forceEjectEligible(failureOutput: output))
    }

    func testOrdinaryBusyProcessIsNotForceEligible() {
        let output = "Unmount was dissented by PID 98343 (/opt/homebrew/Cellar/rsync/3.4.4/bin/rsync)"
        XCTAssertFalse(TimeMachinePolicy.forceEjectEligible(failureOutput: output))
    }

    func testBackupdMatchIsCaseInsensitive() {
        XCTAssertTrue(TimeMachinePolicy.forceEjectEligible(failureOutput: "DISSENTED BY PID 7 (BACKUPD)"))
    }

    func testEmptyFailureIsNotForceEligible() {
        XCTAssertFalse(TimeMachinePolicy.forceEjectEligible(failureOutput: ""))
    }
}

final class EjectionPlanTests: XCTestCase {
    func testTimeMachineStopAlwaysPrecedesDiskEjection() {
        let plan = EjectionPlan.make(timeMachineRunning: true, wholeDisks: ["disk4", "disk7"])
        XCTAssertEqual(plan, [.stopTimeMachine, .eject("disk4"), .eject("disk7")])
    }

    func testIdleTimeMachineNeedsNoStop() {
        let plan = EjectionPlan.make(timeMachineRunning: false, wholeDisks: ["disk4"])
        XCTAssertEqual(plan, [.eject("disk4")])
    }

    func testNoExternalDisksProducesNoActions() {
        XCTAssertEqual(EjectionPlan.make(timeMachineRunning: true, wholeDisks: []), [])
    }
}

final class DiskutilParserTests: XCTestCase {
    func testParsesWholeDiskIdentifiersFromDiskutilPlist() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>AllDisks</key><array><string>disk10</string><string>disk11</string></array>
        <key>WholeDisks</key><array><string>disk10</string></array></dict></plist>
        """.data(using: .utf8)!
        XCTAssertEqual(try DiskutilParser.wholeDisks(from: plist), ["disk10"])
    }
}
