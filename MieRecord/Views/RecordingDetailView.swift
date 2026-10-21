import ConversationCore
import ConversationPipeline
import SwiftUI

/// A saved recording: playback, processing status, and the speaker-attributed
/// transcript. Tapping text plays from there; tapping a speaker label opens
/// corrections for that line or that whole speaker.
struct RecordingDetailView: View {
    @Environment(AppDependencies.self) private var dependencies
    @State private var viewModel: RecordingDetailViewModel?
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var pendingConfirmation: PendingAction?
    let recording: Recording

    /// Actions that replace data and therefore ask first.
    enum PendingAction: Identifiable {
        case retranscribe
        case identifyAgain
        var id: Self { self }
    }

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(viewModel?.recording.title ?? recording.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { actionsMenu }
        }
        .alert("Rename Recording", isPresented: $isRenaming) {
            TextField("Title", text: $draftTitle)
            Button("Save") { Task { await viewModel?.rename(to: draftTitle) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { pendingConfirmation != nil }, set: { if !$0 { pendingConfirmation = nil } }),
            titleVisibility: .visible,
            presenting: pendingConfirmation
        ) { action in
            switch action {
            case .retranscribe:
                Button("Re-transcribe") { viewModel?.retranscribe() }
            case .identifyAgain:
                Button("Identify Speakers Again") { viewModel?.identifySpeakers(fresh: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(confirmationMessage(action))
        }
        .task {
            if viewModel == nil {
                viewModel = RecordingDetailViewModel(recording: recording, dependencies: dependencies)
            }
            await viewModel?.load()
        }
        .onChange(of: dependencies.processingJobs.revision) { _, _ in
            Task { await viewModel?.reloadTranscript() }
        }
        .sheet(item: Binding(get: { viewModel?.enrollment }, set: { viewModel?.enrollment = $0 })) { request in
            if let viewModel {
                EnrollmentView(viewModel: viewModel, request: request)
            }
        }
        .onDisappear { viewModel?.unload() }
    }

    private var actionsMenu: some View {
        Menu {
            Button {
                draftTitle = viewModel?.recording.title ?? recording.title
                isRenaming = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            if viewModel?.canIdentifySpeakers == true {
                Button {
                    if viewModel?.hasSpeakers == true {
                        pendingConfirmation = .identifyAgain
                    } else {
                        viewModel?.identifySpeakers(fresh: false)
                    }
                } label: {
                    Label(viewModel?.hasSpeakers == true ? "Identify Speakers Again" : "Identify Speakers",
                          systemImage: "person.2.wave.2")
                }
                .disabled(viewModel?.isBusy ?? true)
            }
            Button {
                if viewModel?.segments.isEmpty == true {
                    viewModel?.retranscribe()
                } else {
                    pendingConfirmation = .retranscribe
                }
            } label: {
                Label("Re-transcribe", systemImage: "text.badge.checkmark")
            }
            .disabled(viewModel?.isBusy ?? true)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .retranscribe?: "Re-transcribe this recording?"
        case .identifyAgain?: "Identify speakers again?"
        case nil: ""
        }
    }

    private func confirmationMessage(_ action: PendingAction) -> String {
        let corrections = viewModel?.hasCorrections == true
            ? " Your speaker corrections will be replaced." : ""
        switch action {
        case .retranscribe:
            let edits = viewModel?.hasTextOrSpeakerEdits == true ? " Your corrections will be replaced." : ""
            return "The transcript will be rebuilt on this device from the saved audio and will replace the current text. The audio is not changed. If it fails, the current transcript is kept." + edits
        case .identifyAgain:
            return "Speakers will be detected again from the saved audio and the labels may change." + corrections
        }
    }

    private func content(_ viewModel: RecordingDetailViewModel) -> some View {
        VStack(spacing: 0) {
            PlaybackBar(playback: viewModel.playback)
                .padding()
            Divider()
            TranscriptList(viewModel: viewModel)
        }
    }
}

// MARK: - Playback

private struct PlaybackBar: View {
    @Bindable var playback: AudioPlaybackController

    var body: some View {
        VStack(spacing: 8) {
            if let error = playback.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 16) {
                Button {
                    playback.togglePlayback()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .disabled(playback.duration == 0)
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                Slider(
                    value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
                    in: 0...max(playback.duration, 0.01)
                )
                .disabled(playback.duration == 0)

                Text("\(Formatters.duration(playback.currentTime)) / \(Formatters.duration(playback.duration))")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Transcript

private struct TranscriptList: View {
    let viewModel: RecordingDetailViewModel

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            Section { metadata }
            ProcessingStatusSection(viewModel: viewModel)
            Section {
                if viewModel.segments.isEmpty {
                    Text("No transcript was captured for this recording.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(viewModel.segments.enumerated()), id: \.element.id) { offset, segment in
                        SegmentRow(
                            viewModel: viewModel,
                            segment: segment,
                            showsSpeaker: showsSpeaker(at: offset),
                            isCurrent: segment.id == viewModel.currentSegmentID
                        )
                    }
                }
            } header: {
                Text("Transcript")
            } footer: {
                if viewModel.hasSpeakers {
                    Text("Tap a speaker label to correct it. Speaker numbers apply to this recording only.")
                } else if !viewModel.canIdentifySpeakers {
                    Text("Speaker detection is not available in this build.")
                }
            }
        }
        .listStyle(.plain)
    }

    /// Show the label when the speaker changes, and always on lines that need review.
    private func showsSpeaker(at offset: Int) -> Bool {
        guard viewModel.hasSpeakers else { return false }
        let segment = viewModel.segments[offset]
        if segment.speakerIsUncertain || segment.speakerClusterID == nil || offset == 0 { return true }
        let previous = viewModel.segments[offset - 1]
        return previous.speakerClusterID != segment.speakerClusterID || previous.speakerIsUncertain
    }

    @ViewBuilder
    private var metadata: some View {
        let recording = viewModel.recording
        LabeledContent("Recorded", value: recording.createdAt.formatted(date: .abbreviated, time: .shortened))
        LabeledContent("Duration", value: Formatters.duration(recording.duration))
        if viewModel.hasSpeakers {
            LabeledContent("Speakers", value: "\(viewModel.speakers.count)")
        }
        if recording.recordingState == .interrupted {
            Label("This recording was interrupted. The audio captured before the interruption is intact.", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
                .font(.footnote)
        }
    }
}

/// Running job progress, a review prompt, or the last failure with a retry.
private struct ProcessingStatusSection: View {
    let viewModel: RecordingDetailViewModel

    var body: some View {
        if let status = viewModel.jobStatus {
            Section {
                HStack(spacing: 12) {
                    if let fraction = status.fraction, fraction > 0 {
                        ProgressView(value: fraction)
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        Spacer()
                    }
                    Button("Cancel", role: .cancel) { viewModel.cancelJob() }
                        .buttonStyle(.borderless)
                }
            } header: {
                Text(status.description)
            }
        } else if let failure = viewModel.failureMessage {
            Section {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Try Again") { viewModel.retryLastJob() }
            } header: {
                Text("Processing failed")
            }
        } else if viewModel.reviewCount > 0 {
            Section {
                if viewModel.verificationCount > 0 {
                    Label(
                        "\(viewModel.verificationCount) name\(viewModel.verificationCount == 1 ? " was" : "s were") suggested from voice similarity. Tap a name marked with a checkmark badge to confirm or reject it.",
                        systemImage: "person.badge.clock"
                    )
                }
                if viewModel.reviewLineCount > 0 {
                    Label(
                        "\(viewModel.reviewLineCount) line\(viewModel.reviewLineCount == 1 ? "" : "s") may have the wrong speaker or overlapping speech. Tap the marked labels to confirm or fix them.",
                        systemImage: "questionmark.circle"
                    )
                }
            } header: {
                Text("Needs review")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else if !viewModel.hasSpeakers, viewModel.canIdentifySpeakers, !viewModel.segments.isEmpty {
            Section {
                Button {
                    viewModel.identifySpeakers(fresh: false)
                } label: {
                    Label("Identify Speakers", systemImage: "person.2.wave.2")
                }
            } footer: {
                Text("Detects who spoke when, on this device. Nothing is uploaded.")
            }
        }
    }
}

private struct SegmentRow: View {
    let viewModel: RecordingDetailViewModel
    let segment: TranscriptSegment
    let showsSpeaker: Bool
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsSpeaker {
                SpeakerChip(viewModel: viewModel, segment: segment)
            }
            HStack(spacing: 6) {
                if let range = segment.timeRange {
                    Text(Formatters.duration(range.start))
                        .monospacedDigit()
                }
                if !segment.isFinal {
                    Text("provisional")
                        .italic()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(segment.text)
                .foregroundStyle(segment.isFinal ? .primary : .secondary)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let start = segment.timeRange?.start {
                        viewModel.playback.play(from: start)
                    }
                }
        }
        .padding(.vertical, 2)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : nil)
    }
}

/// Speaker label with a menu of corrections for this line or this speaker.
private struct SpeakerChip: View {
    let viewModel: RecordingDetailViewModel
    let segment: TranscriptSegment

    private var speaker: SpeakerOption? { viewModel.speaker(for: segment) }
    private var lineNeedsReview: Bool { segment.speakerIsUncertain || segment.speakerClusterID == nil }

    var body: some View {
        Menu {
            if let speaker, let person = speaker.person, speaker.needsVerification {
                Section("Suggested from voice similarity") {
                    Button {
                        Task { await viewModel.confirmIdentity(speaker) }
                    } label: {
                        Label("Yes, This Is \(person.name)", systemImage: "checkmark.circle")
                    }
                    Button {
                        Task { await viewModel.rejectIdentity(speaker) }
                    } label: {
                        Label("Not \(person.name)", systemImage: "xmark.circle")
                    }
                }
            }
            lineSection
            if let speaker {
                speakerSection(speaker)
            }
        } label: {
            chipLabel
        }
        .disabled(viewModel.isBusy)
        .accessibilityHint("Shows options to correct the speaker")
    }

    @ViewBuilder
    private var lineSection: some View {
        Section("This line") {
            if lineNeedsReview, let speaker {
                Button {
                    Task { await viewModel.confirm(segment) }
                } label: {
                    Label("Confirm \(speaker.label) Said This", systemImage: "checkmark")
                }
            }
            Menu("Move This Line To…") {
                ForEach(viewModel.speakers.filter { $0.id != speaker?.id }) { option in
                    Button(option.label) { Task { await viewModel.move(segment, to: option) } }
                }
                Button {
                    Task { await viewModel.moveToNewSpeaker(segment) }
                } label: {
                    Label("New Speaker", systemImage: "person.badge.plus")
                }
            }
        }
    }

    @ViewBuilder
    private func speakerSection(_ speaker: SpeakerOption) -> some View {
        Section("All lines from \(speaker.label)") {
            let others = viewModel.people.filter { $0.id != speaker.person?.profileID }
            if !others.isEmpty {
                Menu("This Is…") {
                    ForEach(others) { person in
                        Button(person.displayName) { Task { await viewModel.assign(speaker, to: person) } }
                    }
                }
            }
            if speaker.hasVoiceprint {
                if let person = speaker.person, !speaker.needsVerification {
                    Button {
                        viewModel.startEnrollment(speaker, target: .existing(profileID: person.profileID, name: person.name))
                    } label: {
                        Label("Add This Voice to \(person.name)…", systemImage: "waveform.badge.plus")
                    }
                } else if speaker.person == nil {
                    Button {
                        viewModel.startEnrollment(speaker, target: .newPerson)
                    } label: {
                        Label("Save Voice as New Person…", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
            if let person = speaker.person {
                if person.isUserConfirmed {
                    Button {
                        Task { await viewModel.clearIdentity(speaker) }
                    } label: {
                        Label("Remove Name", systemImage: "person.crop.circle.badge.minus")
                    }
                } else if !speaker.needsVerification {
                    Button {
                        Task { await viewModel.rejectIdentity(speaker) }
                    } label: {
                        Label("Not \(person.name)", systemImage: "xmark.circle")
                    }
                }
            } else if !viewModel.people.isEmpty {
                Button {
                    Task { await viewModel.keepUnidentified(speaker) }
                } label: {
                    Label("Not Anyone Saved", systemImage: "person.fill.questionmark")
                }
            }
            if viewModel.speakers.count > 1 {
                Menu("Same Person As…") {
                    ForEach(viewModel.speakers.filter { $0.id != speaker.id }) { target in
                        Button(target.label) { Task { await viewModel.merge(speaker, into: target) } }
                    }
                }
            }
        }
    }

    private var chipLabel: some View {
        let color = speaker.map { SpeakerStyle.color(forIndex: $0.index) } ?? .gray
        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            if speaker?.person != nil {
                Image(systemName: "person.fill")
                    .font(.caption2)
                    .foregroundStyle(color)
            }
            Text(speaker?.label ?? "Unassigned")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(speaker == nil ? .secondary : color)
            if speaker?.needsVerification == true {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Suggested name, needs verification")
            }
            if lineNeedsReview {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Line needs review")
            }
        }
    }
}
