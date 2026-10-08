// The developer's view of the sensor, built into Debug builds only: a live
// chart of what the knock detector hears, and a recorder that captures labeled
// sessions for the evaluation in Evaluation/. Release builds leave all of this
// out, so the shipping window stays one sentence and one button.

#if DEBUG

import Foundation

/// The labels for one recorded session. They're saved as JSON next to the
/// readings (a .bin file: x, y and z for each reading as little-endian Int16 in
/// units of 1/16384 g), and the corpus test reads both back.
struct Recording: Codable {
    enum Split: String, Codable {
        /// The constants may be tuned on it.
        case tuning
        /// It only scores the constants. Every new recording starts here.
        case holdout
    }

    struct Segment: Codable {
        enum Expect: String, Codable { case triple, single, none }
        /// The prompt that was on screen.
        let label: String
        let expect: Expect
        /// Index of the segment's first reading, and the index after its last.
        let start: Int
        let end: Int
    }

    var scenario: String
    /// The Mac's model identifier (hw.model), such as Mac14,6.
    var mac: String
    var macOS: String
    /// Seconds between readings, measured over the whole session.
    var sampleSpacing: Double
    var split: Split
    var segments: [Segment]
}

#endif
