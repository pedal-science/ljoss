#if os(macOS)
import CoreAudio
import Foundation

// The Mac's own devices, for the settings page that chooses which one the local engine uses.
//
// namchaind is told a device by its CoreAudio **UID** rather than by an index or a name, because a
// UID is what survives a replug, a restart and a change of which device is the system default —
// which is exactly what a stored preference has to survive. This file is what turns the HAL's
// objects into those UIDs, and it is deliberately read-only: nothing here selects a device, sets a
// default, or starts an IOProc, so nothing here can change what the Mac is doing.
//
// Every failure degrades to an empty list or nil rather than trapping. The HAL is shared and
// asynchronous: a device can be unplugged between the call that lists it and the call that asks for
// its name, and a settings page that crashed when someone pulled a USB interface out would be a
// worse bug than one that briefly forgot the interface existed. There is no caching for the same
// reason — the answer is a property read, and a stale answer here would offer a device that has
// gone.
//
// iOS has no such enumeration and no `namchaind` to give it to, so the whole file is macOS-only and
// the settings page asks for it behind the same condition.

/// One CoreAudio device, as the settings page needs it: what to show, what to store, and whether
/// it can be an input or an output.
struct CoreAudioDevice: Identifiable, Equatable, Sendable {
    var uid: String
    var name: String
    var inputChannels: Int
    var outputChannels: Int
    var id: String { uid }
}

enum CoreAudioDevices {

    /// Every device the HAL knows about, in the HAL's order.
    static func all() -> [CoreAudioDevice] {
        deviceIDs().compactMap(device(with:))
    }

    /// Those that can capture, in the HAL's order.
    ///
    /// A device with inputs is not always one the engine can use — namchaind wants two channels for
    /// the `coreaudio` backend's stereo capture — but the channel count is kept on the device so the
    /// page can say so rather than this list silently hiding hardware the user owns.
    static func inputs() -> [CoreAudioDevice] {
        all().filter { $0.inputChannels > 0 }
    }

    /// Those that can play, in the HAL's order.
    static func outputs() -> [CoreAudioDevice] {
        all().filter { $0.outputChannels > 0 }
    }

    /// The system's default input device UID, or nil when there is none.
    static func defaultInputUID() -> String? {
        defaultUID(kAudioHardwarePropertyDefaultInputDevice)
    }

    /// The system's default output device UID, or nil when there is none.
    static func defaultOutputUID() -> String? {
        defaultUID(kAudioHardwarePropertyDefaultOutputDevice)
    }

    // MARK: - The HAL's objects

    /// The system object, which is where the device list and the defaults live.
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        // The size is asked for separately because it is the count: a property whose size is zero,
        // or a HAL that will not answer, is an empty device list rather than an error.
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }

        let capacity = Int(size) / MemoryLayout<AudioObjectID>.size
        guard capacity > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: capacity)
        var written = size
        let status = ids.withUnsafeMutableBufferPointer { buffer in
            // `capacity` is positive, so the buffer the HAL is handed is not empty.
            AudioObjectGetPropertyData(system, &address, 0, nil, &written, buffer.baseAddress!)
        }
        guard status == noErr else { return [] }
        // The HAL fills what it has; a device removed while this ran means fewer ids came back than
        // the size promised, and the tail is left as zeroes.
        return Array(ids.prefix(Int(written) / MemoryLayout<AudioObjectID>.size))
    }

    private static func device(with id: AudioObjectID) -> CoreAudioDevice? {
        // A device whose UID cannot be read is one that is going away, or one that has no UID to
        // store. Skipping it is what makes this safe to call while something is being unplugged: a
        // row that stored an empty UID would match no device at all and could never be corrected.
        guard let uid = string(of: id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else {
            return nil
        }
        // The name is what a person recognises, so it is preferred; the UID is a poor label but a
        // truthful one, and a nameless device is still a device that can be chosen.
        let name = string(of: id, kAudioObjectPropertyName) ?? ""
        return CoreAudioDevice(uid: uid,
                               name: name.isEmpty ? uid : name,
                               inputChannels: channels(of: id, scope: kAudioObjectPropertyScopeInput),
                               outputChannels: channels(of: id, scope: kAudioObjectPropertyScopeOutput))
    }

    /// The default device's UID, which is read in two steps: the HAL names an object id, and the uid
    /// property turns that into the thing the settings file stores.
    private static func defaultUID(_ selector: AudioObjectPropertySelector) -> String? {
        guard let id: AudioObjectID = get(system, selector, default: 0), id != 0 else { return nil }
        return string(of: id, kAudioDevicePropertyDeviceUID)
    }

    /// \brief How many channels a device offers on one side.
    ///
    /// The stream configuration is a variable-length `AudioBufferList`: many devices describe their
    /// channels as several buffers, so the size is asked for first and the block allocated rather
    /// than assumed to be one buffer. The answer is the sum over the buffers, which is what a total
    /// channel count means to someone choosing an input.
    private static func channels(of id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                mScope: scope,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }

        let alignment = MemoryLayout<AudioBufferList>.alignment
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }

        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// A `CFString` property, as a Swift `String` or nil.
    private static func string(of id: AudioObjectID,
                               _ selector: AudioObjectPropertySelector) -> String? {
        guard let value: CFString = get(id, selector, default: "" as CFString) else { return nil }
        return value as String
    }

    /// \brief Read one property into a value of a known type.
    ///
    /// The buffer starts as \p fallback because CoreAudio fills in what it has: a property that
    /// answers with a shorter value than was asked for — or with none at all — would otherwise be
    /// read as whatever was in that memory. The status is the other half of the same rule, and it is
    /// what turns a device that has just been unplugged into nil rather than into a stale UID.
    private static func get<T>(_ objectID: AudioObjectID,
                               _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                               default fallback: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var size = UInt32(MemoryLayout<T>.size)
        var value = fallback
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, size > 0 else { return nil }
        return value
    }
}
#endif
