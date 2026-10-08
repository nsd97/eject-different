// The one window. It does one thing: turn listening on or off.
//
// Turning it on registers the daemon with SMAppService. macOS then asks you to
// approve it in System Settings › General › Login Items & Extensions, because
// it runs as root. Opening the app (or running the tests it hosts) never
// changes anything; Debug builds also start reading the sensor for the
// monitor in Monitor.swift, which only reads.

import AppKit
import ServiceManagement
import SwiftUI

struct EjectDifferentApp: App {
    var body: some Scene {
        Window("Eject Different", id: "main") {
            StatusView()
        }
        .windowResizability(.contentSize)
    }
}

/// Where the listener stands, as one plain sentence and at most one button.
enum Listener {
    case noSensor, notInApplications, off, awaitingApproval, on

    static let daemon = SMAppService.daemon(plistName: "com.nsd97.EjectDifferent.daemon.plist")

    static var current: Listener {
        guard MotionSensor.isPresent else { return .noSensor }
        switch daemon.status {
        case .enabled: return .on
        case .requiresApproval: return .awaitingApproval
        default:
            // SMAppService.h asks that an app registering helpers live in /Applications.
            return Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications" ? .off : .notInApplications
        }
    }

    /// Copy follows the HIG's Writing guidance: as few words as possible,
    /// "your" only where it adds meaning, and one term ("in use") everywhere.
    var message: String {
        switch self {
        case .noSensor: "This Mac has no motion sensor. Eject Different needs a MacBook with Apple silicon."
        case .notInApplications: "Move Eject Different to the Applications folder, then open it again."
        case .off: "Every external drive and SD card ejects, unless it’s in use."
        case .awaitingApproval: "Allow Eject Different in System Settings to finish turning it on."
        case .on: "On. Every external drive and SD card ejects, unless it’s in use."
        }
    }
}

struct StatusView: View {
    @State private var listener = Listener.current
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "eject.fill")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Knock three times to eject.")
                .font(.title2.weight(.semibold))
            Text(listener.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            action
                .controlSize(.large)
                .padding(.top, 6)
            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            #if DEBUG
            if listener != .noSensor {
                Divider().padding(.vertical, 6)
                MonitorView(listenerOn: listener == .on)
            }
            #endif
        }
        .padding(36)
        .frame(width: 460)
        .task {
            // Coming back from System Settings is how approval arrives.
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                listener = .current
            }
        }
    }

    @ViewBuilder private var action: some View {
        switch listener {
        case .off:
            Button("Turn On") { change { try Listener.daemon.register() } }
                .buttonStyle(.borderedProminent)
        case .awaitingApproval:
            Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                .buttonStyle(.borderedProminent)
        case .on:
            Button("Turn Off") { change { try Listener.daemon.unregister() } }
        case .noSensor, .notInApplications:
            EmptyView()
        }
    }

    /// Registers or unregisters the daemon, then reads the status again. register()
    /// throws "denied by user" until the daemon is approved, and that is the normal
    /// path, so an error is shown only when nothing moved.
    private func change(_ operation: () throws -> Void) {
        let before = listener
        do { try operation(); problem = nil } catch { problem = error.localizedDescription }
        listener = .current
        if listener != before { problem = nil }
    }
}
