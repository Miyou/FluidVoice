import SwiftUI

/// Sample-quote extraction, kept separate from the view so it stays trivially testable.
nonisolated enum MeetingAssignSpeakersQuoteSource {
    struct Quote: Equatable, Sendable {
        let segmentID: MeetingTranscriptSegmentID
        let text: String
    }

    private static let maxQuoteLength = 180

    /// First two things a speaker actually said: final, non-echo, in time order.
    static func sampleQuotes(for speakerID: SessionSpeakerID, in segments: [MeetingTranscriptSegment]) -> [String] {
        self.samples(for: speakerID, in: segments).map(\.text)
    }

    /// The same quotes with their segments, so each one can be played.
    static func samples(for speakerID: SessionSpeakerID, in segments: [MeetingTranscriptSegment]) -> [Quote] {
        segments
            .filter { $0.speakerID == speakerID && !$0.isEcho && $0.status == .final }
            .sorted { $0.start.seconds < $1.start.seconds }
            .compactMap { segment -> Quote? in
                let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : Quote(segmentID: segment.id, text: Self.truncated(trimmed))
            }
            .prefix(2)
            .map { $0 }
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > self.maxQuoteLength else { return text }
        let cutoff = text.index(text.startIndex, offsetBy: Self.maxQuoteLength)
        let prefix = text[text.startIndex..<cutoff]
        if let lastSpace = prefix.lastIndex(of: " ") {
            return "\(text[text.startIndex..<lastSpace])…"
        }
        return "\(prefix)…"
    }
}

nonisolated enum MeetingAssignSpeakersValidation {
    /// Only a collision the user just created blocks the save. Two speakers can already share a
    /// name — the pipeline emits a bare "Speaker" for re-matched clusters — and that transcript
    /// must stay nameable rather than deadlocking on a duplicate nobody typed.
    static func duplicateName(
        current: [(id: SessionSpeakerID, displayName: String)],
        drafts: [SessionSpeakerID: String]
    ) -> String? {
        let resulting = current.map { speaker -> (name: String, changed: Bool) in
            let typed = (drafts[speaker.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = typed.isEmpty ? speaker.displayName : typed
            return (name, name != speaker.displayName)
        }
        for index in resulting.indices {
            for other in resulting[(index + 1)...]
                where other.name.caseInsensitiveCompare(resulting[index].name) == .orderedSame
            {
                guard resulting[index].changed || other.changed else { continue }
                return other.name
            }
        }
        return nil
    }
}

struct MeetingAssignSpeakersSheet: View {
    private struct MergeRequest {
        let source: SessionSpeakerID
        let target: SessionSpeakerID
    }

    let speakers: [MeetingSessionSpeaker]
    let quotesBySpeaker: [SessionSpeakerID: [MeetingAssignSpeakersQuoteSource.Quote]]
    let tints: [SessionSpeakerID: Color]
    let accentColor: Color
    let focusedSpeakerID: SessionSpeakerID?
    /// Nil when the meeting's audio cannot be played; quotes then show without play buttons.
    let audioSessionID: MeetingSessionID?
    let onSave: (MeetingSpeakerEdits) async -> String?
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @StateObject private var playback = MeetingSegmentPlayback()
    @StateObject private var voices = MeetingSpeakerVoiceAssistant()
    @State private var edits: MeetingSpeakerEdits
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var pendingMerge: MergeRequest?
    @FocusState private var focusedField: SessionSpeakerID?

    init(
        speakers: [MeetingSessionSpeaker],
        quotesBySpeaker: [SessionSpeakerID: [MeetingAssignSpeakersQuoteSource.Quote]],
        tints: [SessionSpeakerID: Color],
        accentColor: Color,
        focusedSpeakerID: SessionSpeakerID? = nil,
        audioSessionID: MeetingSessionID? = nil,
        onSave: @escaping (MeetingSpeakerEdits) async -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.speakers = speakers
        self.quotesBySpeaker = quotesBySpeaker
        self.tints = tints
        self.accentColor = accentColor
        self.focusedSpeakerID = focusedSpeakerID
        self.audioSessionID = audioSessionID
        self.onSave = onSave
        self.onCancel = onCancel
        self._edits = State(initialValue: MeetingSpeakerEdits(names: Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.displayName) })))
    }

    var body: some View {
        VStack(spacing: 0) {
            self.header

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                        ForEach(self.speakers) { speaker in
                            self.row(for: speaker).id(speaker.id)
                        }
                    }
                    .padding(self.theme.metrics.spacing.xl)
                }
                .onAppear {
                    if let audioSessionID = self.audioSessionID {
                        self.voices.start(sessionID: audioSessionID, speakers: self.speakers)
                    }
                    guard let focusedSpeakerID = self.focusedSpeakerID else { return }
                    proxy.scrollTo(focusedSpeakerID, anchor: .center)
                    self.focusedField = focusedSpeakerID
                }
            }

            if let errorMessage {
                Divider()
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
                    .padding(.horizontal, self.theme.metrics.spacing.xl)
                    .padding(.vertical, self.theme.metrics.spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            FluidGlassControlGroup {
                HStack(spacing: self.theme.metrics.spacing.md) {
                    Button("Cancel", action: self.onCancel)
                        .meetingGlassAction()
                        .keyboardShortcut(.cancelAction)
                        .disabled(self.isSaving)
                    Spacer()
                    Button(self.isSaving ? "Saving…" : "Save changes") { Task { await self.save() } }
                        .meetingGlassAction(prominent: true)
                        .keyboardShortcut(.defaultAction)
                        .disabled(self.isSaving)
                }
            }
            .padding(self.theme.metrics.spacing.lg)
        }
        .onDisappear {
            self.playback.stop()
            self.voices.cancel()
        }
        .frame(minWidth: 480, idealWidth: 560, maxWidth: 560)
        .frame(minHeight: 420, idealHeight: 560)
        .background(self.theme.palette.windowBackground)
        .alert(
            "Merge speakers?",
            isPresented: Binding(
                get: { self.pendingMerge != nil },
                set: { if !$0 { self.pendingMerge = nil } }
            ),
            presenting: self.pendingMerge
        ) { request in
            Button("Cancel", role: .cancel) { self.pendingMerge = nil }
            Button("Confirm merge") {
                self.edits.setMerge(source: request.source, into: request.target)
                self.pendingMerge = nil
            }
        } message: { request in
            Text("All of \(self.speakerName(request.source))’s transcript will belong to \(self.speakerName(request.target)) when you save changes.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text("Edit speakers")
                    .font(self.theme.typography.title)
                Text(self.headerDetail)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            Spacer()
            Button("Close", systemImage: "xmark") { self.onCancel() }
                .labelStyle(.iconOnly)
                .meetingGlassAction(circular: true)
                .disabled(self.isSaving)
                .accessibilityLabel("Close")
        }
        .padding(.horizontal, self.theme.metrics.spacing.xl)
        .padding(.vertical, self.theme.metrics.spacing.lg)
    }

    private var headerDetail: String {
        switch self.voices.status {
        case .listening:
            "Listening for voices you named before…"
        default:
            "Rename voices or merge duplicate speakers. Changes apply when you save."
        }
    }

    @ViewBuilder
    private func row(for speaker: MeetingSessionSpeaker) -> some View {
        let tint = speaker.isLocalUser ? self.accentColor : (self.tints[speaker.id] ?? self.theme.palette.tertiaryText)
        let targets = self.mergeTargets(for: speaker)
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
                Text(speaker.displayName)
                    .font(self.theme.typography.captionSmall)
                    .tracking(1.1)
                    .textCase(.uppercase)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

            let quotes = self.quotesBySpeaker[speaker.id] ?? []
            if quotes.isEmpty {
                Text("No transcript sample")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.tertiaryText)
                    .padding(.leading, self.theme.metrics.spacing.md)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(tint.opacity(0.35)).frame(width: 2)
                    }
            } else {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                    ForEach(Array(quotes.enumerated()), id: \.offset) { _, quote in
                        self.quoteRow(quote, speaker: speaker, tint: tint)
                    }
                }
            }

            if let suggestion = self.pendingSuggestion(for: speaker) {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .foregroundStyle(tint)
                    Text("Sounds like \(suggestion.name)")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.primaryText)
                    Spacer(minLength: 0)
                    Button("Use \(suggestion.name)") { self.edits.names[speaker.id] = suggestion.name }
                        .meetingGlassAction()
                        .disabled(self.isSaving)
                        .help("Fill in \(suggestion.name). Play a quote above to check first.")
                }
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: self.theme.metrics.spacing.md) {
                TextField(
                    speaker.displayName,
                    text: Binding(
                        get: { self.edits.names[speaker.id] ?? speaker.displayName },
                        set: { self.edits.names[speaker.id] = $0 }
                    ),
                    prompt: Text(speaker.displayName)
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .accessibilityLabel("Name for \(speaker.displayName)")
                .focused(self.$focusedField, equals: speaker.id)
                .disabled(self.isSaving || self.edits.merges[speaker.id] != nil)

                if self.edits.merges[speaker.id] == nil, !speaker.isLocalUser, !targets.isEmpty {
                    Menu("Merge…") {
                        ForEach(targets) { target in
                            Button(self.speakerName(target.id)) {
                                self.pendingMerge = MergeRequest(source: speaker.id, target: target.id)
                            }
                        }
                    }
                    .meetingGlassAction()
                    .fixedSize()
                    .disabled(self.isSaving)
                    .accessibilityLabel("Merge \(self.speakerName(speaker.id)) with another speaker")
                }
            }

            if let target = self.edits.merges[speaker.id] {
                HStack(spacing: self.theme.metrics.spacing.md) {
                    Text("Will merge into \(self.speakerName(target))")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Cancel merge") { self.edits.setMerge(source: speaker.id, into: nil) }
                        .meetingGlassAction()
                        .disabled(self.isSaving)
                }
            } else if speaker.isLocalUser || targets.isEmpty {
                Text(speaker.isLocalUser ? "Your microphone voice is kept separate" :
                    (speaker.trackKind == .microphone ? "No other microphone speakers" : "No other meeting-audio speakers"))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.tertiaryText)
            }
        }
    }

    @ViewBuilder
    private func quoteRow(_ quote: MeetingAssignSpeakersQuoteSource.Quote, speaker: MeetingSessionSpeaker, tint: Color) -> some View {
        let isActive = self.playback.activeSegmentID == quote.segmentID
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.sm) {
                if let audioSessionID = self.audioSessionID {
                    Button(isActive ? "Close audio" : "Play", systemImage: isActive ? "xmark" : "play.fill") {
                        if isActive {
                            self.playback.stop()
                        } else {
                            self.playback.toggle(sessionID: audioSessionID, segmentID: quote.segmentID)
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(tint)
                    .help(isActive ? "Close audio player" : "Play this line")
                    .accessibilityLabel(isActive ? "Close audio player" : "Play line by \(self.speakerName(speaker.id))")
                }
                Text(quote.text)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isActive {
                MeetingSegmentAudioPlayer(playback: self.playback, isLoading: self.playback.isLoading)
                    .frame(maxWidth: 360, alignment: .leading)
            }
        }
        .padding(.leading, self.theme.metrics.spacing.md)
        .overlay(alignment: .leading) {
            Rectangle().fill(tint.opacity(0.35)).frame(width: 2)
        }
    }

    /// A suggestion is shown until the user types a real name for that speaker.
    private func pendingSuggestion(for speaker: MeetingSessionSpeaker) -> MeetingSpeakerVoiceSuggestion? {
        guard self.edits.merges[speaker.id] == nil, let suggestion = self.voices.suggestions[speaker.id] else { return nil }
        let typed = self.edits.names[speaker.id] ?? speaker.displayName
        guard MeetingSpeakerVoiceSuggester.isPlaceholderName(typed) else { return nil }
        let usedElsewhere = self.speakers.contains {
            $0.id != speaker.id && self.edits.merges[$0.id] == nil
                && self.speakerName($0.id).caseInsensitiveCompare(suggestion.name) == .orderedSame
        }
        return usedElsewhere ? nil : suggestion
    }

    private func mergeTargets(for speaker: MeetingSessionSpeaker) -> [MeetingSessionSpeaker] {
        self.speakers.filter {
            $0.id != speaker.id && !$0.isLocalUser && $0.trackKind == speaker.trackKind
                && self.edits.merges[$0.id] == nil
        }
    }

    private func speakerName(_ id: SessionSpeakerID) -> String {
        let name = self.edits.names[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? (self.speakers.first { $0.id == id }?.displayName ?? "Speaker") : name
    }

    private func save() async {
        self.errorMessage = nil

        if let duplicate = MeetingAssignSpeakersValidation.duplicateName(
            current: self.speakers.filter { self.edits.merges[$0.id] == nil }.map { (id: $0.id, displayName: $0.displayName) },
            drafts: self.edits.names
        ) {
            self.errorMessage = "Two speakers are both named \"\(duplicate)\". Give them different names, or merge them here."
            return
        }

        self.isSaving = true
        let message = await self.onSave(self.edits)
        self.isSaving = false

        if let message {
            self.errorMessage = message
        } else {
            if let audioSessionID = self.audioSessionID {
                self.voices.learn(sessionID: audioSessionID, edits: self.edits)
            }
            // No separate "dismiss" callback: onCancel is just "close the sheet" either way.
            self.onCancel()
        }
    }
}
