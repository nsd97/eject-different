// Which disks a knock ejects, and how.
//
// A knock ejects every mounted volume you could physically unplug: USB and
// Thunderbolt drives, and SD cards. It never ejects the internal disk, a disk
// image (Xcode's simulator runtimes are disk images), or a network share.
//
// A disk that's in use is left alone, with one exception: when Time Machine is
// using it, the backup is stopped and that disk is ejected anyway. You asked for the
// drive, and Time Machine throws away the unfinished backup next time it runs.

import DiskArbitration
import Foundation
import IOKit.storage
import os

enum Eject {
    struct Volume {
        let url: URL
        /// BSD name of the whole disk the volume lives on, for example "disk4".
        let wholeDisk: String
    }

    struct Result {
        var ejected: [String] = []
        var refused: [String] = []
        /// At least one disk ejected and none refused. Nothing attached plays the refusal sound.
        var succeeded: Bool { !ejected.isEmpty && refused.isEmpty }
    }

    /// Seconds Time Machine gets to let go of a disk after its backup is stopped,
    /// before the disk is forced out.
    static let timeMachineGrace = 15

    private static let log = Logger(subsystem: "com.nsd97.EjectDifferent", category: "eject")

    /// Ejects every unpluggable disk, one at a time. It scans again after each
    /// eject, because one eject takes every volume on that disk with it.
    /// Each whole disk is tried once, so the loop always ends.
    static func everything() async -> Result {
        var result = Result()
        var tried: Set<String> = []
        while let volume = unpluggableVolumes().first(where: { !tried.contains($0.wholeDisk) }) {
            tried.insert(volume.wholeDisk)
            if await eject(volume) {
                result.ejected.append(volume.wholeDisk)
            } else {
                result.refused.append(volume.wholeDisk)
            }
        }
        log.notice("Ejected \(result.ejected, privacy: .public); refused \(result.refused, privacy: .public)")
        return result
    }

    /// Mounted volumes on disks you could pull out of the Mac, hidden mounts included.
    static func unpluggableVolumes() -> [Volume] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return mounted.compactMap { url in
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                  let description = DADiskCopyDescription(disk) as? [String: Any],
                  isUnpluggable(description),
                  let whole = DADiskCopyWholeDisk(disk),
                  let name = DADiskGetBSDName(whole)
            else { return nil }
            return Volume(url: url, wholeDisk: String(cString: name))
        }
    }

    /// The rule, given a Disk Arbitration description: removable media (an SD
    /// card in the built-in reader) or a device outside the Mac, never a disk
    /// image. Disk images claim to be removable and external, so they are
    /// excluded by their "Virtual Interface" protocol first. Network shares carry
    /// none of these keys and fall through to false.
    // ponytail: a Thunderbolt enclosure that reports itself internal and fixed is skipped; add a protocol allowlist if one turns up.
    static func isUnpluggable(_ description: [String: Any]) -> Bool {
        if description[kDADiskDescriptionDeviceProtocolKey as String] as? String == kIOPropertyPhysicalInterconnectTypeVirtual {
            return false
        }
        return description[kDADiskDescriptionMediaRemovableKey as String] as? Bool == true
            || description[kDADiskDescriptionDeviceInternalKey as String] as? Bool == false
    }

    /// Time Machine's backup daemon. backupd-helper counts too.
    static func isTimeMachine(_ process: String) -> Bool {
        process.hasPrefix("backupd")
    }

    /// Ejects one disk politely. If Time Machine holds it, stops the backup,
    /// waits up to `timeMachineGrace` for Time Machine to let go, and then
    /// forces the disk out.
    private static func eject(_ volume: Volume) async -> Bool {
        guard let holder = await unmount(volume.url) else { return true }
        guard isTimeMachine(holder) else {
            log.notice("\(volume.wholeDisk, privacy: .public) is in use by \(holder, privacy: .public); leaving it")
            return false
        }

        log.notice("Time Machine is using \(volume.wholeDisk, privacy: .public); stopping the backup")
        await run("/usr/bin/tmutil", "stopbackup")
        for _ in 1...timeMachineGrace {
            try? await Task.sleep(for: .seconds(1))
            // Stopping a backup can unmount some of the disk's volumes, so look
            // again. Nothing left mounted means the disk is safe to unplug.
            guard let mounted = unpluggableVolumes().first(where: { $0.wholeDisk == volume.wholeDisk }),
                  let stillHolding = await unmount(mounted.url)
            else { return true }
            guard isTimeMachine(stillHolding) else {
                log.notice("\(volume.wholeDisk, privacy: .public) is in use by \(stillHolding, privacy: .public); leaving it")
                return false
            }
        }
        // FileManager has no force option, so diskutil does this part. Its
        // `eject force` force-unmounts every volume first (diskutil(8)) and finds
        // the physical disk behind an APFS container.
        log.notice("Time Machine still holds \(volume.wholeDisk, privacy: .public); forcing it out")
        return await run("/usr/sbin/diskutil", "eject", "force", volume.wholeDisk) == 0
    }

    /// Unmounts every volume on the volume's disk and ejects the disk. Returns
    /// nil on success. Otherwise returns the name of the process that refused
    /// (FileManager reports its PID), or why it failed.
    private static func unmount(_ url: URL) async -> String? {
        do {
            try await FileManager.default.unmountVolume(at: url, options: [.allPartitionsAndEjectDisk, .withoutUI])
            return nil
        } catch {
            guard let pid = (error as NSError).userInfo[NSFileManagerUnmountDissentingProcessIdentifierErrorKey] as? pid_t else {
                return error.localizedDescription
            }
            // proc_name returns the name's length, or 0 if the process is already gone.
            var name = [UInt8](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
            let length = proc_name(pid, &name, UInt32(name.count))
            return String(decoding: name.prefix(Int(max(length, 0))), as: UTF8.self)
        }
    }

    /// Runs a command-line tool and returns its exit status, without blocking the main actor.
    @discardableResult
    private static func run(_ tool: String, _ arguments: String...) async -> Int32 {
        await withCheckedContinuation { finished in
            let process = Process()
            process.executableURL = URL(filePath: tool)
            process.arguments = arguments
            process.terminationHandler = { finished.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { finished.resume(returning: -1) }
        }
    }
}
