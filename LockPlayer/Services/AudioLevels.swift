import Accelerate
import CoreAudio
import Foundation
import Observation

/// Niveaux du son réellement joué par le Mac (tap Core Audio, macOS 14.4+),
/// découpés en bandes de fréquences pour animer l'égaliseur.
@MainActor
@Observable
final class AudioLevels {
    nonisolated static let bandCount = 5

    /// 0…1 par bande, lissés.
    private(set) var bands = [Float](repeating: 0, count: bandCount)
    /// true quand on reçoit un vrai signal (permission accordée et son non nul).
    private(set) var isLive = false

    @ObservationIgnored private var tap: SystemAudioTap?
    @ObservationIgnored private var lastSignal = Date.distantPast
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private static let setupQueue = DispatchQueue(label: "LockPlayer.audio.setup")

    func start() {
        guard tap == nil else { return }
        generation += 1
        let current = generation
        let tap = SystemAudioTap { [weak self] raw in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(raw) }
            }
        }
        self.tap = tap
        // La création du tap peut bloquer tant que la demande d'autorisation est affichée :
        // jamais sur le fil principal, sinon toute l'interface se fige.
        Self.setupQueue.async {
            do {
                try tap.start()
            } catch {
                NSLog("LockPlayer: tap audio impossible: \(error)")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Arrêté entre-temps : on libère ce qui vient d'être créé.
                    if self.generation != current || self.tap !== tap { Self.setupQueue.async { tap.stop() } }
                }
            }
        }
    }

    func stop() {
        generation += 1
        if let tap { Self.setupQueue.async { tap.stop() } }
        tap = nil
        isLive = false
        bands = [Float](repeating: 0, count: Self.bandCount)
    }

    private func receive(_ raw: [Float]) {
        let now = Date()
        if raw.contains(where: { $0 > 0.02 }) { lastSignal = now }
        // Sans permission, macOS envoie du silence : on bascule alors sur l'animation de secours.
        isLive = now.timeIntervalSince(lastSignal) < 1.5

        var next = bands
        for i in 0..<Self.bandCount {
            let target = raw[i]
            // Montée rapide, descente douce : rendu « VU-mètre ».
            next[i] = target > next[i] ? next[i] + (target - next[i]) * 0.7 : next[i] + (target - next[i]) * 0.25
        }
        bands = next
    }
}

/// Tap global (tout le son du Mac) + device agrégé privé + analyse FFT.
final class SystemAudioTap {
    enum TapError: Error { case status(String, OSStatus) }

    private let onLevels: ([Float]) -> Void
    private let queue = DispatchQueue(label: "LockPlayer.audio", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    // Analyse
    private let fftSize = 1024
    private lazy var fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)!
    private lazy var window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
    private var samples: [Float] = []
    private var sampleRate: Double = 48_000
    private var peaks = [Float](repeating: 1e-6, count: AudioLevels.bandCount)
    private var lastEmit = Date.distantPast

    init(onLevels: @escaping ([Float]) -> Void) {
        self.onLevels = onLevels
    }

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "LockPlayer"

        try check("create tap", AudioHardwareCreateProcessTap(description, &tapID))

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr, format.mSampleRate > 0 {
            sampleRate = format.mSampleRate
        }
        let channels = max(1, Int(format.mChannelsPerFrame))
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LockPlayer Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check("create aggregate", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        try check("io proc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.process(input, channels: channels, interleaved: interleaved)
        })
        try check("start", AudioDeviceStart(aggregateID, procID))
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    // MARK: - Traitement (file audio)

    private func process(_ input: UnsafePointer<AudioBufferList>, channels: Int, interleaved: Bool) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData else { return }
        let floats = data.assumingMemoryBound(to: Float.self)
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size

        // Mono : moyenne des canaux (entrelacés) ou premier buffer.
        if interleaved && channels > 1 {
            let frames = count / channels
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += floats[f * channels + c] }
                samples.append(sum / Float(channels))
            }
        } else {
            samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
        }

        while samples.count >= fftSize {
            let chunk = Array(samples.prefix(fftSize))
            samples.removeFirst(fftSize / 2) // recouvrement 50 %
            analyze(chunk)
        }
    }

    private func analyze(_ chunk: [Float]) {
        let windowed = vDSP.multiply(chunk, window)
        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &magnitudes)
            }
        }

        // Bandes : graves → aigus.
        let edges: [Double] = [40, 150, 400, 1_200, 3_500, 11_000]
        let binWidth = sampleRate / Double(fftSize)
        var levels = [Float](repeating: 0, count: AudioLevels.bandCount)
        for b in 0..<AudioLevels.bandCount {
            let lo = max(1, Int(edges[b] / binWidth))
            let hi = min(half - 1, max(lo + 1, Int(edges[b + 1] / binWidth)))
            let energy = vDSP.mean(magnitudes[lo..<hi])
            // Normalisation adaptative : chaque bande se compare à son propre pic récent.
            peaks[b] = max(energy, peaks[b] * 0.995, 1e-7)
            let db = 10 * log10(max(energy, 1e-12) / peaks[b]) // ≤ 0
            levels[b] = energy < 1e-9 ? 0 : Float(max(0, 1 + db / 30))
        }

        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= 1.0 / 40 else { return }
        lastEmit = now
        onLevels(levels)
    }

    // MARK: - Utilitaires

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw TapError.status(step, status) }
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw TapError.status("default output", status) }

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw TapError.status("device uid", status) }
        return uid.takeRetainedValue() as String
    }
}
