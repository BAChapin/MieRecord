import ConversationCore
import SwiftUI

/// Shows a saved recording: playback, metadata, and the transcript. Tapping a
/// segment plays from its start; the segment under the playhead is highlighted.
struct RecordingDetailView: View {
    @Environment(AppDependencies.self) private var dependencies
    @State private var viewModel: RecordingDetailViewModel?
    @State private var isRenaming = false
    @State private var isConfirmingRetranscribe = false
    @State private var draftTitle = ""
    let recording: Recording

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
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        draftTitle = viewModel?.recording.title ?? recording.title
                        isRenaming = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        if viewModel?.segments.isEmpty == true {
                            viewModel?.retranscribe()
                        } else {
                            isConfirmingRetranscribe = true
                        }
                    } label: {
                        Label("Re-transcribe", systemImage: "text.badge.checkmark")
                    }
                    .disabled(viewModel?.isRetranscribing ?? true)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Re-transcribe this recording?",
            isPresented: $isConfirmingRetranscribe,
            titleVisibility: .visible
        ) {
            Button("Re-transcribe") { viewModel?.retranscribe() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript will be rebuilt on this device from the saved audio and will replace the current text. The audio is not changed. If it fails, the current transcript is kept.")
        }
        .onChange(of: dependencies.transcriptionJobs.revision) { _, _ in
            Task { await viewModel?.reloadTranscript() }
        }
        .alert("Rename Recording", isPresented: $isRenaming) {
            TextField("Title", text: $draftTitle)
            Button("Save") { Task { await viewModel?.rename(to: draftTitle) } }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            if viewModel == nil {
                viewModel = RecordingDetailViewModel(recording: recording, dependencies: dependencies)
            }
            await viewModel?.load()
        }
        .onDisappear { viewModel?.unload() }
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
                    value: Binding(
                        get: { playback.currentTime },
                        set: { playback.seek(to: $0) }
                    ),
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

private struct TranscriptList: View {
    let viewModel: RecordingDetailViewModel

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            Section {
                metadata
            }
            RetranscriptionStatusSection(viewModel: viewModel)
            Section {
                if viewModel.segments.isEmpty {
                    Text("No transcript was captured for this recording.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.segments) { segment in
                        SegmentRow(
                            segment: segment,
                            isCurrent: segment.id == viewModel.currentSegmentID
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let start = segment.timeRange?.start {
                                viewModel.playback.play(from: start)
                            }
                        }
                    }
                }
            } header: {
                Text("Transcript")
            } footer: {
                Text("Speaker labels appear after post-recording processing, which is not available yet.")
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var metadata: some View {
        let recording = viewModel.recording
        LabeledContent("Recorded", value: recording.createdAt.formatted(date: .abbreviated, time: .shortened))
        LabeledContent("Duration", value: Formatters.duration(recording.duration))
        if recording.recordingState == .interrupted {
            Label("This recording was interrupted. The audio captured before the interruption is intact.", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
                .font(.footnote)
        }
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        }
        .padding(.vertical, 2)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : nil)
        .accessibilityElement(children: .combine)
    }
}

/// Progress while re-transcribing, or the last failure with a retry button.
private struct RetranscriptionStatusSection: View {
    let viewModel: RecordingDetailViewModel

    var body: some View {
        if viewModel.isRetranscribing {
            Section {
                HStack(spacing: 12) {
                    if let progress = viewModel.retranscriptionProgress, progress > 0 {
                        ProgressView(value: progress)
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        Text("Preparing…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Button("Cancel", role: .cancel) { viewModel.cancelRetranscription() }
                        .buttonStyle(.borderless)
                }
            } header: {
                Text("Re-transcribing")
            }
        } else if let error = viewModel.retranscriptionError {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Try Again") { viewModel.retranscribe() }
            } header: {
                Text("Re-transcription failed")
            }
        }
    }
}
