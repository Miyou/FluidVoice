@testable import FluidVoice_Debug
import Foundation
import XCTest

final class MeetingSpeakerVoiceprintTests: XCTestCase {
    func testPlaceholderNamesAreNotUserNames() {
        for name in ["Speaker", "Speaker 3", " speaker 12 ", ""] {
            XCTAssertTrue(MeetingSpeakerVoiceSuggester.isPlaceholderName(name), name)
        }
        for name in ["Serge", "Speaker Pelosi", "Speaker 3b"] {
            XCTAssertFalse(MeetingSpeakerVoiceSuggester.isPlaceholderName(name), name)
        }
    }

    func testSuggestsTheClosestNameWhenItIsCloseAndUnambiguous() {
        let speaker = SessionSpeakerID()
        let suggestions = MeetingSpeakerVoiceSuggester.suggestions(
            clipsBySpeaker: [speaker: [self.vector(angle: 0.05), self.vector(angle: -0.05)]],
            voiceprints: [self.print("Serge", angles: [0]), self.print("Milan", angles: [1.2])],
            takenNames: []
        )
        XCTAssertEqual(suggestions[speaker]?.name, "Serge")
    }

    func testNoSuggestionWhenTooFarOrAmbiguous() {
        let speaker = SessionSpeakerID()
        let far = MeetingSpeakerVoiceSuggester.suggestions(
            clipsBySpeaker: [speaker: [self.vector(angle: 0)]],
            voiceprints: [self.print("Serge", angles: [1.4])],
            takenNames: []
        )
        XCTAssertNil(far[speaker])

        let ambiguous = MeetingSpeakerVoiceSuggester.suggestions(
            clipsBySpeaker: [speaker: [self.vector(angle: 0)]],
            voiceprints: [self.print("Serge", angles: [0.30]), self.print("Milan", angles: [-0.31])],
            takenNames: []
        )
        XCTAssertNil(ambiguous[speaker])
    }

    func testNamesAlreadyInTheMeetingAreNotOffered() {
        let speaker = SessionSpeakerID()
        let suggestions = MeetingSpeakerVoiceSuggester.suggestions(
            clipsBySpeaker: [speaker: [self.vector(angle: 0)]],
            voiceprints: [self.print("Serge", angles: [0])],
            takenNames: ["serge"]
        )
        XCTAssertNil(suggestions[speaker])
    }

    func testTwoSpeakersClaimingOneNameKeepsOnlyTheCloser() {
        let closer = SessionSpeakerID()
        let farther = SessionSpeakerID()
        let suggestions = MeetingSpeakerVoiceSuggester.suggestions(
            clipsBySpeaker: [closer: [self.vector(angle: 0.02)], farther: [self.vector(angle: 0.3)]],
            voiceprints: [self.print("Serge", angles: [0])],
            takenNames: []
        )
        XCTAssertEqual(suggestions[closer]?.name, "Serge")
        XCTAssertNil(suggestions[farther])
    }

    func testLearningFilesClipsUnderTheNameAndReplacesAnEarlierNameForTheSameSpeaker() {
        let session = MeetingSessionID()
        let speaker = SessionSpeakerID()
        let now = Date(timeIntervalSince1970: 0)
        var prints = MeetingSpeakerVoiceSuggester.learning(
            [], name: "Sergei", clips: [self.vector(angle: 0)], sessionID: session, speakerID: speaker, now: now
        )
        XCTAssertEqual(prints.map(\.name), ["Sergei"])

        // Renamed to fix a typo: the old name loses this speaker's samples and disappears.
        prints = MeetingSpeakerVoiceSuggester.learning(
            prints, name: "Serge", clips: [self.vector(angle: 0)], sessionID: session, speakerID: speaker, now: now
        )
        XCTAssertEqual(prints.map(\.name), ["Serge"])
        XCTAssertEqual(prints[0].samples.count, 1)

        // Reset to a placeholder: nothing is learned and the speaker is forgotten.
        prints = MeetingSpeakerVoiceSuggester.learning(
            prints, name: "Speaker 2", clips: [self.vector(angle: 0)], sessionID: session, speakerID: speaker, now: now
        )
        XCTAssertTrue(prints.isEmpty)
    }

    func testLearningMatchesNamesCaseInsensitivelyAndCapsSamples() {
        var prints: [MeetingSpeakerVoiceprint] = []
        for index in 0..<40 {
            prints = MeetingSpeakerVoiceSuggester.learning(
                prints,
                name: index.isMultiple(of: 2) ? "serge" : "Serge",
                clips: [self.vector(angle: Float(index) / 100)],
                sessionID: MeetingSessionID(),
                speakerID: SessionSpeakerID(),
                now: Date()
            )
        }
        XCTAssertEqual(prints.count, 1)
        XCTAssertEqual(prints[0].samples.count, MeetingSpeakerVoiceSuggester.maximumSamplesPerName)
    }

    func testStoreRoundTripsAndForgets() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("voiceprints.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = MeetingSpeakerVoiceprintStore(fileURL: url)
        try await store.learn(name: "Serge", clips: [self.vector(angle: 0)], sessionID: UUID(), speakerID: UUID())

        let reloaded = await MeetingSpeakerVoiceprintStore(fileURL: url).all()
        XCTAssertEqual(reloaded.map(\.name), ["Serge"])

        try await store.forget(name: "SERGE")
        let afterForget = await MeetingSpeakerVoiceprintStore(fileURL: url).all()
        XCTAssertTrue(afterForget.isEmpty)
    }

    func testClipSourcePrefersLongCleanTurns() {
        let speaker = SessionSpeakerID()
        func segment(_ start: Int64, _ end: Int64, overlap: MeetingTranscriptOverlap = .none, echo: Bool = false,
                     speakerID: SessionSpeakerID? = nil) -> MeetingTranscriptSegment
        {
            MeetingTranscriptSegment(
                id: UUID(),
                start: MeetingMediaTime(value: start, timescale: 1),
                end: MeetingMediaTime(value: end, timescale: 1),
                sourceTrackID: UUID(),
                speakerID: speakerID ?? speaker,
                text: "words",
                revision: 0,
                status: .final,
                overlap: overlap,
                completeness: .complete,
                isLikelyEcho: echo
            )
        }
        let segments = [
            segment(0, 2), // too short
            segment(10, 15),
            segment(20, 40),
            segment(50, 60, overlap: .overlapsOtherTrack),
            segment(70, 80, echo: true),
            segment(90, 100, speakerID: SessionSpeakerID()),
        ]
        let picked = MeetingSpeakerVoiceClipSource.segments(for: speaker, in: segments)
        XCTAssertEqual(picked.map(\.start.seconds), [20, 10])
    }

    func testClipTrimmingDropsEdgesAndCapsAtTenSeconds() {
        XCTAssertNil(MeetingSpeakerVoiceClipSource.trimmed([Float](repeating: 0.1, count: 3 * 16_000)))
        let long = MeetingSpeakerVoiceClipSource.trimmed([Float](repeating: 0.1, count: 30 * 16_000))
        XCTAssertEqual(long?.count, 10 * 16_000)
    }

    /// Opt-in calibration on the user's own saved meetings. Prints names and distances only.
    func testCalibrateOnSavedMeetings() async throws {
        guard ProcessInfo.processInfo.environment["FLUIDVOICE_VOICEPRINT_CALIBRATION"] == "1" else {
            throw XCTSkip("Set FLUIDVOICE_VOICEPRINT_CALIBRATION=1 to measure distances on saved meetings.")
        }
        let store = MeetingSessionStore.shared
        let embedder = MeetingSpeakerVoiceEmbedder()
        var observations: [(name: String, session: MeetingSessionID, track: String, clips: [[Float]])] = []
        for session in try await store.loadAll() {
            guard let directory = try await store.existingSessionDirectory(for: session.id) else { continue }
            for speaker in session.activeSpeakers where !MeetingSpeakerVoiceSuggester.isPlaceholderName(speaker.displayName) {
                let clips = try await embedder.clips(session: session, speakerID: speaker.id, directory: directory)
                Swift.print("CALIBRATION meeting=\(session.id.uuidString.prefix(4)) speaker=\(speaker.displayName) track=\(speaker.trackKind.rawValue) clips=\(clips.count)")
                if !clips.isEmpty {
                    observations.append((speaker.displayName, session.id, speaker.trackKind.rawValue, clips))
                }
            }
        }
        var same: [Float] = []
        var different: [Float] = []
        for (index, left) in observations.enumerated() {
            for right in observations[(index + 1)...] where right.session != left.session {
                let voiceprint = MeetingSpeakerVoiceprint(name: right.name, samples: right.clips.map {
                    .init(embedding: $0, sessionID: right.session, speakerID: UUID(), createdAt: Date())
                })
                guard let distance = MeetingSpeakerVoiceSuggester.distance(clips: left.clips, voiceprint: voiceprint) else { continue }
                let isSame = left.name.caseInsensitiveCompare(right.name) == .orderedSame
                if isSame { same.append(distance) } else { different.append(distance) }
                Swift.print(String(format: "CALIBRATION pair %@ %@(%@) vs %@(%@) = %.3f", isSame ? "SAME" : "diff",
                                   left.name, left.track, right.name, right.track, distance))
            }
        }
        Swift.print(String(format: "CALIBRATION same max=%.3f mean=%.3f n=%d | different min=%.3f mean=%.3f n=%d",
                           same.max() ?? -1, same.isEmpty ? -1 : same.reduce(0, +) / Float(same.count), same.count,
                           different.min() ?? -1, different.isEmpty ? -1 : different.reduce(0, +) / Float(different.count), different.count))
    }

    // MARK: - Helpers

    /// Unit vectors on a circle in the first two of 256 dimensions; cosine distance = 1 - cos(Δangle).
    private func vector(angle: Float) -> [Float] {
        var values = [Float](repeating: 0, count: 256)
        values[0] = cos(angle)
        values[1] = sin(angle)
        return values
    }

    private func print(_ name: String, angles: [Float]) -> MeetingSpeakerVoiceprint {
        MeetingSpeakerVoiceprint(name: name, samples: angles.map {
            .init(embedding: self.vector(angle: $0), sessionID: UUID(), speakerID: UUID(), createdAt: Date())
        })
    }
}
