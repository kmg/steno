import CoreAudio
import AVFoundation
import os

/// Captures system audio using Core Audio Taps (macOS 14.2+).
/// Uses a global stereo tap to capture all system audio output.
final class SystemAudioCapture: @unchecked Sendable {
    private let log = StenoLog.audio

    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?

    private(set) var isCapturing = false
    private(set) var captureFormat: AVAudioFormat?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var pendingRestart: DispatchWorkItem?
    private let restartQueue = DispatchQueue(label: "com.kmganesh.steno.sys-restart")

    var bufferHandler: (@Sendable (UnsafePointer<AudioBufferList>) -> Void)?

    init() {
        // Register the output-device-change listener ONCE per instance lifetime.
        // Re-registering on every start/restart cycle leaks listeners — Swift-to-ObjC
        // block bridging makes AudioObjectRemovePropertyListenerBlock unreliable
        // (the bridged block instance passed at register time can differ from the
        // stored block instance, so removal silently fails). v0.2.19 torture test
        // showed listener counts growing 3 → 4 → 5 → 6 with each device transition.
        // Fix: install once here, gate the body with isCapturing, remove in deinit.
        installOutputDeviceListener()
    }

    /// Start capturing all system audio.
    func start() throws {
        guard !isCapturing else { return }

        // 1. Create a global stereo tap (captures all system audio, excludes our own process)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var ownAudioObjectID: AudioObjectID = 0
        var pidSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var ownPIDValue = ownPID

        // Try to get our own audio object ID to exclude ourselves
        let excludeProcesses: [AudioObjectID]
        let translateStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &Self.translatePIDAddress,
            UInt32(MemoryLayout<pid_t>.size),
            &ownPIDValue,
            &pidSize,
            &ownAudioObjectID
        )
        if translateStatus == noErr {
            excludeProcesses = [ownAudioObjectID]
        } else {
            excludeProcesses = []
        }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeProcesses)
        description.name = "StenoSystemAudioTap"
        self.tapDescription = description

        // 2. Create the process tap
        var tapObjectID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapObjectID)
        guard tapStatus == noErr else {
            throw CaptureError.tapCreationFailed(tapStatus)
        }
        self.tapID = tapObjectID
        log.info("Process tap created: \(tapObjectID)")

        // 3. Create aggregate device with the tap
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "StenoAggregateDevice",
            kAudioAggregateDeviceUIDKey as String: "com.kmganesh.steno.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapUIDKey as String: description.uuid.uuidString
            ]]
        ]

        var aggregateID: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateID)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapObjectID)
            throw CaptureError.aggregateDeviceFailed(aggStatus)
        }
        self.aggregateDeviceID = aggregateID
        log.info("Aggregate device created: \(aggregateID)")

        // 4. Read the stream format
        var streamFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectGetPropertyData(aggregateID, &formatAddress, 0, nil, &formatSize, &streamFormat)
        captureFormat = AVAudioFormat(streamDescription: &streamFormat)
        log.info("Capture format: \(streamFormat.mSampleRate)Hz, \(streamFormat.mChannelsPerFrame)ch")

        // 5. Create IO proc for receiving audio
        // Capture handler directly — avoids accessing `self` on the IO thread
        let handler = bufferHandler
        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateID,
            nil
        ) { (
            _: UnsafePointer<AudioTimeStamp>,
            inputData: UnsafePointer<AudioBufferList>,
            _: UnsafePointer<AudioTimeStamp>,
            _: UnsafeMutablePointer<AudioBufferList>,
            _: UnsafePointer<AudioTimeStamp>
        ) in
            handler?(inputData)
        }

        guard ioStatus == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapObjectID)
            throw CaptureError.ioProcFailed(ioStatus)
        }
        self.ioProcID = procID

        // 6. Start
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapObjectID)
            throw CaptureError.startFailed(startStatus)
        }

        isCapturing = true
        log.info("System audio capture started")
        // Output-device-change listener is registered once in init() — see comment there.
    }

    func stop() {
        // Output-device-change listener is NOT removed here — it stays registered for
        // the instance lifetime (cleaned up in deinit). The listener body gates on
        // isCapturing so it only schedules a restart when actually recording.
        guard isCapturing else { return }

        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
        }

        ioProcID = nil
        aggregateDeviceID = 0
        tapID = 0
        tapDescription = nil
        isCapturing = false
        log.info("System audio capture stopped")
    }

    /// Recreate the tap when the output device changes. The global stereo tap
    /// may stop delivering audio or capture from the wrong device after a switch.
    func restart() {
        guard isCapturing, let handler = bufferHandler else { return }
        log.info("Restarting system audio capture after device change")
        stop()
        do {
            bufferHandler = handler
            try start()
        } catch {
            log.error("Failed to restart system audio capture: \(error)")
        }
    }

    // MARK: - Output device change listener

    private func installOutputDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Gate on isCapturing — when not recording, we still receive system
            // notifications but ignore them. This avoids noisy logs and prevents
            // useless restart attempts.
            guard self.isCapturing else { return }
            self.log.info("Default output device changed")
            self.restartQueue.async { [weak self] in
                guard let self else { return }
                self.pendingRestart?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.restart()
                }
                self.pendingRestart = work
                self.restartQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
        if status == noErr {
            deviceListenerBlock = block
        } else {
            log.warning("Failed to install output device listener: \(status)")
        }
    }

    private func removeOutputDeviceListener() {
        guard let block = deviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
        deviceListenerBlock = nil
    }

    deinit {
        stop()
        removeOutputDeviceListener()
    }

    // MARK: - Property addresses

    nonisolated(unsafe) private static var translatePIDAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    enum CaptureError: LocalizedError {
        case tapCreationFailed(OSStatus)
        case aggregateDeviceFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let s): return "Failed to create audio tap (status: \(s))"
            case .aggregateDeviceFailed(let s): return "Failed to create aggregate device (status: \(s))"
            case .ioProcFailed(let s): return "Failed to create IO proc (status: \(s))"
            case .startFailed(let s): return "Failed to start capture (status: \(s))"
            }
        }
    }
}
