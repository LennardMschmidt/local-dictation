import AudioToolbox
import CoreAudio
import Foundation

/// The microphones macOS knows about, read through Core Audio.
enum AudioDevices {
    struct Device: Identifiable, Equatable {
        var id: String { uid }
        let uid: String
        let name: String
        let deviceID: AudioDeviceID
        /// How the device is connected (`kAudioDeviceTransportType…`).
        var transport: UInt32 = 0

        var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
        /// Bluetooth headsets switch from music quality to headset mode while their microphone
        /// is open, which interrupts and changes the volume of whatever is playing.
        var isBluetooth: Bool {
            transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        }
    }

    /// Every device with at least one input channel.
    static func inputs() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            guard inputChannels(of: id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(uid: uid, name: name, deviceID: id, transport: transportType(of: id))
        }
    }

    /// The system's current default microphone.
    static func defaultInput() -> Device? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else {
            return nil
        }
        return inputs().first { $0.deviceID == id }
    }

    static func device(uid: String) -> Device? {
        inputs().first { $0.uid == uid }
    }

    /// The microphone to record from: the chosen one, or for "Auto-detect" the system default.
    /// For dictation (`avoidBluetooth`) a Bluetooth default gives way to the built-in microphone,
    /// so headphones keep playing music undisturbed. A meeting takes the Bluetooth headset: in a
    /// call it is in call mode anyway and hears the user from close by, where the built-in
    /// microphone hears them from across the desk.
    static func resolve(uid: String, avoidBluetooth: Bool = true) -> Device? {
        if !uid.isEmpty, let chosen = device(uid: uid) { return chosen }
        guard let system = defaultInput() else { return nil }
        guard avoidBluetooth, system.isBluetooth, let builtIn = inputs().first(where: \.isBuiltIn) else { return system }
        return builtIn
    }

    private static func transportType(of id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func inputChannels(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(pointer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
