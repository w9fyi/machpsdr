import Testing
@testable import machpsdr

/// Tests for the pan-law helper. `panWeights` is a pure static function, so no
/// audio engine is constructed here. Center is full in both channels (matching
/// the legacy mono-duplicated behavior); hard pan zeroes the opposite side.
@Suite struct SliceAudioMixerTests {

    @Test func centerIsFullInBothChannels() {
        let w = SliceAudioMixer.panWeights(0)
        #expect(w.left == 1)
        #expect(w.right == 1)
    }

    @Test func hardLeft() {
        let w = SliceAudioMixer.panWeights(-1)
        #expect(w.left == 1)
        #expect(w.right == 0)
    }

    @Test func hardRight() {
        let w = SliceAudioMixer.panWeights(1)
        #expect(w.left == 0)
        #expect(w.right == 1)
    }

    @Test func partialLeft() {
        let w = SliceAudioMixer.panWeights(-0.5)
        #expect(w.left == 1)       // opposite side stays full until hard pan
        #expect(w.right == 0.5)
    }

    @Test func partialRight() {
        let w = SliceAudioMixer.panWeights(0.5)
        #expect(w.left == 0.5)
        #expect(w.right == 1)
    }

    @Test func clampsBeyondRange() {
        let over = SliceAudioMixer.panWeights(2)
        #expect(over.left == 0 && over.right == 1)   // same as +1
        let under = SliceAudioMixer.panWeights(-2)
        #expect(under.left == 1 && under.right == 0)  // same as −1
    }
}
