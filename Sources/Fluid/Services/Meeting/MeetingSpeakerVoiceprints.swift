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
    enum Relation: Equatable, Sendable {
        /// Nobody else in this meeting has this voice.
        case new
        /// Another speaker on the same audio source has this voice: one person split in two.
        case sameVoiceAs(SessionSpeakerID)
        /// The same person on the other audio source (e.g. joined from a phone): same name, no merge.
        case alsoOnOtherSource
    }

    let name: String
    let distance: Float
    var relation: Relation = .new
}

/// A speaker as the suggester sees it: who it is called and which audio source it came from.
nonisolated struct MeetingSpeakerVoiceCandidate: Sendable {
    let id: SessionSpeakerID
    let name: String
    let trackKind: MeetingAudioTrackKind
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

    /// The confident, unambiguous name for one speaker's clips, if any.
    static func bestName(clips: [[Float]], voiceprints: [MeetingSpeakerVoiceprint]) -> MeetingSpeakerVoiceSuggestion? {
        let ranked = self.ranked(clips: clips, voiceprints: voiceprints)
        guard let first = ranked.first, first.distance <= self.maximumDistance else { return nil }
        if ranked.count > 1, ranked[1].distance - first.distance < self.ambiguityMargin { return nil }
        return first
    }

    /// One suggestion per unnamed speaker. One person can appear as several speakers (split by the
    /// diarizer, or joining again from a phone), so a voice that already has a speaker in this
    /// meeting is offered as "same voice" (same audio source, merge) or as the same name on the
    /// other audio source, instead of being hidden.
    static func suggestions(
        speakers: [MeetingSpeakerVoiceCandidate],
        clipsBySpeaker: [SessionSpeakerID: [[Float]]],
        voiceprints: [MeetingSpeakerVoiceprint]
    ) -> [SessionSpeakerID: MeetingSpeakerVoiceSuggestion] {
        var best: [SessionSpeakerID: MeetingSpeakerVoiceSuggestion] = [:]
        for speaker in speakers where self.isPlaceholderName(speaker.name) {
            guard let clips = clipsBySpeaker[speaker.id], let match = self.bestName(clips: clips, voiceprints: voiceprints)
            else { continue }
            best[speaker.id] = match
        }
        var result: [SessionSpeakerID: MeetingSpeakerVoiceSuggestion] = [:]
        for speaker in speakers {
            guard var suggestion = best[speaker.id] else { continue }
            let key = suggestion.name.lowercased()
            // Who already holds the voice: a speaker named so, or a closer unnamed claimant.
            let holders = speakers.filter { other in
                guard other.id != speaker.id else { return false }
                if other.name.lowercased() == key { return true }
                guard let theirs = best[other.id], theirs.name.lowercased() == key else { return false }
                return theirs.distance == suggestion.distance
                    ? other.id.uuidString < speaker.id.uuidString : theirs.distance < suggestion.distance
            }
            if let sameSource = holders.first(where: { $0.trackKind == speaker.trackKind }) {
                suggestion.relation = .sameVoiceAs(sameSource.id)
            } else if !holders.isEmpty {
                suggestion.relation = .alsoOnOtherSource
            }
            result[speaker.id] = suggestion
        }
        return result
    }

    /// For a speaker whose clips match different people: the best line for each person, so each
    /// voice can be played and checked on its own.
    static func linesByVoice(
        clips: [MeetingSpeakerVoiceClip],
        voiceprints: [MeetingSpeakerVoiceprint]
    ) -> [(name: String, segmentID: MeetingTranscriptSegmentID)] {
        var bestByName: [String: (distance: Float, segmentID: MeetingTranscriptSegmentID)] = [:]
        for clip in clips {
            guard let match = self.bestName(clips: [clip.embedding], voiceprints: voiceprints) else { continue }
            if bestByName[match.name].map({ match.distance < $0.distance }) ?? true {
                bestByName[match.name] = (match.distance, clip.segmentID)
            }
        }
        guard bestByName.count > 1 else { return [] }
        return bestByName.sorted { $0.value.distance < $1.value.distance }.map { ($0.key, $0.value.segmentID) }
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
        let existing = result.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        let clips = self.coherentClips(clips, existing: existing)
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

    /// The clips that can safely be filed under a name. Diarization sometimes gives two people one
    /// label, so a named speaker's clips may hold someone else's voice. Against a known voice, only
    /// clips that sound like it are kept. For a new name, only a clear majority that agree with one
    /// another is kept; when they don't agree, nothing is learned rather than guessing.
    static func coherentClips(_ clips: [[Float]], existing: MeetingSpeakerVoiceprint?) -> [[Float]] {
        if let existing, !existing.samples.isEmpty {
            return clips.filter { clip in
                let nearest = existing.samples.compactMap { MeetingSpeakerEmbeddingIndex.cosineDistance(clip, $0.embedding) }.min()
                return nearest.map { $0 <= self.maximumDistance } ?? false
            }
        }
        guard clips.count > 1 else { return clips }
        let groups = clips.indices.map { center in
            clips.indices.filter { other in
                other == center || (MeetingSpeakerEmbeddingIndex.cosineDistance(clips[center], clips[other]).map { $0 <= self.maximumDistance } ?? false)
            }
        }
        guard let largest = groups.max(by: { $0.count < $1.count }), largest.count * 2 > clips.count else { return [] }
        return largest.map { clips[$0] }
    }

    /// Names that different clips of one speaker confidently match. Two or more means the speaker
    /// is probably two people under one label.
    static func mixedVoices(clips: [[Float]], voiceprints: [MeetingSpeakerVoiceprint]) -> [String] {
        var counts: [String: Int] = [:]
        for clip in clips {
            let ranked = self.ranked(clips: [clip], voiceprints: voiceprints)
            guard let best = ranked.first, best.distance <= self.maximumDistance,
                  ranked.count == 1 || ranked[1].distance - best.distance >= self.ambiguityMargin
            else { continue }
            counts[best.name, default: 0] += 1
        }
        guard counts.count > 1 else { return [] }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
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

/// One embedded turn: the voice vector and the transcript line it came from.
nonisolated struct MeetingSpeakerVoiceClip: Equatable, Sendable {
    let segmentID: MeetingTranscriptSegmentID
    let embedding: [Float]
}

/// Embeds a speaker's clean turns with the same local model the meeting pipeline uses to keep
/// speakers apart. Reads the meeting's own audio files; nothing is uploaded.
final nonisolated class MeetingSpeakerVoiceEmbedder: @unchecked Sendable {
    #if arch(arm64)
    private var extractor: EmbeddingExtractor?
    private var maskFrames = 0
    #endif

    func clips(session: MeetingSession, speakerID: SessionSpeakerID, directory: URL) async throws -> [MeetingSpeakerVoiceClip] {
        #if arch(arm64)
        let extractor = try await self.loadExtractor()
        let mask = [Float](repeating: 1, count: self.maskFrames)
        var clips: [MeetingSpeakerVoiceClip] = []
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
                clips.append(MeetingSpeakerVoiceClip(segmentID: segment.id, embedding: embedding))
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

/// Per-meeting speaker embeddings, prepared when a meeting is opened so Edit speakers can suggest
/// names at once. Each entry remembers the turns it came from; a speaker is embedded again only
/// when those change (a merge or reassignment). Embeddings only, kept outside the meeting folder.
actor MeetingSpeakerVoiceClipCache {
    nonisolated struct Entry: Codable, Equatable, Sendable {
        var segmentIDs: [MeetingTranscriptSegmentID]
        var clips: [[Float]]
        /// The line each clip came from. Missing in caches written before it existed; those
        /// entries are embedded again.
        var clipSegmentIDs: [MeetingTranscriptSegmentID]? = nil

        var voiceClips: [MeetingSpeakerVoiceClip] {
            guard let clipSegmentIDs, clipSegmentIDs.count == self.clips.count else { return [] }
            return zip(clipSegmentIDs, self.clips).map { MeetingSpeakerVoiceClip(segmentID: $0, embedding: $1) }
        }
    }

    static let shared = MeetingSpeakerVoiceClipCache()

    private let directory: URL
    private var inFlight: [MeetingSessionID: Task<[SessionSpeakerID: [MeetingSpeakerVoiceClip]], Error>] = [:]

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.directory = applicationSupport
                .appendingPathComponent("FluidVoice", isDirectory: true)
                .appendingPathComponent("SpeakerVoiceClips", isDirectory: true)
        }
    }

    /// Which speakers can reuse their cached embeddings, and which need embedding (again).
    nonisolated static func plan(
        cached: [SessionSpeakerID: Entry],
        wanted: [SessionSpeakerID: [MeetingTranscriptSegmentID]]
    ) -> (reuse: [SessionSpeakerID: Entry], embed: [SessionSpeakerID]) {
        var reuse: [SessionSpeakerID: Entry] = [:]
        var embed: [SessionSpeakerID] = []
        for (speakerID, segmentIDs) in wanted where !segmentIDs.isEmpty {
            if let entry = cached[speakerID], entry.segmentIDs == segmentIDs,
               entry.clipSegmentIDs?.count == entry.clips.count
            {
                reuse[speakerID] = entry
            } else {
                embed.append(speakerID)
            }
        }
        return (reuse, embed.sorted { $0.uuidString < $1.uuidString })
    }

    /// Clips for every active speaker, embedding only what is missing or stale. Concurrent callers
    /// for one meeting (the background pass and an opened sheet) share a single pass.
    func clips(sessionID: MeetingSessionID) async throws -> [SessionSpeakerID: [MeetingSpeakerVoiceClip]] {
        if let running = self.inFlight[sessionID] { return try await running.value }
        let file = self.directory.appendingPathComponent("\(sessionID.uuidString).json")
        let directory = self.directory
        let pass = Task.detached(priority: .utility) {
            try await Self.refresh(sessionID: sessionID, file: file, directory: directory)
        }
        self.inFlight[sessionID] = pass
        defer { self.inFlight[sessionID] = nil }
        return try await pass.value
    }

    private nonisolated static func refresh(
        sessionID: MeetingSessionID, file: URL, directory: URL
    ) async throws -> [SessionSpeakerID: [MeetingSpeakerVoiceClip]] {
        guard let session = try await MeetingSessionStore.shared.load(id: sessionID),
              let sessionDirectory = try await MeetingSessionStore.shared.existingSessionDirectory(for: sessionID)
        else { throw MeetingSegmentPlaybackError.unavailable }
        let cached = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([SessionSpeakerID: Entry].self, from: $0) } ?? [:]
        let wanted = Dictionary(uniqueKeysWithValues: session.activeSpeakers.map { speaker in
            (speaker.id, MeetingSpeakerVoiceClipSource.segments(for: speaker.id, in: session.transcriptSegments).map(\.id))
        })
        let plan = Self.plan(cached: cached, wanted: wanted)
        var entries = plan.reuse
        let embedder = MeetingSpeakerVoiceEmbedder()
        for speakerID in plan.embed {
            try Task.checkCancellation()
            let clips = try await embedder.clips(session: session, speakerID: speakerID, directory: sessionDirectory)
            entries[speakerID] = Entry(
                segmentIDs: wanted[speakerID] ?? [], clips: clips.map(\.embedding), clipSegmentIDs: clips.map(\.segmentID)
            )
        }
        if entries != cached {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: file, options: [.atomic])
        }
        DebugLogger.shared.info(
            "voice-clips session=\(sessionID.uuidString.prefix(8)) reused=\(plan.reuse.count) embedded=\(plan.embed.count)",
            source: "MeetingSpeakerVoice"
        )
        return entries.compactMapValues { $0.voiceClips.isEmpty ? nil : $0.voiceClips }
    }
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
    @Published private(set) var mixedVoices: [SessionSpeakerID: [String]] = [:]
    /// For mixed speakers: the best line for each matched person, to play and check.
    @Published private(set) var linesByVoice: [SessionSpeakerID: [(name: String, segmentID: MeetingTranscriptSegmentID)]] = [:]

    private let store: MeetingSpeakerVoiceprintStore
    private let clipCache: MeetingSpeakerVoiceClipCache
    private var clipsBySpeaker: [SessionSpeakerID: [[Float]]] = [:]
    private var task: Task<Void, Never>?

    init(store: MeetingSpeakerVoiceprintStore = .shared, clipCache: MeetingSpeakerVoiceClipCache = .shared) {
        self.store = store
        self.clipCache = clipCache
    }

    func start(sessionID: MeetingSessionID, speakers: [MeetingSessionSpeaker]) {
        guard self.status == .idle else { return }
        self.status = .listening
        let store = self.store
        let clipCache = self.clipCache
        self.task = Task { [weak self] in
            do {
                // Usually already prepared when the meeting was opened, so this is a file read.
                let speakerIDs = Set(speakers.map(\.id))
                let voiceClips = try await clipCache.clips(sessionID: sessionID).filter { speakerIDs.contains($0.key) }
                let clipsBySpeaker = voiceClips.mapValues { $0.map(\.embedding) }
                let voiceprints = await store.all()
                let suggestions = MeetingSpeakerVoiceSuggester.suggestions(
                    speakers: speakers.map { .init(id: $0.id, name: $0.displayName, trackKind: $0.trackKind) },
                    clipsBySpeaker: clipsBySpeaker,
                    voiceprints: voiceprints
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
                let mixed = clipsBySpeaker.compactMapValues { clips -> [String]? in
                    let names = MeetingSpeakerVoiceSuggester.mixedVoices(clips: clips, voiceprints: voiceprints)
                    return names.isEmpty ? nil : names
                }
                let lines = voiceClips.filter { mixed[$0.key] != nil }.compactMapValues { clips in
                    let lines = MeetingSpeakerVoiceSuggester.linesByVoice(clips: clips, voiceprints: voiceprints)
                    return lines.isEmpty ? nil : lines
                }
                guard let self, !Task.isCancelled else { return }
                self.clipsBySpeaker = clipsBySpeaker
                self.mixedVoices = mixed
                self.linesByVoice = lines
                self.suggestions = suggestions.filter { mixed[$0.key] == nil }
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
        let clipCache = self.clipCache
        Task.detached(priority: .utility) {
            // The save may have merged speakers, so the cache re-embeds any whose turns changed.
            let current = (try? await clipCache.clips(sessionID: sessionID))?.mapValues { $0.map(\.embedding) } ?? cached
            for (speakerID, name) in edits.names where edits.merges[speakerID] == nil {
                let clips = current[speakerID] ?? []
                do {
                    try await store.learn(name: name, clips: clips, sessionID: sessionID, speakerID: speakerID)
                } catch {
                    DebugLogger.shared.info("voice-learn failed: \(error.localizedDescription)", source: "MeetingSpeakerVoice")
                }
            }
            DebugLogger.shared.info("voice-learn saved session=\(sessionID.uuidString.prefix(8))", source: "MeetingSpeakerVoice")
        }
    }
}
