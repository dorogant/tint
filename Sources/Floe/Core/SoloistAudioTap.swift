import Accelerate
import AudioToolbox
import CFloeCore
import CoreAudio
import Foundation
import Synchronization
import os

/// Taps Spotify Soloist's Core Audio output via macOS's native process tap
/// (`CATapDescription` + `AudioHardwareCreateProcessTap`) and pushes stereo
/// float32 PCM into Tint's existing lock-free `AnalysisTap` ring.
///
/// Given a ring to play from, it also takes the sound over for the equalizer:
/// Soloist's own output is muted for as long as the tap is read, and every
/// frame goes into the ring for `EqualizerOutput` to play. The mute ends with
/// the tap, so if Tint quits or crashes, Soloist is simply heard again.
///
/// Only runs while something needs it (the visuals: playing, visible, effects
/// on; the equalizer: playing); stops completely otherwise so idle CPU stays at 0%.
@MainActor
final class SoloistAudioTap {
    enum Start {
        case started
        /// Soloist hasn't opened an audio device yet. It will have by the time it plays.
        case notReady
        case failed
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var activePID: pid_t?
    private var activeRing: AudioRing?
    /// The rate the tap delivers at: the rate of the device Soloist plays to.
    private(set) var sampleRate: Double = 0
    private let meter = TapMeter()
    /// Counts up with every delivery that wasn't silence. A tap without the
    /// System Audio Recording permission starts like any other and delivers
    /// only silence, so this is the one way to tell that it hears Soloist.
    var soundingDeliveries: Int { meter.sounding.load(ordering: .relaxed) }
    private let log = Logger(subsystem: "com.antonchurchyn.floe", category: "soloist-tap")

    deinit {
        let tap = tapID, agg = aggregateID, proc = ioProcID
        Self.teardown(tapID: tap, aggregateID: agg, ioProcID: proc)
    }

    /// With `takingOver`, Soloist is muted and its sound goes into that ring.
    @discardableResult
    func start(pid: pid_t, takingOver ring: AudioRing? = nil) -> Start {
        if activePID == pid, ioProcID != nil, activeRing === ring { return .started }
        stop()
        guard let processObject = Self.processObjectID(for: pid) else {
            log.notice("No Core Audio process object yet for soloist pid \(pid)")
            return .notReady
        }
        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.muteBehavior = ring == nil ? .unmuted : .mutedWhenTapped
        description.isPrivate = true
        description.name = "Tint Soloist Analysis Tap"

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTap)
        guard tapStatus == noErr, newTap != AudioObjectID(kAudioObjectUnknown) else {
            log.notice("Process tap unavailable (OSStatus \(tapStatus)); visualizer will stay quiet until Audio Capture permission is granted.")
            return .failed
        }

        guard let tapUID = Self.tapUID(for: newTap) else {
            _ = AudioHardwareDestroyProcessTap(newTap)
            return .failed
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
            return .failed
        }

        let format = Self.inputFormat(of: newAggregate)
        // Without a rate there's nothing to play the sound back at, so it can't be taken over.
        if ring != nil, (format?.mSampleRate ?? 0) <= 0 {
            log.error("The tap reports no sample rate; leaving Soloist's sound alone")
            Self.teardown(tapID: newTap, aggregateID: newAggregate, ioProcID: nil)
            return .failed
        }
        let channels = Int(format?.mChannelsPerFrame ?? 2)
        let interleaved = ((format?.mFormatFlags ?? 0) & kAudioFormatFlagIsNonInterleaved) == 0
        var newProc: AudioDeviceIOProcID?
        ring?.reset()
        let procStatus = Self.installIOProc(on: newAggregate, channels: channels, interleaved: interleaved, ring: ring, meter: meter, outID: &newProc)
        guard procStatus == noErr, let newProc else {
            log.error("Failed to install tap IOProc (OSStatus \(procStatus))")
            Self.teardown(tapID: newTap, aggregateID: newAggregate, ioProcID: nil)
            return .failed
        }

        let startStatus = AudioDeviceStart(newAggregate, newProc)
        guard startStatus == noErr else {
            log.error("Failed to start tap device (OSStatus \(startStatus))")
            Self.teardown(tapID: newTap, aggregateID: newAggregate, ioProcID: newProc)
            return .failed
        }

        tapID = newTap
        aggregateID = newAggregate
        ioProcID = newProc
        activePID = pid
        activeRing = ring
        sampleRate = format?.mSampleRate ?? 0
        return .started
    }

    func stop() {
        Self.teardown(tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID)
        tapID = AudioObjectID(kAudioObjectUnknown)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        ioProcID = nil
        activePID = nil
        activeRing = nil
    }

    /// True while Soloist is muted and its sound goes through the ring.
    var isTakingOver: Bool { activeRing != nil && ioProcID != nil }

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
        ring: AudioRing?,
        meter: TapMeter,
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
                if frames > 0 { deliver(leftPtr, rightPtr, frames, to: ring, meter) }
                return
            }
            let buf = buffers[0]
            let ch = max(1, Int(buf.mNumberChannels > 0 ? buf.mNumberChannels : UInt32(channels)))
            let total = Int(buf.mDataByteSize) / MemoryLayout<Float>.size / ch
            guard total > 0, let src = buf.mData?.assumingMemoryBound(to: Float.self) else { return }
            if ch == 1 {
                deliver(src, src, total, to: ring, meter)
                return
            }
            // In pieces the scratch buffers hold: a long delivery cut short would
            // only cost the visuals a few frames, but it would be a hole in the sound.
            let l = scratch.left, r = scratch.right
            var done = 0
            while done < total {
                let frames = min(total - done, TapScratch.capacity)
                for i in 0..<frames {
                    l[i] = src[(done + i) * ch]
                    r[i] = src[(done + i) * ch + 1]
                }
                deliver(l, r, frames, to: ring, meter)
                done += frames
            }
        }
    }

    /// To the equalizer, if it has the sound, and to the visuals, which take
    /// it as it left Soloist, before the equalizer.
    private nonisolated static func deliver(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, _ frames: Int,
                                            to ring: AudioRing?, _ meter: TapMeter) {
        var peak: Float = 0
        vDSP_maxmgv(left, 1, &peak, vDSP_Length(frames))
        if peak <= 1e-5 { vDSP_maxmgv(right, 1, &peak, vDSP_Length(frames)) }
        if peak > 1e-5 { meter.sounding.add(1, ordering: .relaxed) }
        ring?.write(left: left, right: right, frames: frames)
        floe_push_analysis(left, right, UInt32(frames))
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

    private nonisolated static func inputFormat(of deviceID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var desc = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &desc) == noErr,
              desc.mChannelsPerFrame > 0 else { return nil }
        return desc
    }
}

private final class TapMeter: Sendable {
    let sounding = Atomic<Int>(0)
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
