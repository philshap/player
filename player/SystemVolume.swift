//
//  SystemVolume.swift
//  player
//

import AudioToolbox
import CoreAudio
import Foundation
import Observation

/// Observes and controls the OS output volume of the default output device,
/// so the system volume can be micro-adjusted without leaving the app.
///
/// Uses the virtual main volume property, which CoreAudio maps onto whatever
/// per-channel volume controls the device actually has. Some devices (HDMI,
/// DisplayPort) expose no volume control at all — `isAvailable` is false then
/// and the UI should hide the control.
///
/// Mute is a separate device property from the volume scalar: macOS mutes when
/// the volume keys reach the bottom, and writing the scalar alone leaves the
/// device silent. So `volume` reads as 0 while muted, raising it unmutes, and
/// setting it to 0 mutes — mirroring the volume keys.
@Observable
final class SystemVolumeController {

    /// Whether the current default output device supports volume control.
    private(set) var isAvailable = false

    /// System output volume (0.0 ... 1.0), reported as 0 while muted. Setting
    /// writes through to the device; external changes (volume keys, Control
    /// Center) are reflected back here.
    var volume: Float = 0 {
        didSet {
            guard !isSyncingFromDevice, volume != oldValue else { return }
            writeDevice(volume: volume.clamped(to: 0...1))
        }
    }

    /// Step for the micro-adjust buttons — matches option-shift volume keys (1/64).
    static let microStep: Float = 1.0 / 64.0

    @ObservationIgnored private var deviceID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var isSyncingFromDevice = false
    /// Settable mute elements: the main element if the device has one,
    /// otherwise per-channel mutes.
    @ObservationIgnored private var muteElements: [AudioObjectPropertyElement] = []
    @ObservationIgnored private var listenedAddresses: [AudioObjectPropertyAddress] = []
    @ObservationIgnored private var deviceListener: AudioObjectPropertyListenerBlock?

    private static let volumeAddress = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)

    private static var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func outputAddress(
        _ selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    init() {
        attachToDefaultDevice()
        // Re-attach when the default output device changes (e.g. headphones plugged in).
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &Self.defaultDeviceAddress,
            .main
        ) { [weak self] _, _ in
            self?.attachToDefaultDevice()
        }
    }

    // MARK: - Device Plumbing

    private func attachToDefaultDevice() {
        detachFromDevice()

        var newID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &Self.defaultDeviceAddress,
            0, nil, &size, &newID
        )
        guard status == noErr, newID != AudioObjectID(kAudioObjectUnknown) else {
            isAvailable = false
            return
        }

        deviceID = newID
        var volumeAddress = Self.volumeAddress
        isAvailable = AudioObjectHasProperty(deviceID, &volumeAddress)
        guard isAvailable else { return }

        let candidates = [kAudioObjectPropertyElementMain, 1, 2].filter { element in
            var address = Self.outputAddress(kAudioDevicePropertyMute, element: element)
            var settable: DarwinBoolean = false
            return AudioObjectHasProperty(deviceID, &address)
                && AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr
                && settable.boolValue
        }
        muteElements = candidates.contains(kAudioObjectPropertyElementMain)
            ? [kAudioObjectPropertyElementMain]
            : candidates

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.syncFromDevice()
        }
        deviceListener = block
        listenedAddresses = [Self.volumeAddress]
            + muteElements.map { Self.outputAddress(kAudioDevicePropertyMute, element: $0) }
        for var address in listenedAddresses {
            AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
        }

        syncFromDevice()
    }

    private func detachFromDevice() {
        if let block = deviceListener, deviceID != AudioObjectID(kAudioObjectUnknown) {
            for var address in listenedAddresses {
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
            }
        }
        deviceListener = nil
        listenedAddresses = []
        muteElements = []
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    private func syncFromDevice() {
        var address = Self.volumeAddress
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return }
        isSyncingFromDevice = true
        volume = isDeviceMuted ? 0 : value
        isSyncingFromDevice = false
    }

    private var isDeviceMuted: Bool {
        !muteElements.isEmpty && muteElements.allSatisfy { element in
            var address = Self.outputAddress(kAudioDevicePropertyMute, element: element)
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr && muted != 0
        }
    }

    private func writeDevice(volume value: Float) {
        guard isAvailable, deviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        let shouldMute = value == 0
        // Set the level before unmuting so the old level never sounds.
        if shouldMute { setMute(true) }
        var address = Self.volumeAddress
        var v = Float32(value)
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        if !shouldMute { setMute(false) }
    }

    private func setMute(_ muted: Bool) {
        guard !muteElements.isEmpty, isDeviceMuted != muted else { return }
        for element in muteElements {
            var address = Self.outputAddress(kAudioDevicePropertyMute, element: element)
            var value: UInt32 = muted ? 1 : 0
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        }
    }
}
