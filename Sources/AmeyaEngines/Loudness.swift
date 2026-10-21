import Accelerate
import Foundation

/// Integrated loudness (ITU-R BS.1770-4 / EBU R128) and true peak, measured over float PCM in
/// chunks so an hour-long file never has to sit in memory.
///
/// K-weighting is the standard two-stage filter (a high shelf, then a high pass), derived for any
/// sample rate from its analogue prototype as libebur128 does. Energy is summed in 400 ms blocks
/// overlapping by 75 %, then gated at −70 LUFS and at 10 LU below the ungated mean. True peak uses
/// the 4× polyphase interpolator from BS.1770-4 Annex 2. The filtering runs on Accelerate.
final class LoudnessMeter {
    private let channels: Int
    private var filters: [KWeighting]
    private var truePeak: [TruePeakDetector]
    /// Samples per 100 ms step; four steps make one 400 ms block.
    private let step: Int
    private var stepSum = 0.0
    private var stepCount = 0
    private var recentSteps: [Double] = []
    private(set) var blocks: [Double] = []
    private(set) var peak: Float = 0

    init(sampleRate: Double, channels: Int) {
        self.channels = max(channels, 1)
        filters = (0..<max(channels, 1)).map { _ in KWeighting(sampleRate: sampleRate) }
        truePeak = (0..<max(channels, 1)).map { _ in TruePeakDetector() }
        step = max(1, Int((sampleRate / 10).rounded()))
    }

    /// Adds the next samples, one array per channel, all the same length.
    func add(_ samples: [[Float]]) {
        guard let frames = samples.first?.count, frames > 0 else { return }
        var power = [Double](repeating: 0, count: frames)
        for channel in 0..<min(channels, samples.count) {
            peak = max(peak, truePeak[channel].process(samples[channel]))
            let filtered = filters[channel].filter(samples[channel])
            power = vDSP.add(power, vDSP.square(filtered))
        }
        var offset = 0
        while offset < frames {
            let take = min(step - stepCount, frames - offset)
            stepSum += vDSP.sum(power[offset..<(offset + take)])
            stepCount += take
            offset += take
            if stepCount == step {
                recentSteps.append(stepSum / Double(step))
                if recentSteps.count > 4 { recentSteps.removeFirst() }
                if recentSteps.count == 4 { blocks.append(recentSteps.reduce(0, +) / 4) }
                stepSum = 0
                stepCount = 0
            }
        }
    }

    /// Gated integrated loudness in LUFS, or `nil` for silence or sound shorter than 400 ms.
    var integratedLoudness: Double? { Self.integrated(blocks) }

    /// True peak in dBTP (−∞ for silence).
    var truePeakDB: Double { 20 * log10(Double(max(peak, 1e-12))) }

    static func loudness(ofPower power: Double) -> Double { -0.691 + 10 * log10(max(power, 1e-20)) }

    static func integrated(_ blocks: [Double]) -> Double? {
        let absolute = blocks.filter { loudness(ofPower: $0) > -70 }
        guard !absolute.isEmpty else { return nil }
        let relativeGate = loudness(ofPower: absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { loudness(ofPower: $0) > relativeGate }
        guard !gated.isEmpty else { return nil }
        return loudness(ofPower: gated.reduce(0, +) / Double(gated.count))
    }
}

/// The BS.1770 K-weighting filter for one channel: a +4 dB high shelf followed by a high pass
/// (RLB), as two biquads in double precision (vDSP_deq22D), carrying state between chunks.
struct KWeighting {
    private var shelf: Biquad
    private var highPass: Biquad

    init(sampleRate: Double) {
        var f0 = 1681.974450955533
        let gain = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(Double.pi * f0 / sampleRate)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        shelf = Biquad([(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
                        2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0])
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(Double.pi * f0 / sampleRate)
        a0 = 1 + k / q + k * k
        highPass = Biquad([1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0])
    }

    mutating func filter(_ samples: [Float]) -> [Double] {
        highPass.filter(shelf.filter(vDSP.floatToDouble(samples)))
    }
}

/// One biquad, y = b0·x + b1·x₋₁ + b2·x₋₂ − a1·y₋₁ − a2·y₋₂.
struct Biquad {
    /// b0, b1, b2, a1, a2.
    let coefficients: [Double]
    private var inputHistory: [Double] = [0, 0]
    private var outputHistory: [Double] = [0, 0]

    init(_ coefficients: [Double]) { self.coefficients = coefficients }

    mutating func filter(_ samples: [Double]) -> [Double] {
        let count = samples.count
        guard count > 0 else { return [] }
        let input = inputHistory + samples
        var output = outputHistory + [Double](repeating: 0, count: count)
        vDSP_deq22D(input, 1, coefficients, &output, 1, vDSP_Length(count))
        inputHistory = Array(input.suffix(2))
        outputHistory = Array(output.suffix(2))
        return Array(output.dropFirst(2))
    }
}

/// Finds the true (inter-sample) peak of one channel with the BS.1770-4 Annex 2 interpolator:
/// 4× oversampling through a 48-tap polyphase FIR (12 taps per phase).
struct TruePeakDetector {
    static let phases: [[Float]] = [
        [0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
         0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500],
        [-0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
         0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375],
        [-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
         0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875],
        [-0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
         0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750],
    ]
    static let taps = 12
    /// Reversed, so vDSP_conv's correlation applies phase[0] to the newest sample.
    private static let reversed = phases.map { Array($0.reversed()) }

    /// The 11 samples before the next chunk.
    private var history = [Float](repeating: 0, count: TruePeakDetector.taps - 1)

    /// For each new sample, the largest absolute value among it and the four interpolated points
    /// just before it.
    mutating func peaks(_ samples: [Float]) -> [Float] {
        let count = samples.count
        guard count > 0 else { return [] }
        let extended = history + samples
        var result = vDSP.absolute(samples)
        var interpolated = [Float](repeating: 0, count: count)
        for phase in Self.reversed {
            vDSP_conv(extended, 1, phase, 1, &interpolated, 1, vDSP_Length(count), vDSP_Length(Self.taps))
            result = vDSP.maximum(result, vDSP.absolute(interpolated))
        }
        history = Array(extended.suffix(Self.taps - 1))
        return result
    }

    /// The largest true peak among these samples.
    mutating func process(_ samples: [Float]) -> Float {
        samples.isEmpty ? 0 : vDSP.maximum(peaks(samples))
    }
}

/// A look-ahead peak limiter that keeps the true peak under a ceiling with smooth gain changes.
///
/// For every sample it works out the gain that would keep that point (and the interpolated points
/// around it) under the ceiling, takes the minimum over a short window, lets it recover slowly, and
/// averages it over the same window. Because the average of minimums never exceeds the gain needed
/// at the peak, nothing goes over; because it is an average, the gain never jumps. The output is
/// delayed by the window, and `finish` returns the held-back tail.
final class PeakLimiter {
    private let ceiling: Float
    private let window: Int
    private let release: Float
    private let channels: Int
    private var detectors: [TruePeakDetector]
    /// Delayed audio, one ring of `window` samples per channel, sharing `slot`.
    private let delay: UnsafeMutablePointer<Float>
    /// The recovered gains being averaged (a ring of `window`).
    private let recent: UnsafeMutablePointer<Float>
    private var recentSum: Double
    private var slot = 0
    /// Monotonic deque for the sliding minimum: a ring of (value, index) pairs.
    private let dequeValues: UnsafeMutablePointer<Float>
    private let dequeIndices: UnsafeMutablePointer<Int>
    private let dequeCapacity: Int
    private var dequeHead = 0
    private var dequeCount = 0
    private var position = 0
    private var released: Float = 1
    private var written = 0
    private(set) var engaged = false

    /// - Parameters:
    ///   - ceilingDB: the highest allowed true peak, in dBTP.
    ///   - lookahead: seconds of look-ahead; also the attack time.
    init(ceilingDB: Double, sampleRate: Double, channels: Int, lookahead: Double = 0.005, releaseSeconds: Double = 0.06) {
        ceiling = Float(pow(10, ceilingDB / 20))
        // Covers the interpolator's 12-tap reach as well as the attack.
        let window = max(16, Int(sampleRate * lookahead)) + TruePeakDetector.taps
        self.window = window
        release = Float(exp(-1 / (releaseSeconds * sampleRate)))
        self.channels = max(channels, 1)
        detectors = (0..<max(channels, 1)).map { _ in TruePeakDetector() }
        delay = .allocate(capacity: window * max(channels, 1))
        delay.initialize(repeating: 0, count: window * max(channels, 1))
        recent = .allocate(capacity: window)
        recent.initialize(repeating: 1, count: window)
        recentSum = Double(window)
        // One longer than the delay, so the minimum covers the delayed sample.
        dequeCapacity = window + 2
        dequeValues = .allocate(capacity: window + 2)
        dequeIndices = .allocate(capacity: window + 2)
    }

    deinit {
        delay.deallocate()
        recent.deallocate()
        dequeValues.deallocate()
        dequeIndices.deallocate()
    }

    func process(_ input: [[Float]]) -> [[Float]] {
        guard let frames = input.first?.count, frames > 0 else { return input }
        var peak = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            peak = vDSP.maximum(peak, detectors[channel].peaks(input[min(channel, input.count - 1)]))
        }
        // ceiling ÷ max(peak, ceiling): 1 when under, less when over.
        let needed = vDSP.divide(ceiling, vDSP.clip(peak, to: ceiling...Float.greatestFiniteMagnitude))
        if vDSP.minimum(needed) < 1 { engaged = true }

        var gains = [Float](repeating: 1, count: frames)
        let startSlot = slot
        needed.withUnsafeBufferPointer { need in
            gains.withUnsafeMutableBufferPointer { gain in
                let span = window + 1
                for frame in 0..<frames {
                    // Sliding minimum over the last `span` needed gains.
                    let value = need[frame]
                    while dequeCount > 0, dequeValues[(dequeHead + dequeCount - 1) % dequeCapacity] >= value { dequeCount -= 1 }
                    let tail = (dequeHead + dequeCount) % dequeCapacity
                    dequeValues[tail] = value
                    dequeIndices[tail] = position
                    dequeCount += 1
                    while dequeIndices[dequeHead] <= position - span {
                        dequeHead = (dequeHead + 1) % dequeCapacity
                        dequeCount -= 1
                    }
                    position += 1
                    // Recover slowly, never above the minimum.
                    released = min(dequeValues[dequeHead], 1 - (1 - released) * release)
                    recentSum += Double(released - recent[slot])
                    recent[slot] = released
                    slot = (slot + 1) % window
                    gain[frame] = min(1, Float(recentSum / Double(window)))
                }
            }
        }

        var output: [[Float]] = []
        for channel in 0..<channels {
            let ring = delay + channel * window
            let source = input[min(channel, input.count - 1)]
            var out = [Float](repeating: 0, count: frames)
            source.withUnsafeBufferPointer { samples in
                gains.withUnsafeBufferPointer { gain in
                    out.withUnsafeMutableBufferPointer { result in
                        var index = startSlot
                        for frame in 0..<frames {
                            result[frame] = ring[index] * gain[frame]
                            ring[index] = samples[frame]
                            index += 1
                            if index == window { index = 0 }
                        }
                    }
                }
            }
            output.append(out)
        }
        // The first `window` outputs are the empty delay line; drop them once.
        if written < window {
            let drop = min(window - written, frames)
            written += drop
            return output.map { Array($0.dropFirst(drop)) }
        }
        return output
    }

    /// Pushes silence through to release the delayed tail.
    func finish() -> [[Float]] {
        let pending = min(written, window)
        guard pending > 0 else { return [] }
        return process([[Float]](repeating: [Float](repeating: 0, count: pending), count: channels))
    }
}
