import Foundation

/// How long a person takes to type and send a sequence of bubbles.
///
/// People don't send five messages at once. They type one (the other person sees the
/// typing bubble), send it, pause, and start the next. Typing time grows with length at the
/// person's typing speed, varies a little each time, speeds up for emoji and short
/// replies, and never takes unreasonably long even for long texts.
public struct TypingPlan: Sendable, Equatable {
    public struct Bubble: Sendable, Equatable {
        public let text: String
        /// Pause after the previous bubble was sent, before typing starts.
        public let pauseBefore: TimeInterval
        /// How long typing this bubble takes.
        public let typingDuration: TimeInterval
        /// Delay before each character, when typing into Messages.
        public let keystrokeDelays: [TimeInterval]
    }

    public let bubbles: [Bubble]

    public var totalDuration: TimeInterval {
        bubbles.reduce(0) { $0 + $1.pauseBefore + $1.typingDuration }
    }

    /// Longest time spent typing one bubble.
    public static let maximumTypingDuration: TimeInterval = 30
    public static let minimumTypingDuration: TimeInterval = 0.8

    /// Builds a plan for `texts` at `wordsPerMinute`, kept between 6 and 600 words per minute.
    /// The same `seed` always gives the same plan, which keeps previews and tests reproducible.
    public static func make(_ texts: [String], wordsPerMinute: Double, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) -> TypingPlan {
        var random = SplitMix64(seed: seed)
        // A speed of zero, infinity or NaN would give no typing time at all, or endless typing.
        let charactersPerSecond = min(max(0.5, wordsPerMinute * 5 / 60), 50)
        var bubbles: [Bubble] = []
        for (index, text) in texts.enumerated() {
            let characters = Array(text)
            let emojiOnly = !characters.isEmpty && characters.allSatisfy { $0.unicodeScalars.contains { $0.properties.isEmojiPresentation } || $0 == " " }
            var delays: [TimeInterval] = []
            var previous: Character?
            for character in characters {
                var delay = 1 / charactersPerSecond
                // Natural rhythm: a little faster inside words, slower after spaces and punctuation.
                if let previous {
                    if previous == " " { delay *= 1.35 }
                    if ".,!?;:".contains(previous) { delay *= 2.2 }
                    if character == previous { delay *= 0.8 }
                }
                if character.isUppercase { delay *= 1.25 }
                if emojiOnly { delay *= 2.5 } // Picking an emoji takes longer than a key, but there are few.
                delay *= random.logNormal(sigma: 0.35)
                delays.append(min(delay, 1.6))
                previous = character
            }
            var typing = delays.reduce(0, +)
            let clamped = min(max(typing, minimumTypingDuration), maximumTypingDuration)
            if typing > 0, clamped != typing {
                let scale = clamped / typing
                delays = delays.map { $0 * scale }
                typing = clamped
            }
            if delays.isEmpty { typing = minimumTypingDuration }
            // After sending, people glance at the conversation before typing the next bubble.
            let pause = index == 0 ? 0 : min(3.5, 0.6 + random.logNormal(sigma: 0.45) * 0.9)
            bubbles.append(Bubble(text: text, pauseBefore: pause, typingDuration: typing, keystrokeDelays: delays))
        }
        return TypingPlan(bubbles: bubbles)
    }

    /// No pacing: send one bubble after another with a short gap so they arrive in order.
    public static func immediate(_ texts: [String]) -> TypingPlan {
        TypingPlan(
            bubbles: texts.enumerated().map { index, text in
                Bubble(text: text, pauseBefore: index == 0 ? 0 : 0.4, typingDuration: 0, keystrokeDelays: Array(repeating: 0, count: text.count))
            })
    }
}

/// A small deterministic random number generator for reproducible plans.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// A multiplier around 1 with a long right tail, like human timing.
    mutating func logNormal(sigma: Double) -> Double {
        let u1 = max(unit(), .leastNonzeroMagnitude)
        let u2 = unit()
        let normal = sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        return exp(sigma * normal - sigma * sigma / 2)
    }
}
