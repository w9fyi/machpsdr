import Testing
import Foundation
import FT8Kit
@testable import machpsdr

@MainActor
@Suite struct FT8ControllerTests {

    private func makeController() -> FT8Controller {
        FT8Controller(session: RadioSession())
    }

    @Test func dialFrequencyFollowsBandAndMode() {
        let c = makeController()
        c.useCustomFrequency = false
        c.setMode(.ft8)
        c.setBand("20m")
        #expect(c.dialFrequencyHz == 14_074_000)
        c.setBand("40m")
        #expect(c.dialFrequencyHz == 7_074_000)
        c.setMode(.ft4)
        #expect(c.dialFrequencyHz == 7_047_500)
    }

    @Test func customFrequencyOverridesBandPlan() {
        let c = makeController()
        c.setMode(.ft8)
        c.setBand("20m")
        c.customFrequencyHz = 14_071_000
        c.useCustomFrequency = true
        #expect(c.dialFrequencyHz == 14_071_000)
        c.useCustomFrequency = false
        #expect(c.dialFrequencyHz == 14_074_000)
    }

    @Test func switchingToFT4LeavesValidBand() {
        let c = makeController()
        c.setMode(.ft8)
        c.setBand("160m")   // FT4 has no 160 m channel
        c.setMode(.ft4)
        #expect(c.availableBandIDs.contains(c.selectedBandID))
        #expect(FTxBandPlan.primaryChannel(bandID: c.selectedBandID, mode: .ft4) != nil)
    }

    @Test func cannotStartWithoutStationInfoOrConnection() {
        let c = makeController()
        c.station.info = StationInfo()   // no callsign/grid
        #expect(c.canStart == false)
        c.start()
        #expect(c.isRunning == false)
    }

    @Test func settingsRoundTripThroughDefaults() {
        let c = makeController()
        c.txOffsetHz = 1_720
        c.autoAnswerCQs = true
        c.answerPolicy = FT8AutoAnswerPolicy(order: .closestFirst,
                                             continents: [.europe], skipWorked: false)
        let reloaded = makeController()
        #expect(reloaded.txOffsetHz == 1_720)
        #expect(reloaded.autoAnswerCQs == true)
        #expect(reloaded.answerPolicy.order == .closestFirst)
        #expect(reloaded.answerPolicy.continents == [.europe])
        #expect(reloaded.answerPolicy.skipWorked == false)
    }

    @Test func txDisableClearsTransmitState() {
        let c = makeController()
        c.txEnabled = false
        #expect(c.currentTxText == nil)
        #expect(c.isTransmitting == false)
        #expect(c.engine.phase == .idle)
    }
}
