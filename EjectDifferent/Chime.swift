// The sound a knock makes.
//
// You need to hear whether it is safe to pull the cable, even through a closed
// lid, a muted Mac, or a noisy room. So the chime briefly unmutes the Mac and
// turns the built-in speakers all the way up, then puts both back exactly.
// Headphones and AirPods keep your volume: a chime at full volume in your
// ears would hurt.

import AVFAudio
import CoreAudio
import Foundation
import IOKit.audio

enum Chime {
    case success  // an original C-major add-9 chord (Scripts/generate-success-chord.py)
    case refusal  // macOS's own Sosumi

    /// Both sounds, decoded once. Creating a player doesn't claim the audio
    /// hardware; play() does, and gives it back when the sound ends.
    private static let players: [Chime: AVAudioPlayer] = [
        .success: Bundle.main.url(forResource: "different", withExtension: "wav"),
        .refusal: URL(filePath: "/System/Library/Sounds/Sosumi.aiff"),
    ].compactMapValues { url in url.flatMap { try? AVAudioPlayer(contentsOf: $0) } }

    /// Loads the sounds and Core Audio up front, so the first chime after the
    /// Mac starts comes as quickly as every later one (about 30 ms, not 200).
    static func load() {
        _ = players
        _ = defaultOutput()
    }

    static func play(_ chime: Chime) async {
        guard let player = players[chime] else { return }

        let output = defaultOutput()
        let muted: UInt32? = output.flatMap { property($0, kAudioDevicePropertyMute) }
        let volume: Float32? = output.flatMap { property($0, kAudioDevicePropertyVolumeScalar) }
        let loud = output.map(isBuiltInSpeaker) ?? false

        if let output {
            setProperty(output, kAudioDevicePropertyMute, UInt32(0))
            if loud { setProperty(output, kAudioDevicePropertyVolumeScalar, Float32(1)) }
        }
        player.currentTime = 0
        player.play()
        try? await Task.sleep(for: .seconds(player.duration))
        if let output {
            if loud, let volume { setProperty(output, kAudioDevicePropertyVolumeScalar, volume) }
            if let muted { setProperty(output, kAudioDevicePropertyMute, muted) }
        }
    }

    private static func defaultOutput() -> AudioObjectID? {
        property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
    }

    /// The Mac's own speakers: a built-in device whose output stream is a speaker.
    /// The built-in streams report the I/O Kit code OUTPUT_SPEAKER (0x0301)
    /// rather than Core Audio's 'spkr', so either counts. Wired headphones report
    /// OUTPUT_HEADPHONES, and AirPods and displays aren't built-in, so they all
    /// keep their volume.
    private static func isBuiltInSpeaker(_ device: AudioObjectID) -> Bool {
        let transport: UInt32? = property(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
        guard transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr else { return false }
        return streams.contains { stream in
            let terminal: UInt32? = property(stream, kAudioStreamPropertyTerminalType, kAudioObjectPropertyScopeGlobal)
            return terminal == kAudioStreamTerminalTypeSpeaker || terminal == UInt32(OUTPUT_SPEAKER)
        }
    }

    /// Reads a fixed-size Core Audio property, or nil when the object lacks it.
    private static func property<T: Numeric & BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectHasProperty(object, &address), AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// Writes an output property when the device allows it, and does nothing otherwise.
    /// A display over HDMI, for example, has no volume control.
    private static func setProperty<T: Numeric & BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        var value = value
        guard AudioObjectHasProperty(object, &address),
              AudioObjectIsPropertySettable(object, &address, &settable) == noErr, settable.boolValue
        else { return }
        AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }
}
