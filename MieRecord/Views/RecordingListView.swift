import ConversationCore
import SwiftUI

struct RecordingListView: View {
    @Environment(AppDependencies.self) private var dependencies
    @State private var viewModel: RecordingListViewModel?
    @State private var isRecording = false

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    content(viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Recordings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isRecording = true
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                }
            }
        }
        .task {
            if viewModel == nil {
                viewModel = RecordingListViewModel(dependencies: dependencies)
            }
            await viewModel?.load()
        }
        .fullScreenCover(isPresented: $isRecording) {
            RecordingView()
                .environment(dependencies)
        }
        .onChange(of: isRecording) { _, presented in
            if !presented {
                Task { await viewModel?.load() }
            }
        }
        .onChange(of: dependencies.transcriptionJobs.revision) { _, _ in
            Task { await viewModel?.load() }
        }
    }

    @ViewBuilder
    private func content(_ viewModel: RecordingListViewModel) -> some View {
        if viewModel.recordings.isEmpty, !viewModel.isLoading {
            ContentUnavailableView {
                Label("No Recordings", systemImage: "waveform")
            } description: {
                Text("Tap Record to capture a conversation. Everything stays on this device.")
            } actions: {
                Button("Record") { isRecording = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                if let startupError = dependencies.startupError {
                    Section {
                        Label(startupError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if let error = viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    ForEach(viewModel.recordings) { recording in
                        NavigationLink(value: recording) {
                            RecordingRow(
                                recording: recording,
                                isTranscribing: dependencies.transcriptionJobs.isRunning(recording.id)
                            )
                        }
                    }
                    .onDelete { offsets in
                        Task { await viewModel.delete(at: offsets) }
                    }
                }
            }
            .navigationDestination(for: Recording.self) { recording in
                RecordingDetailView(recording: recording)
            }
            .refreshable { await viewModel.load() }
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording
    let isTranscribing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(recording.createdAt, format: .dateTime.month().day().hour().minute())
                Text("·")
                Text(Formatters.duration(recording.duration))
                if recording.recordingState == .interrupted {
                    Text("·")
                    Label("Interrupted", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                if isTranscribing {
                    Text("·")
                    Label("Transcribing", systemImage: "waveform.badge.magnifyingglass")
                        .foregroundStyle(.tint)
                } else if case .failed = recording.processingState {
                    Text("·")
                    Label("Transcription failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
