import Foundation
import LogoLightCore

/// Stands in for the display drivers: the built-in display's pipe and one external pipe, dithering as
/// after a restart, and every write logged.
@MainActor
private final class FakePipes: DisplayPipes {
    var all = [DisplayPipe(id: 1, isExternal: false, dithers: true), DisplayPipe(id: 2, isExternal: true, dithers: true)]
    /// Every write made, in order.
    var writes: [(pipe: UInt64, dithers: Bool)] = []
    /// The drivers say yes and change nothing.
    var ignoresWrites = false

    func pipes() -> [DisplayPipe] { all }

    func setDithers(_ dithers: Bool, pipe id: UInt64) -> Bool {
        writes.append((id, dithers))
        guard let index = all.firstIndex(where: { $0.id == id }) else { return false }
        if !ignoresWrites { all[index].dithers = dithers }
        return true
    }

    var dithering: [Bool?] { all.map(\.dithers) }
}

@MainActor
func ditheringTests(_ t: TestHarness) {
    print("\nDisable Dithering")

    t.test("left on, nothing is written, so another tool's setting stands") {
        let pipes = FakePipes()
        pipes.all[0].dithers = false
        let dithering = DisplayDithering(hardware: pipes)
        dithering.start(disabled: false)
        dithering.reapply()
        dithering.restore()
        t.expect(pipes.writes.isEmpty, "wrote \(pipes.writes)")
        t.expectEqual(pipes.dithering, [false, true])
    }

    t.test("saved as off, it's turned off on every display at launch") {
        let pipes = FakePipes()
        let dithering = DisplayDithering(hardware: pipes)
        dithering.start(disabled: true)
        t.expect(dithering.isDisabled)
        t.expectEqual(pipes.dithering, [false, false])
    }

    t.test("the menu item turns it off and back on") {
        let pipes = FakePipes()
        let dithering = DisplayDithering(hardware: pipes)
        t.expect(dithering.setDisabled(true))
        t.expectEqual(pipes.dithering, [false, false])
        t.expect(dithering.setDisabled(false))
        t.expect(!dithering.isDisabled)
        t.expectEqual(pipes.dithering, [true, true])
    }

    t.test("it's turned off again only where it has come back on") {
        let pipes = FakePipes()
        let dithering = DisplayDithering(hardware: pipes)
        dithering.start(disabled: true)
        // A display was connected: its pipe dithers again.
        pipes.all[1].dithers = true
        pipes.writes = []
        dithering.reapply()
        t.expectEqual(pipes.dithering, [false, false])
        t.expectEqual(pipes.writes.map(\.pipe), [2])
        dithering.reapply()
        t.expectEqual(pipes.writes.count, 1)
    }

    t.test("quitting turns it back on, and keeps the choice") {
        let pipes = FakePipes()
        let dithering = DisplayDithering(hardware: pipes)
        dithering.start(disabled: true)
        dithering.restore()
        t.expectEqual(pipes.dithering, [true, true])
        t.expect(dithering.isDisabled)
    }

    t.test("a driver without the switch is left alone") {
        let pipes = FakePipes()
        pipes.all[1].dithers = nil
        let dithering = DisplayDithering(hardware: pipes)
        t.expect(dithering.isAvailable)
        t.expect(dithering.setDisabled(true))
        t.expectEqual(pipes.writes.map(\.pipe), [1])
        pipes.all[0].dithers = nil
        t.expect(!dithering.isAvailable)
    }

    t.test("a Mac without display pipes doesn't have it") {
        let pipes = FakePipes()
        pipes.all = []
        t.expect(!DisplayDithering(hardware: pipes).isAvailable)
    }

    t.test("a driver that doesn't take the change is reported") {
        let pipes = FakePipes()
        pipes.ignoresWrites = true
        let dithering = DisplayDithering(hardware: pipes)
        t.expect(!dithering.setDisabled(true), "the displays still dither")
    }

    t.test("reads this Mac's real display pipes") {
        let pipes = SystemDisplayPipes().pipes()
        guard pipes.contains(where: { $0.dithers != nil }) else { try t.skip("this Mac's displays have no dithering switch") }
        t.expectEqual(Set(pipes.map(\.id)).count, pipes.count)
        print("      this Mac: " + pipes.map { pipe in
            "\(pipe.isExternal ? "external" : "built-in") \(pipe.dithers.map { $0 ? "dithers" : "doesn't dither" } ?? "has no switch")"
        }.joined(separator: ", "))
    }
}
