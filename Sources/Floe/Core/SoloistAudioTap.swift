import AudioToolbox
import CFloeCore
import CoreAudio
import Foundation
import os

/// Taps Spotify Soloist's Core Audio output via macOS's native process tap
/// (`CATapDescription` + `AudioHardwareCreateProcessTap`) and pushes stereo
/// float32 PCM into Tint's existing lock-free `AnalysisTap` ring.
///
/// Only runs while `VisualizationModel` is active (playing, visible, effects on);
/// stops completely when paused or hidden so idle CPU stays at 0%.
@MainActor
final class SoloistAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var activePID: pid_t?
    private let log = Logger(subsystem: "com.antonchurchyn.floe", category: "soloist-tap")

    deinit {
        let tap = tapID, agg = aggregateID, proc = ioProcID
        Self.teardown(tapID: tap, aggregateID: agg, ioProcID: proc)
    }

    func start(pid: pid_t) {
        if activePID == pid, ioProcID != nil { return }
        stop()
        guard let processObject = Self.processObjectID(for: pid) else {
            log.notice("No Core Audio process object yet for soloist pid \(pid)")
            return
        }
        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Tint Soloist Analysis Tap"

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTap)
        guard tapStatus == noErr, newTap != AudioObjectID(kAudioObjectUnknown) else {
            log.notice("Process tap unavailable (OSStatus \(tapStatus)); visualizer will stay quiet until Audio Capture permission is granted.")
            return
        }

        guard let tapUID = Self.tapUID(for: newTap) else {
            _ = AudioHardwareDestroyProcessTap(newTap)
            return
        }

        let aggregateUID = "com.antonchurchyn.floe.soloist-tap.\(UUID().uuidString)"
        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tint Soloist Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &newAggregate)
        guard aggStatus == noErr, newAggregate != AudioObjectID(kAudioObjectUnknown) else {
            log.error("Failed to create aggregate tap device (OSStatus \(aggStatus))")
            _ = AudioHardwareDestroyProcessTap(newTap)
            return
        }

        let channels = Self.inputChannelCount(of: newAggregate)
        let interleaved = Self.isInputInterleaved(of: newAggregate)
        var newProc: AudioDeviceIOProcID?
        let procStatus = Self.installIOProc(on: newAggregate, channels: channels, interleaved: interleaved, outID: &newProc)
        guard procStatus == noErr, let newProc else {
            log.error("Failed to install tap IOProc (OSStatus \(procStatus))")
            Self.teardown(tapID: newTap, aggregateID: newAggregate, ioProcID: nil)
            return
        }

        let startStatus = AudioDeviceStart(newAggregate, newProc)
        guard startStatus == noErr else {
            log.error("Failed to start tap device (OSStatus \(startStatus))")
            Self.teardown(tapID: newTap, aggregateID: newAggregate, ioProcID: newProc)
            return
        }

        tapID = newTap
        aggregateID = newAggregate
        ioProcID = newProc
        activePID = pid
    }

    func stop() {
        Self.teardown(tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID)
        tapID = AudioObjectID(kAudioObjectUnknown)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        ioProcID = nil
        activePID = nil
    }

    // MARK: - Nonisolated Core Audio helpers

    private nonisolated static func teardown(tapID: AudioObjectID, aggregateID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                _ = AudioDeviceStop(aggregateID, ioProcID)
                _ = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyProcessTap(tapID)
        }
    }

    /// Built outside `@MainActor`: Core Audio invokes the IOProc block on its
    /// real-time audio thread, where main-actor isolation checks would trap.
    private nonisolated static func installIOProc(
        on deviceID: AudioObjectID,
        channels: Int,
        interleaved: Bool,
        outID: inout AudioDeviceIOProcID?
    ) -> OSStatus {
        let scratch = TapScratch()
        return AudioDeviceCreateIOProcIDWithBlock(&outID, deviceID, nil) { _, inInputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard !buffers.isEmpty else { return }
            if !interleaved, buffers.count >= 2,
               let leftPtr = buffers[0].mData?.assumingMemoryBound(to: Float.self),
               let rightPtr = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
                if frames > 0 { floe_push_analysis(leftPtr, rightPtr, UInt32(frames)) }
                return
            }
            let buf = buffers[0]
            let ch = max(1, Int(buf.mNumberChannels > 0 ? buf.mNumberChannels : UInt32(channels)))
            let totalFloats = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let frames = min(totalFloats / ch, TapScratch.capacity)
            guard frames > 0, let src = buf.mData?.assumingMemoryBound(to: Float.self) else { return }
            if ch == 1 {
                floe_push_analysis(src, src, UInt32(frames))
            } else {
                let l = scratch.left, r = scratch.right
                for i in 0..<frames {
                    l[i] = src[i * ch]
                    r[i] = src[i * ch + 1]
                }
                floe_push_analysis(l, r, UInt32(frames))
            }
        }
    }

    private nonisolated static func processObjectID(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidValue,
            &size,
            &objectID
        )
        guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return objectID
    }

    private nonisolated static func tapUID(for tapID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &uid)
        guard status == noErr, let cf = uid?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private nonisolated static func inputChannelCount(of deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var desc = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &desc) == noErr,
              desc.mChannelsPerFrame > 0 else { return 2 }
        return Int(desc.mChannelsPerFrame)
    }

    private nonisolated static func isInputInterleaved(of deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var desc = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &desc) == noErr else { return true }
        return (desc.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
    }
}

/// Pre-allocated planar buffers for deinterleaving inside the Core Audio IOProc
/// without allocating on the real-time thread.
private final class TapScratch: @unchecked Sendable {
    static let capacity = 4096
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>

    init() {
        left = .allocate(capacity: Self.capacity)
        right = .allocate(capacity: Self.capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }
}
