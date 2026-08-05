// SpeechAudioGeneratorTests.swift — Always-on pure tests for TTS helpers +
// soft/muffled/noise conditions (no model required).

import Testing
import Foundation

@Suite("SpeechAudioGenerator conditions")
struct SpeechAudioGeneratorTests {

    @Test("soften reduces peak amplitude")
    func softenReducesPeak() {
        let loud = [Float](repeating: 0.8, count: 100) + [Float](repeating: -0.8, count: 100)
        let soft = SpeechAudioGenerator.soften(loud, gain: 0.15)
        #expect(SpeechAudioGenerator.peakAmplitude(soft) < SpeechAudioGenerator.peakAmplitude(loud) * 0.2)
        #expect(abs(SpeechAudioGenerator.peakAmplitude(soft) - 0.8 * 0.15) < 1e-5)
    }

    @Test("muffle damps high-frequency energy (impulse response)")
    func muffleDampsImpulse() {
        var impulse = [Float](repeating: 0, count: 64)
        impulse[0] = 1
        let muff = SpeechAudioGenerator.muffle(impulse, alpha: 0.9)
        // Low-pass: energy spreads; sample 0 smaller, later samples non-zero
        #expect(muff[0] < 1)
        #expect(muff[1] > 0)
        let late = muff.suffix(10).map { abs($0) }.reduce(0, +)
        #expect(late > 0, "muffle should leave a tail")
    }

    @Test("addNoise increases energy at low SNR")
    func noiseRaisesEnergy() {
        let clean = [Float](repeating: 0.1, count: 1000)
        let noisy = SpeechAudioGenerator.addNoise(to: clean, snrDB: 5, seed: 1)
        let cleanP = clean.map { $0 * $0 }.reduce(0, +)
        let noisyP = noisy.map { $0 * $0 }.reduce(0, +)
        #expect(noisyP > cleanP)
    }

    @Test("addRoomNoise is deterministic for seed")
    func roomNoiseDeterministic() {
        let clean = [Float](repeating: 0.2, count: 200)
        let a = SpeechAudioGenerator.addRoomNoise(to: clean, snrDB: 12, seed: 42)
        let b = SpeechAudioGenerator.addRoomNoise(to: clean, snrDB: 12, seed: 42)
        #expect(a == b)
        let c = SpeechAudioGenerator.addRoomNoise(to: clean, snrDB: 12, seed: 99)
        #expect(a != c)
    }

    @Test("VoiceCondition.harshDesk changes signal vs clean")
    func harshDeskDiffers() {
        let clean = (0..<500).map { i -> Float in sin(Float(i) * 0.1) * 0.5 }
        let harsh = SpeechAudioGenerator.VoiceCondition.harshDesk.apply(to: clean)
        #expect(harsh.count == clean.count)
        #expect(SpeechAudioGenerator.peakAmplitude(harsh) < SpeechAudioGenerator.peakAmplitude(clean))
        let diff = zip(clean, harsh).map { abs($0 - $1) }.reduce(0, +)
        #expect(diff > 0.1)
    }

    @Test("all VoiceCondition cases apply without crash")
    func allConditionsApply() {
        let s = [Float](repeating: 0.3, count: 100)
        for c in SpeechAudioGenerator.VoiceCondition.allCases {
            let out = c.apply(to: s)
            #expect(out.count == s.count, "\(c.label) length")
        }
    }

    @Test("withTrailingSilence lengthens")
    func trailingSilence() {
        let s = SpeechAudioGenerator.silence(seconds: 0.1)
        let pad = SpeechAudioGenerator.withTrailingSilence(s, seconds: 0.5)
        #expect(pad.count > s.count)
        #expect(pad.count == s.count + Int(0.5 * SpeechAudioGenerator.sampleRate))
    }
}
