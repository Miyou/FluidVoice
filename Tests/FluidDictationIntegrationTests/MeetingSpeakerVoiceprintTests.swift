import CoreAudio
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
            speakers: [.init(id: speaker, name: "Speaker 1", trackKind: .applicationAudio)],
            clipsBySpeaker: [speaker: [self.vector(angle: 0.05), self.vector(angle: -0.05)]],
            voiceprints: [self.print("Serge", angles: [0]), self.print("Milan", angles: [1.2])]
        )
        XCTAssertEqual(suggestions[speaker]?.name, "Serge")
        XCTAssertEqual(suggestions[speaker]?.relation, .new)
    }

    func testNoSuggestionWhenTooFarOrAmbiguous() {
        let speaker = SessionSpeakerID()
        let candidates: [MeetingSpeakerVoiceCandidate] = [.init(id: speaker, name: "Speaker 1", trackKind: .applicationAudio)]
        let far = MeetingSpeakerVoiceSuggester.suggestions(
            speakers: candidates, clipsBySpeaker: [speaker: [self.vector(angle: 0)]],
            voiceprints: [self.print("Serge", angles: [1.4])]
        )
        XCTAssertNil(far[speaker])

        let ambiguous = MeetingSpeakerVoiceSuggester.suggestions(
            speakers: candidates, clipsBySpeaker: [speaker: [self.vector(angle: 0)]],
            voiceprints: [self.print("Serge", angles: [0.30]), self.print("Milan", angles: [-0.31])]
        )
        XCTAssertNil(ambiguous[speaker])
    }

    func testAVoiceAlreadyNamedOnTheOtherSourceIsOfferedForTheSameName() {
        // 2026-11-06: Michael on the microphone, then again on the call audio after joining by phone.
        let mic = SessionSpeakerID()
        let phone = SessionSpeakerID()
        let suggestions = MeetingSpeakerVoiceSuggester.suggestions(
            speakers: [.init(id: mic, name: "Michael", trackKind: .microphone),
                       .init(id: phone, name: "Speaker 5", trackKind: .applicationAudio)],
            clipsBySpeaker: [mic: [self.vector(angle: 0)], phone: [self.vector(angle: 0.1)]],
            voiceprints: [self.print("Michael", angles: [0])]
        )
        XCTAssertEqual(suggestions[phone]?.name, "Michael")
        XCTAssertEqual(suggestions[phone]?.relation, .alsoOnOtherSource)
        XCTAssertNil(suggestions[mic], "named speakers get no suggestion")
    }

    func testOnePersonSplitOnOneSourceIsOfferedAsAMerge() {
        // 2026-11-06: Milan split into Speaker 3 and Speaker 6 on the call audio.
        let closer = SessionSpeakerID()
        let farther = SessionSpeakerID()
        let named = SessionSpeakerID()
        let suggestions = MeetingSpeakerVoiceSuggester.suggestions(
            speakers: [.init(id: closer, name: "Speaker 6", trackKind: .applicationAudio),
                       .init(id: farther, name: "Speaker 3", trackKind: .applicationAudio)],
            clipsBySpeaker: [closer: [self.vector(angle: 0.02)], farther: [self.vector(angle: 0.3)]],
            voiceprints: [self.print("Milan", angles: [0])]
        )
        XCTAssertEqual(suggestions[closer]?.relation, .new)
        XCTAssertEqual(suggestions[farther]?.relation, .sameVoiceAs(closer))

        // Once one of them is named Milan, the other is offered as a merge into it.
        let afterNaming = MeetingSpeakerVoiceSuggester.suggestions(
            speakers: [.init(id: named, name: "Milan", trackKind: .applicationAudio),
                       .init(id: farther, name: "Speaker 3", trackKind: .applicationAudio)],
            clipsBySpeaker: [named: [self.vector(angle: 0.02)], farther: [self.vector(angle: 0.3)]],
            voiceprints: [self.print("Milan", angles: [0])]
        )
        XCTAssertEqual(afterNaming[farther]?.relation, .sameVoiceAs(named))
    }

    func testLinesByVoicePicksEachPersonsClosestLine() {
        let prints = [self.print("Pablo", angles: [0]), self.print("Daniel", angles: [1.5])]
        let lines = (0..<4).map { _ in UUID() }
        let picked = MeetingSpeakerVoiceSuggester.linesByVoice(clips: [
            .init(segmentID: lines[0], embedding: self.vector(angle: 0.2)),
            .init(segmentID: lines[1], embedding: self.vector(angle: 0.05)),
            .init(segmentID: lines[2], embedding: self.vector(angle: 1.45)),
            .init(segmentID: lines[3], embedding: self.vector(angle: 0.8)), // nobody's: ignored
        ], voiceprints: prints)
        XCTAssertEqual(picked.map(\.name), ["Pablo", "Daniel"])
        XCTAssertEqual(picked.map(\.segmentID), [lines[1], lines[2]])
        XCTAssertTrue(MeetingSpeakerVoiceSuggester.linesByVoice(clips: [
            .init(segmentID: lines[0], embedding: self.vector(angle: 0)),
        ], voiceprints: prints).isEmpty, "one voice: no per-voice lines")
    }

    func testSameNameIsAllowedAcrossAudioSourcesButNotWithinOne() {
        let mic = SessionSpeakerID()
        let call = SessionSpeakerID()
        let call2 = SessionSpeakerID()
        let current = [(id: mic, displayName: "Michael"), (id: call, displayName: "Speaker 5"), (id: call2, displayName: "Serge")]
        let kinds: [SessionSpeakerID: MeetingAudioTrackKind] = [mic: .microphone, call: .applicationAudio, call2: .applicationAudio]
        XCTAssertNil(MeetingAssignSpeakersValidation.duplicateName(current: current, drafts: [call: "Michael"], trackKinds: kinds))
        XCTAssertEqual(MeetingAssignSpeakersValidation.duplicateName(current: current, drafts: [call: "Serge"], trackKinds: kinds), "Serge")
    }

    func testLinesMoveOnlyBetweenSpeakersOfTheSameSource() {
        let mic = MeetingSessionSpeaker(id: UUID(), displayName: "Michael", trackKind: .microphone, isLocalUser: true, identityCandidates: [])
        let a = MeetingSessionSpeaker(id: UUID(), displayName: "Daniel", trackKind: .applicationAudio, isLocalUser: false, identityCandidates: [])
        let b = MeetingSessionSpeaker(id: UUID(), displayName: "Speaker 7", trackKind: .applicationAudio, isLocalUser: false, identityCandidates: [])
        var line = self.segment(speakerID: b.id, start: 0, end: 5)
        XCTAssertEqual(MeetingResultCanvas.reassignTargets(for: line, among: [mic, a, b]).map(\.id), [a.id])
        line.speakerID = nil // Unknown lines may go to anyone, as before.
        XCTAssertEqual(MeetingResultCanvas.reassignTargets(for: line, among: [mic, a, b]).count, 3)
    }

    func testSampleQuotesPreferCleanLongerLines() {
        let speaker = SessionSpeakerID()
        var short = self.segment(speakerID: speaker, start: 0, end: 1.5, text: "No, wasn't that mammography?")
        short.overlap = .none
        let clean = self.segment(speakerID: speaker, start: 10, end: 20, text: "A long clean line.")
        let quotes = MeetingAssignSpeakersQuoteSource.samples(for: speaker, in: [short, clean])
        XCTAssertEqual(quotes.map(\.text), ["A long clean line.", "No, wasn't that mammography?"])
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
                let clips = try await embedder.clips(session: session, speakerID: speaker.id, directory: directory).map(\.embedding)
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

    func testClipCacheReusesUnchangedSpeakersAndReembedsChangedOnes() {
        let kept = SessionSpeakerID()
        let changed = SessionSpeakerID()
        let added = SessionSpeakerID()
        let silent = SessionSpeakerID()
        let keptTurns = [UUID(), UUID()]
        let cached: [SessionSpeakerID: MeetingSpeakerVoiceClipCache.Entry] = [
            kept: .init(segmentIDs: keptTurns, clips: [self.vector(angle: 0)], clipSegmentIDs: [keptTurns[0]]),
            changed: .init(segmentIDs: [UUID()], clips: [self.vector(angle: 1)]),
        ]
        let plan = MeetingSpeakerVoiceClipCache.plan(cached: cached, wanted: [
            kept: keptTurns,
            changed: [UUID()], // a merge or reassignment gave it different turns
            added: [UUID()],
            silent: [], // no clean turns: nothing to embed
        ])
        XCTAssertEqual(Set(plan.reuse.keys), [kept])
        XCTAssertEqual(Set(plan.embed), [changed, added])
    }

    func testLearningAKnownNameKeepsOnlyClipsThatSoundLikeThem() {
        // Speaker 7: two of Daniel's clips and two of someone else's under one label.
        let daniel = self.print("Daniel", angles: [0])
        let clips = [self.vector(angle: 0.05), self.vector(angle: 1.4), self.vector(angle: -0.1), self.vector(angle: 1.45)]
        let kept = MeetingSpeakerVoiceSuggester.coherentClips(clips, existing: daniel)
        XCTAssertEqual(kept, [self.vector(angle: 0.05), self.vector(angle: -0.1)])

        let prints = MeetingSpeakerVoiceSuggester.learning(
            [daniel], name: "daniel", clips: clips, sessionID: UUID(), speakerID: UUID(), now: Date()
        )
        XCTAssertEqual(prints.first?.samples.count, 3)
    }

    func testLearningANewNameKeepsOnlyAnAgreeingMajority() {
        let majority = MeetingSpeakerVoiceSuggester.coherentClips(
            [self.vector(angle: 0), self.vector(angle: 0.1), self.vector(angle: 1.5)], existing: nil
        )
        XCTAssertEqual(majority.count, 2)
        XCTAssertTrue(MeetingSpeakerVoiceSuggester.coherentClips(
            [self.vector(angle: 0), self.vector(angle: 1.5)], existing: nil
        ).isEmpty, "two disagreeing clips: learn nothing rather than guess")
        XCTAssertEqual(MeetingSpeakerVoiceSuggester.coherentClips([self.vector(angle: 0)], existing: nil).count, 1)
    }

    func testMixedVoicesNamesEveryConfidentlyMatchedPerson() {
        let prints = [self.print("Pablo", angles: [0]), self.print("Daniel", angles: [1.5])]
        XCTAssertEqual(MeetingSpeakerVoiceSuggester.mixedVoices(
            clips: [self.vector(angle: 0.05), self.vector(angle: 0.1), self.vector(angle: 1.45)], voiceprints: prints
        ), ["Pablo", "Daniel"])
        XCTAssertEqual(MeetingSpeakerVoiceSuggester.mixedVoices(
            clips: [self.vector(angle: 0.05), self.vector(angle: -0.05)], voiceprints: prints
        ), [])
    }

    func testVirtualDefaultInputIsReplacedByARealMicrophone() {
        let devices: [(uid: String, transportType: UInt32)] = [
            ("BlackHole2ch_UID", kAudioDeviceTransportTypeVirtual),
            ("Aggregate_UID", kAudioDeviceTransportTypeAggregate),
            ("AirPods_UID", kAudioDeviceTransportTypeBluetooth),
            ("BuiltInMicrophoneDevice", kAudioDeviceTransportTypeBuiltIn),
        ]
        // AirPods dropped mid-meeting and macOS made BlackHole the default (2026-11-04, 11-06).
        XCTAssertEqual(MeetingMicrophoneDefaultPolicy.effectiveDefaultUID(
            systemDefaultUID: "BlackHole2ch_UID", devices: devices
        ), "BuiltInMicrophoneDevice")
        XCTAssertEqual(MeetingMicrophoneDefaultPolicy.effectiveDefaultUID(
            systemDefaultUID: "Aggregate_UID", devices: devices
        ), "BuiltInMicrophoneDevice")
        // A real default is always kept, Bluetooth included.
        XCTAssertEqual(MeetingMicrophoneDefaultPolicy.effectiveDefaultUID(
            systemDefaultUID: "AirPods_UID", devices: devices
        ), "AirPods_UID")
        // Without the built-in mic, any real microphone beats a virtual one.
        XCTAssertEqual(MeetingMicrophoneDefaultPolicy.effectiveDefaultUID(
            systemDefaultUID: "BlackHole2ch_UID", devices: Array(devices.prefix(3))
        ), "AirPods_UID")
        // Only virtual devices: keep the system default rather than nothing.
        XCTAssertEqual(MeetingMicrophoneDefaultPolicy.effectiveDefaultUID(
            systemDefaultUID: "BlackHole2ch_UID", devices: Array(devices.prefix(1))
        ), "BlackHole2ch_UID")
    }

    func testSplitByVoiceMovesConfidentLinesAndLeavesUnclearOnes() {
        let serge = SessionSpeakerID()
        let lines = (0..<4).map { _ in UUID() }
        let plan = MeetingSpeakerVoiceSplitter.plan(lines: [
            .init(segmentID: lines[0], embedding: self.vector(angle: 0.05)),  // Pablo (saved voice, not in meeting)
            .init(segmentID: lines[1], embedding: self.vector(angle: 1.52)),  // Serge (speaker in this meeting)
            .init(segmentID: lines[2], embedding: self.vector(angle: 0.77)),  // halfway: unclear, stays
            .init(segmentID: lines[3], embedding: self.vector(angle: 3.0)),   // nobody: stays
        ], references: [
            .init(target: .new("Pablo"), embeddings: [self.vector(angle: 0)]),
            .init(target: .existing(serge), embeddings: [self.vector(angle: 1.5)]),
        ])
        XCTAssertEqual(plan[lines[0]], .new("Pablo"))
        XCTAssertEqual(plan[lines[1]], .existing(serge))
        XCTAssertNil(plan[lines[2]])
        XCTAssertNil(plan[lines[3]])
    }

    // MARK: - Helpers

    private func segment(speakerID: SessionSpeakerID?, start: Double, end: Double, text: String = "words") -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(
            id: UUID(),
            start: MeetingMediaTime(value: Int64(start * 1000), timescale: 1000),
            end: MeetingMediaTime(value: Int64(end * 1000), timescale: 1000),
            sourceTrackID: UUID(),
            speakerID: speakerID,
            text: text,
            revision: 0,
            status: .final,
            overlap: .none,
            completeness: .complete
        )
    }

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
