import Foundation
import LogoLightCore

@MainActor
func panelStateTests(_ t: TestHarness) {
    print("\nMenu panel")

    func status(_ setting: LogoIllumination?, isSupported: Bool = true) -> LogoStatus {
        LogoStatus(isSupported: isSupported, setting: setting, source: .daemon, isLit: setting == .on, outputLevel: 0.2)
    }

    t.test("with the logo on, the brightness and effects can be changed") {
        let state = PanelState(status: status(.on), canControlDirectly: true, effect: .pulse, brightness: 0.4)
        t.expect(state.isOn)
        t.expect(state.showsAdjustments)
        t.expect(state.canAdjust)
        t.expectEqual(state.effect, .pulse)
        t.expectEqual(state.brightness, 0.4)
        t.expectEqual(state.symbolName, "lightbulb.fill")
    }

    t.test("with the logo off, they're greyed out but keep the chosen effect and brightness") {
        let state = PanelState(status: status(.off), canControlDirectly: true, effect: .breathe, brightness: 0.3)
        t.expect(!state.isOn)
        t.expect(state.showsAdjustments, "still shown")
        t.expect(!state.canAdjust, "greyed out")
        t.expectEqual(state.effect, .breathe)
        t.expectEqual(state.brightness, 0.3)
        t.expectEqual(state.symbolName, "lightbulb.slash")
    }

    t.test("an unknown setting counts as on") {
        let state = PanelState(status: status(nil), canControlDirectly: true, effect: .none, brightness: 1)
        t.expect(state.isOn)
        t.expect(state.canAdjust)
        t.expectEqual(state.symbolName, "lightbulb")
    }

    t.test("without direct control, the brightness and effects are hidden") {
        let state = PanelState(status: status(.on), canControlDirectly: false, effect: .heartbeat, brightness: 0.5)
        t.expect(state.isOn)
        t.expect(!state.showsAdjustments)
        t.expect(!state.canAdjust)
    }

    t.test("while a change is under way, the brightness and effects are greyed out") {
        let state = PanelState(status: status(.on), canControlDirectly: true, effect: .none, brightness: 1, isBusy: true)
        t.expect(!state.canAdjust)
    }

    t.test("a Mac without the logo says why, with the logo off and nothing to adjust") {
        let state = PanelState(status: .unsupported, canControlDirectly: true, effect: .pulse, brightness: 1)
        t.expect(!state.isSupported)
        t.expect(!state.isOn)
        t.expect(!state.showsAdjustments)
        t.expectEqual(state.message, "Needs a MacBook Pro with PROLED XDR Display")
        t.expectEqual(state.symbolName, "lightbulb.slash")
        t.expectEqual(state.symbolDescription, "No illuminated logo on this Mac")
    }

    t.test("there's no text in the panel on a Mac with the logo") {
        for setting in [LogoIllumination.on, .off, nil] {
            for direct in [true, false] {
                let state = PanelState(status: status(setting), canControlDirectly: direct, effect: .none, brightness: 1)
                t.expectEqual(state.message, nil)
            }
        }
    }

    t.test("states built from the same inputs are equal, and differ when an input does") {
        let a = PanelState(status: status(.on), canControlDirectly: true, effect: .none, brightness: 0.5)
        t.expectEqual(a, PanelState(status: status(.on), canControlDirectly: true, effect: .none, brightness: 0.5))
        t.expect(a != PanelState(status: status(.on), canControlDirectly: true, effect: .none, brightness: 0.6))
        t.expect(a != PanelState(status: status(.off), canControlDirectly: true, effect: .none, brightness: 0.5))
    }
}
