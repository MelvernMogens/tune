import Foundation
import Testing
@testable import Kaset

@Suite("Song transition transport gate", .tags(.service))
@MainActor
struct SongTransitionTransportGateTests {
    @MainActor
    private final class Recorder {
        var events: [String] = []
        var commands: [SongTransitionCommand] = []
        var generation: UInt64 = 1
        /// Runs inside `perform`, after the fade starts and before it waits.
        var onFadeOut: (@MainActor () -> Void)?

        func record(_ command: SongTransitionCommand) {
            self.commands.append(command)
            switch command {
            case let .fadeOut(token, _, fadeIn):
                self.events.append("fadeOut(\(token),\(fadeIn))")
                self.onFadeOut?()
            case let .release(token, superseded):
                self.events.append(superseded ? "release(\(token),superseded)" : "release(\(token))")
            case let .fadeInOnPlay(milliseconds):
                self.events.append("fadeInOnPlay(\(milliseconds))")
            case .configure:
                self.events.append("configure")
            case .prepareOverlap, .armOverlap, .quickOverlap, .cancelOverlap:
                self.events.append("overlap")
            }
        }
    }

    private func makeGate(_ recorder: Recorder, fade: Duration = .milliseconds(40)) -> SongTransitionTransportGate {
        SongTransitionTransportGate(fadeDuration: fade) { recorder.record($0) }
    }

    /// Waits (bounded) until the gate's first fade is in flight; parallel suites can delay task start.
    private func waitUntilFading(_ gate: SongTransitionTransportGate) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !gate.isFading, ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test("With fades off the command runs at once and nothing is sent")
    func disabledRunsImmediately() async {
        let recorder = Recorder()
        let gate = self.makeGate(recorder)
        await gate.perform(.pause, canFade: false, intentGeneration: { recorder.generation }) {
            recorder.events.append("body")
        }
        #expect(recorder.events == ["body"])
        #expect(!gate.isFading)
    }

    @Test("A pause fades out, pauses, then always releases")
    func pauseFadesThenReleases() async {
        let recorder = Recorder()
        let gate = self.makeGate(recorder)
        let start = ContinuousClock.now
        await gate.perform(.pause, canFade: true, intentGeneration: { recorder.generation }) {
            recorder.events.append("body")
        }
        #expect(ContinuousClock.now - start >= .milliseconds(40))
        #expect(recorder.events == ["fadeOut(1,0)", "body", "release(1)"])
        #expect(!gate.isFading)
    }

    @Test("A skip arms the next song's fade-in")
    func skipArmsFadeIn() async {
        let recorder = Recorder()
        let gate = self.makeGate(recorder)
        await gate.perform(.skip, canFade: true, intentGeneration: { recorder.generation }) {
            recorder.events.append("body")
        }
        #expect(recorder.events == ["fadeOut(1,\(SongTransitionTiming.skipFadeInMilliseconds))", "body", "release(1)"])
    }

    @Test("A newer playback intent during the fade drops the command but still releases")
    func supersededCommandReleases() async {
        let recorder = Recorder()
        let gate = self.makeGate(recorder, fade: .milliseconds(100))
        recorder.onFadeOut = { recorder.generation += 1 }
        await gate.perform(.pause, canFade: true, intentGeneration: { recorder.generation }) {
            recorder.events.append("body")
        }
        #expect(recorder.events == ["fadeOut(1,0)", "release(1,superseded)"])
    }

    @Test("Two quick skips both run, in order, without waiting for the full fade")
    func quickSkipsRunInOrder() async {
        let recorder = Recorder()
        let gate = self.makeGate(recorder, fade: .seconds(60))
        let start = ContinuousClock.now
        async let first: Void = gate.perform(.skip, canFade: true, intentGeneration: { recorder.generation }) {
            recorder.events.append("skip1")
        }
        await self.waitUntilFading(gate)
        #expect(gate.isFading)
        await gate.perform(.skip, canFade: true, intentGeneration: { recorder.generation }) {
            recorder.events.append("skip2")
        }
        await first
        // The 60 s fade was cut short by the second press.
        #expect(ContinuousClock.now - start < .seconds(30))
        #expect(recorder.events.filter { $0.hasPrefix("skip") } == ["skip1", "skip2"])
        #expect(recorder.events.contains("release(1)"))
        #expect(recorder.events.count(where: { $0.hasPrefix("fadeOut") }) == 1)
    }

    @Test("Three quick presses all run in order; only the first fades")
    func threeQuickPresses() async {
        let recorder = Recorder()
        let gate = self.makeGate(recorder, fade: .seconds(60))
        async let first: Void = gate.perform(.skip, canFade: true, intentGeneration: { recorder.generation }) {
            recorder.events.append("skip1")
        }
        await self.waitUntilFading(gate)
        #expect(gate.isFading)
        async let second: Void = gate.perform(.skip, canFade: true, intentGeneration: { recorder.generation }) {
            recorder.events.append("skip2")
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while gate.waitingCommandCount < 1, !recorder.events.contains("skip2"), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        await gate.perform(.pause, canFade: false, intentGeneration: { recorder.generation }) {
            recorder.events.append("pause3")
        }
        await first
        await second
        #expect(recorder.events.filter { !$0.hasPrefix("fadeOut") && !$0.hasPrefix("release") }
            == ["skip1", "skip2", "pause3"])
        #expect(recorder.events.count(where: { $0.hasPrefix("fadeOut") }) == 1)
        #expect(recorder.events.count(where: { $0.hasPrefix("release") }) == 1)
    }

    @Test("A resume during a fade-out ramps straight back up")
    func resumeDuringFade() async {
        let recorder = Recorder()
        let gate = self.makeGate(recorder, fade: .milliseconds(100))
        recorder.onFadeOut = {
            gate.prepareResume(canFade: false)
            recorder.generation += 1
        }
        await gate.perform(.pause, canFade: true, intentGeneration: { recorder.generation }) {
            recorder.events.append("pause")
        }
        #expect(recorder.events == [
            "fadeOut(1,0)",
            "fadeInOnPlay(\(SongTransitionTiming.resumeFadeInMilliseconds))",
            "release(1,superseded)",
        ])
    }

    @Test("The page fade length matches the Swift wait")
    func fadeLengthMatchesWait() async {
        let recorder = Recorder()
        let gate = self.makeGate(recorder, fade: .milliseconds(40))
        await gate.perform(.pause, canFade: true, intentGeneration: { recorder.generation }) {}
        #expect(recorder.commands.first == .fadeOut(token: 1, milliseconds: 40, fadeInMilliseconds: 0))
    }

    @Test("Resume requests a fade-in only when allowed")
    func resumeFadeIn() {
        let recorder = Recorder()
        let gate = self.makeGate(recorder)
        gate.prepareResume(canFade: false)
        #expect(recorder.events.isEmpty)
        gate.prepareResume(canFade: true)
        #expect(recorder.events == ["fadeInOnPlay(\(SongTransitionTiming.resumeFadeInMilliseconds))"])
    }
}
