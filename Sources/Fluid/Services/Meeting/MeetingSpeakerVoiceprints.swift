import Combine
import Foundation

#if arch(arm64)
import CoreML
import FluidAudio
#endif

/// Voice embeddings of speakers the user named, kept so later meetings can suggest the same name.
/// Only 256-value embeddings are stored, never audio, and nothing leaves the Mac.
nonisolated struct MeetingSpeakerVoiceprint: Codable, Equatable, Sendable {
    nonisolated struct Sample: Codable, Equatable, Sendable {
        var embedding: [Float]
        var sessionID: MeetingSessionID
        var speakerID: SessionSpeakerID
        var createdAt: Date
    }

    var name: String
    var samples: [Sample]
}

nonisolated struct MeetingSpeakerVoiceSuggestion: Equatable, Sendable {
    let name: String
    let distance: Float
}

nonisolated enum MeetingSpeakerVoiceSuggester {
    /// Calibrated on three real meetings: the same person across meetings scored 0.18–0.49,
    /// different people 0.51 and up (mean 0.81).
    static let maximumDistance: Float = 0.50
    static let ambiguityMargin: Float = 0.05
    static let maximumSamplesPerName = 30

    /// Pipeline placeholders ("Speaker 3", or a bare "Speaker" for re-matched clusters) are not
    /// names the user chose, so they are neither learned nor treated as already named.
    static func isPlaceholderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed.range(of: #"^Speaker( \d+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Distance to a name is the mean, over this speaker's clips, of the nearest stored sample.
    /// Nearest-neighbour keeps one person recognisable across microphones and call apps.
    static func distance(clips: [[Float]], voiceprint: MeetingSpeakerVoiceprint) -> Float? {
        let perClip = clips.compactMap { clip in
            voiceprint.samples.compactMap { MeetingSpeakerEmbeddingIndex.cosineDistance(clip, $0.embedding) }.min()
        }
        guard !perClip.isEmpty else { return nil }
        return perClip.reduce(0, +) / Float(perClip.count)
    }

    static func ranked(clips: [[Float]], voiceprints: [MeetingSpeakerVoiceprint]) -> [MeetingSpeakerVoiceSuggestion] {
        voiceprints.compactMap { voiceprint in
            self.distance(clips: clips, voiceprint: voiceprint).map { .init(name: voiceprint.name, distance: $0) }
        }.sorted { $0.distance == $1.distance ? $0.name < $1.name : $0.distance < $1.distance }
    }

    /// One suggestion per unnamed speaker. A name already used in this meeting is never offered,
    /// and when two speakers resolve to the same name only the closer one keeps it.
    static func suggestions(
        clipsBySpeaker: [SessionSpeakerID: [[Float]]],
        voiceprints: [MeetingSpeakerVoiceprint],
        takenNames: Set<String>
    ) -> [SessionSpeakerID: MeetingSpeakerVoiceSuggestion] {
        let taken = Set(takenNames.map { $0.lowercased() })
        let available = voiceprints.filter { !taken.contains($0.name.lowercased()) }
        var best: [SessionSpeakerID: MeetingSpeakerVoiceSuggestion] = [:]
        for (speakerID, clips) in clipsBySpeaker {
            let ranked = self.ranked(clips: clips, voiceprints: available)
            guard let first = ranked.first, first.distance <= self.maximumDistance else { continue }
            if ranked.count > 1, ranked[1].distance - first.distance < self.ambiguityMargin { continue }
            best[speakerID] = first
        }
        let byName = Dictionary(grouping: best, by: { $0.value.name.lowercased() })
        for (_, claims) in byName where claims.count > 1 {
            let winner = claims.min { $0.value.distance == $1.value.distance
                ? $0.key.uuidString < $1.key.uuidString : $0.value.distance < $1.value.distance }
            for claim in claims where claim.key != winner?.key {
                best[claim.key] = nil
            }
        }
        return best
    }

    /// Replaces whatever this meeting speaker previously taught (it may have been renamed), then
    /// files the new clips under `name`, keeping the most recent samples per name.
    static func learning(
        _ voiceprints: [MeetingSpeakerVoiceprint],
        name: String,
        clips: [[Float]],
        sessionID: MeetingSessionID,
        speakerID: SessionSpeakerID,
        now: Date
    ) -> [MeetingSpeakerVoiceprint] {
        var result = voiceprints.map { voiceprint in
            var copy = voiceprint
            copy.samples.removeAll { $0.sessionID == sessionID && $0.speakerID == speakerID }
            return copy
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !self.isPlaceholderName(trimmed), !clips.isEmpty {
            let samples = clips.map { Sample(embedding: $0, sessionID: sessionID, speakerID: speakerID, createdAt: now) }
            if let index = result.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                result[index].samples.append(contentsOf: samples)
                result[index].samples = Array(result[index].samples.suffix(self.maximumSamplesPerName))
            } else {
                result.append(.init(name: trimmed, samples: samples))
            }
        }
        return result.filter { !$0.samples.isEmpty }
    }

    private typealias Sample = MeetingSpeakerVoiceprint.Sample
}

/// Which turns of a speaker are clean enough to identify their voice.
nonisolated enum MeetingSpeakerVoiceClipSource {
    static let minimumSeconds: Double = 3
    static let maximumClips = 4

    static func segments(for speakerID: SessionSpeakerID, in segments: [MeetingTranscriptSegment]) -> [MeetingTranscriptSegment] {
        segments
            .filter {
                $0.speakerID == speakerID && !$0.isEcho && $0.status == .final && $0.overlap == .none
                    && $0.end.seconds - $0.start.seconds >= self.minimumSeconds
            }
            .sorted {
                let left = $0.end.seconds - $0.start.seconds
                let right = $1.end.seconds - $1.start.seconds
                return left == right ? $0.start.seconds < $1.start.seconds : left > right
            }
            .prefix(self.maximumClips)
            .map { $0 }
    }

    /// Drops turn edges, where the previous speaker often bleeds in, and caps the clip at the
    /// 10-second window the embedding model accepts.
    static func trimmed(_ samples: [Float], sampleRate: Int = 16_000) -> [Float]? {
        let edge = Int(0.2 * Double(sampleRate))
        guard samples.count - 2 * edge >= 3 * sampleRate else { return nil }
        let start = edge
        let end = min(samples.count - edge, start + 10 * sampleRate)
        return Array(samples[start..<end])
    }
}

actor MeetingSpeakerVoiceprintStore {
    static let shared = MeetingSpeakerVoiceprintStore()

    private let fileURL: URL
    private var cache: [MeetingSpeakerVoiceprint]?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.fileURL = applicationSupport
                .appendingPathComponent("FluidVoice", isDirectory: true)
                .appendingPathComponent("SpeakerVoiceprints.json")
        }
    }

    func all() -> [MeetingSpeakerVoiceprint] {
        if let cache { return cache }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: self.fileURL)).flatMap { try? decoder.decode([MeetingSpeakerVoiceprint].self, from: $0) } ?? []
        self.cache = loaded
        return loaded
    }

    func learn(name: String, clips: [[Float]], sessionID: MeetingSessionID, speakerID: SessionSpeakerID) throws {
        let updated = MeetingSpeakerVoiceSuggester.learning(
            self.all(), name: name, clips: clips, sessionID: sessionID, speakerID: speakerID, now: Date()
        )
        try self.write(updated)
    }

    func forget(name: String) throws {
        try self.write(self.all().filter { $0.name.caseInsensitiveCompare(name) != .orderedSame })
    }

    private func write(_ voiceprints: [MeetingSpeakerVoiceprint]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(voiceprints).write(to: self.fileURL, options: [.atomic])
        self.cache = voiceprints
    }
}

/// Embeds a speaker's clean turns with the same local model the meeting pipeline uses to keep
/// speakers apart. Reads the meeting's own audio files; nothing is uploaded.
final nonisolated class MeetingSpeakerVoiceEmbedder: @unchecked Sendable {
    #if arch(arm64)
    private var extractor: EmbeddingExtractor?
    private var maskFrames = 0
    #endif

    func clips(session: MeetingSession, speakerID: SessionSpeakerID, directory: URL) async throws -> [[Float]] {
        #if arch(arm64)
        let extractor = try await self.loadExtractor()
        let mask = [Float](repeating: 1, count: self.maskFrames)
        var clips: [[Float]] = []
        for segment in MeetingSpeakerVoiceClipSource.segments(for: speakerID, in: session.transcriptSegments) {
            try Task.checkCancellation()
            guard let slices = try? MeetingSegmentPlaybackPlan.slices(session: session, segment: segment, directory: directory)
            else { continue }
            var samples: [Float] = []
            for slice in slices {
                guard let part = try? MeetingProcessingPipeline.readSamples(
                    fileURL: slice.url, startSeconds: slice.start, endSeconds: slice.end
                ) else { continue }
                samples.append(contentsOf: part)
            }
            guard let clip = MeetingSpeakerVoiceClipSource.trimmed(samples) else { continue }
            let output = try extractor.getEmbeddings(audio: clip, masks: [mask])
            if let embedding = output.first, embedding.count == 256, embedding.allSatisfy(\.isFinite) {
                clips.append(embedding)
            }
        }
        return clips
        #else
        return []
        #endif
    }

    #if arch(arm64)
    private func loadExtractor() async throws -> EmbeddingExtractor {
        if let extractor { return extractor }
        let models = try await DownloadUtils.loadModels(
            .diarizer,
            modelNames: [ModelNames.Diarizer.embeddingFile],
            directory: DiarizerModels.defaultModelsDirectory().deletingLastPathComponent(),
            computeUnits: .cpuAndNeuralEngine
        )
        guard let model = models[ModelNames.Diarizer.embeddingFile],
              let maskFrames = model.modelDescription.inputDescriptionsByName["mask"]?
              .multiArrayConstraint?.shape.last?.intValue,
              (1...4096).contains(maskFrames)
        else {
            throw NSError(domain: "MeetingSpeakerVoice", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The speaker voice model has an unsupported input format.",
            ])
        }
        let extractor = EmbeddingExtractor(embeddingModel: model)
        self.extractor = extractor
        self.maskFrames = maskFrames
        return extractor
    }
    #endif
}

/// Drives the Edit speakers sheet: embeds each speaker once, offers names for unnamed ones, and
/// teaches the store the names the user saves.
@MainActor
final class MeetingSpeakerVoiceAssistant: ObservableObject {
    enum Status: Equatable {
        case idle
        case listening
        case ready
        case unavailable
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var suggestions: [SessionSpeakerID: MeetingSpeakerVoiceSuggestion] = [:]

    private let store: MeetingSpeakerVoiceprintStore
    private var clipsBySpeaker: [SessionSpeakerID: [[Float]]] = [:]
    private var task: Task<Void, Never>?

    init(store: MeetingSpeakerVoiceprintStore = .shared) {
        self.store = store
    }

    func start(sessionID: MeetingSessionID, speakers: [MeetingSessionSpeaker]) {
        guard self.status == .idle else { return }
        self.status = .listening
        let store = self.store
        self.task = Task { [weak self] in
            do {
                guard let session = try await MeetingSessionStore.shared.load(id: sessionID),
                      let directory = try await MeetingSessionStore.shared.existingSessionDirectory(for: sessionID)
                else { throw MeetingSegmentPlaybackError.unavailable }
                let embedder = MeetingSpeakerVoiceEmbedder()
                var clipsBySpeaker: [SessionSpeakerID: [[Float]]] = [:]
                for speaker in speakers {
                    try Task.checkCancellation()
                    let clips = try await Task.detached(priority: .userInitiated) {
                        try await embedder.clips(session: session, speakerID: speaker.id, directory: directory)
                    }.value
                    if !clips.isEmpty { clipsBySpeaker[speaker.id] = clips }
                }
                let voiceprints = await store.all()
                let unnamed = speakers.filter { MeetingSpeakerVoiceSuggester.isPlaceholderName($0.displayName) }.map(\.id)
                let taken = Set(speakers.map(\.displayName).filter { !MeetingSpeakerVoiceSuggester.isPlaceholderName($0) })
                let suggestions = MeetingSpeakerVoiceSuggester.suggestions(
                    clipsBySpeaker: clipsBySpeaker.filter { unnamed.contains($0.key) },
                    voiceprints: voiceprints,
                    takenNames: taken
                )
                for speaker in speakers {
                    guard let clips = clipsBySpeaker[speaker.id] else { continue }
                    let ranked = MeetingSpeakerVoiceSuggester.ranked(clips: clips, voiceprints: voiceprints).prefix(3)
                    DebugLogger.shared.debug(
                        "voice-suggest speaker=\(speaker.displayName) clips=\(clips.count) "
                            + ranked.map { "\($0.name)=\(String(format: "%.3f", $0.distance))" }.joined(separator: " "),
                        source: "MeetingSpeakerVoice"
                    )
                }
                DebugLogger.shared.info(
                    "voice-suggest ready speakers=\(clipsBySpeaker.count)/\(speakers.count) "
                        + "known=\(voiceprints.count) suggestions=\(suggestions.count)",
                    source: "MeetingSpeakerVoice"
                )
                guard let self, !Task.isCancelled else { return }
                self.clipsBySpeaker = clipsBySpeaker
                self.suggestions = suggestions
                self.status = .ready
            } catch {
                guard let self, !Task.isCancelled else { return }
                DebugLogger.shared.info("voice-suggest unavailable: \(error.localizedDescription)", source: "MeetingSpeakerVoice")
                self.status = .unavailable
            }
        }
    }

    func cancel() {
        self.task?.cancel()
        self.task = nil
    }

    /// Called after a successful save. Merged speakers teach nothing: their audio now belongs to
    /// the target, whose own clips already cover the voice.
    /// Runs independently of the sheet: a save made before the sheet finished listening still
    /// teaches every named speaker, embedding whichever ones it had not reached yet.
    func learn(sessionID: MeetingSessionID, edits: MeetingSpeakerEdits) {
        let cached = self.clipsBySpeaker
        let store = self.store
        Task.detached(priority: .utility) {
            let embedder = MeetingSpeakerVoiceEmbedder()
            var context: (session: MeetingSession, directory: URL)?
            for (speakerID, name) in edits.names where edits.merges[speakerID] == nil {
                var clips = cached[speakerID] ?? []
                do {
                    if clips.isEmpty, !MeetingSpeakerVoiceSuggester.isPlaceholderName(name) {
                        if context == nil,
                           let session = try await MeetingSessionStore.shared.load(id: sessionID),
                           let directory = try await MeetingSessionStore.shared.existingSessionDirectory(for: sessionID)
                        {
                            context = (session, directory)
                        }
                        if let context {
                            clips = try await embedder.clips(session: context.session, speakerID: speakerID, directory: context.directory)
                        }
                    }
                    try await store.learn(name: name, clips: clips, sessionID: sessionID, speakerID: speakerID)
                } catch {
                    DebugLogger.shared.info("voice-learn failed: \(error.localizedDescription)", source: "MeetingSpeakerVoice")
                }
            }
            DebugLogger.shared.info("voice-learn saved session=\(sessionID.uuidString.prefix(8))", source: "MeetingSpeakerVoice")
        }
    }
}
