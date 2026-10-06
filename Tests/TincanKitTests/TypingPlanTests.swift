import Foundation
import Testing

@testable import TincanKit

@Suite("Typing plans")
struct TypingPlanTests {
    static let bubbles = ["hey!", "running about 10 minutes late, sorry", "save me a seat 🙏"]

    @Test func theSameSeedGivesTheSamePlan() {
        let first = TypingPlan.make(Self.bubbles, wordsPerMinute: 42, seed: 7)
        let second = TypingPlan.make(Self.bubbles, wordsPerMinute: 42, seed: 7)
        let other = TypingPlan.make(Self.bubbles, wordsPerMinute: 42, seed: 8)
        #expect(first == second)
        #expect(first != other)
    }

    @Test func onlyLaterBubblesWaitBeforeTyping() {
        let plan = TypingPlan.make(Self.bubbles, wordsPerMinute: 42, seed: 7)
        #expect(plan.bubbles.map(\.text) == Self.bubbles)
        #expect(plan.bubbles.first?.pauseBefore == 0)
        for bubble in plan.bubbles.dropFirst() {
            #expect(bubble.pauseBefore > 0 && bubble.pauseBefore <= 3.5)
        }
    }

    @Test("Typing time stays within human limits", arguments: [1, 2, 3, 4, 5] as [UInt64])
    func typingTimeIsClamped(seed: UInt64) {
        let texts = ["k", "ok", Self.bubbles[1], String(repeating: "a much longer message that keeps going ", count: 20)]
        let plan = TypingPlan.make(texts, wordsPerMinute: 42, seed: seed)
        for bubble in plan.bubbles {
            #expect(bubble.typingDuration >= TypingPlan.minimumTypingDuration)
            #expect(bubble.typingDuration <= TypingPlan.maximumTypingDuration)
        }
        #expect(plan.bubbles.last?.typingDuration == TypingPlan.maximumTypingDuration)
    }

    @Test("Keystroke delays cover every character and add up to the typing time", arguments: [1, 2, 3] as [UInt64])
    func keystrokesMatchTheText(seed: UInt64) {
        let texts = Self.bubbles + ["a", String(repeating: "long ", count: 200)]
        let plan = TypingPlan.make(texts, wordsPerMinute: 60, seed: seed)
        for bubble in plan.bubbles {
            #expect(bubble.keystrokeDelays.count == bubble.text.count)
            #expect(abs(bubble.keystrokeDelays.reduce(0, +) - bubble.typingDuration) < 1e-9)
            #expect(bubble.keystrokeDelays.allSatisfy { $0 > 0 })
        }
    }

    @Test("Any typing speed gives a plan within human limits", arguments: [0, -10, .infinity, -.infinity, .nan, 1e300] as [Double])
    func extremeSpeeds(wordsPerMinute: Double) {
        let plan = TypingPlan.make(["hello there", "ok 👍"], wordsPerMinute: wordsPerMinute, seed: 1)
        for bubble in plan.bubbles {
            #expect(bubble.typingDuration >= TypingPlan.minimumTypingDuration)
            #expect(bubble.typingDuration <= TypingPlan.maximumTypingDuration)
            #expect(bubble.keystrokeDelays.allSatisfy { $0.isFinite && $0 > 0 })
            #expect(abs(bubble.keystrokeDelays.reduce(0, +) - bubble.typingDuration) < 1e-9)
        }
    }

    @Test func fasterTypistsFinishSooner() {
        let slow = TypingPlan.make([Self.bubbles[1]], wordsPerMinute: 30, seed: 11)
        let fast = TypingPlan.make([Self.bubbles[1]], wordsPerMinute: 90, seed: 11)
        #expect(fast.totalDuration < slow.totalDuration)
    }

    @Test func totalDurationAddsPausesAndTyping() {
        let plan = TypingPlan.make(Self.bubbles, wordsPerMinute: 42, seed: 3)
        let expected = plan.bubbles.reduce(0) { $0 + $1.pauseBefore + $1.typingDuration }
        #expect(plan.totalDuration == expected)
    }

    @Test func anEmptyBubbleStillTakesTheMinimumTime() {
        let bubble = TypingPlan.make([""], wordsPerMinute: 42, seed: 1).bubbles[0]
        #expect(bubble.keystrokeDelays.isEmpty)
        #expect(bubble.typingDuration == TypingPlan.minimumTypingDuration)
    }

    @Test func immediatePlansDoNotType() {
        let plan = TypingPlan.immediate(Self.bubbles)
        #expect(plan.bubbles.map(\.typingDuration) == [0, 0, 0])
        #expect(plan.bubbles.map(\.pauseBefore) == [0, 0.4, 0.4])
        #expect(plan.bubbles.map(\.keystrokeDelays.count) == Self.bubbles.map(\.count))
        #expect(plan.bubbles.allSatisfy { $0.keystrokeDelays.allSatisfy { $0 == 0 } })
        #expect(abs(plan.totalDuration - 0.8) < 1e-9)
    }
}
