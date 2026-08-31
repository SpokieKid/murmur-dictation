import AVFoundation

struct AudioInputDevice: Identifiable, Hashable {
    let uid: String   // AVCaptureDevice.uniqueID
    let name: String
    var id: String { uid }
}

/// Enumerates audio input devices via AVFoundation so the user can pick a mic.
/// (Matches AVCaptureSession, which is what AudioRecorder uses to capture.)
enum AudioDevices {
    static func inputDevices() -> [AudioInputDevice] {
        let types = discoveryTypes()
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                       mediaType: .audio,
                                                       position: .unspecified)
        return session.devices.map { AudioInputDevice(uid: $0.uniqueID, name: $0.localizedName) }
    }

    static func device(forUID uid: String) -> AVCaptureDevice? {
        guard !uid.isEmpty else { return nil }
        return AVCaptureDevice(uniqueID: uid)
    }

    /// Display name of a device, or nil if it isn't currently connected.
    static func name(forUID uid: String) -> String? {
        device(forUID: uid)?.localizedName
    }

    private static func discoveryTypes() -> [AVCaptureDevice.DeviceType] {
        if #available(macOS 14.0, *) {
            return [.microphone, .external]
        } else {
            return [.builtInMicrophone]
        }
    }
}
