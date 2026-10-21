import ConversationCore
import ConversationPipeline
import SwiftUI

/// Live recording screen: elapsed time, transcription status, and the evolving
/// unlabeled transcript. Speaker identity is intentionally absent (SPEC §4).
struct RecordingView: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: RecordingViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    content(viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let viewModel, !viewModel.phase.isActive, viewModel.phase != .stopping {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled()
        }
        .task {
            let viewModel = RecordingViewModel(dependencies: dependencies)
            self.viewModel = viewModel
            await viewModel.start()
        }
    }

    @ViewBuilder
    private func content(_ viewModel: RecordingViewModel) -> some View {
        VStack(spacing: 16) {
            header(viewModel)
            TranscriptionStatusView(status: viewModel.transcriptionStatus)
            LiveTranscriptView(transcript: viewModel.transcript)
            footer(viewModel)
        }
        .padding()
    }

    private func header(_ viewModel: RecordingViewModel) -> some View {
        VStack(spacing: 6) {
            Text(Formatters.duration(viewModel.elapsed))
                .font(.system(size: 44, weight: .light, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            HStack(spacing: 6) {
                Circle()
                    .fill(indicatorColor(viewModel.phase))
                    .frame(width: 10, height: 10)
                Text(phaseText(viewModel.phase))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func footer(_ viewModel: RecordingViewModel) -> some View {
        switch viewModel.phase {
        case .idle, .requestingPermission, .starting:
            ProgressView("Starting…")
        case .recording, .interrupted:
            Button {
                Task { await viewModel.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        case .stopping:
            ProgressView("Finishing…")
        case .finished:
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .onAppear { dismiss() }
        case .permissionDenied:
            VStack(spacing: 12) {
                Label("Microphone access is required to record.", systemImage: "mic.slash")
                    .foregroundStyle(.secondary)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: url)
                }
            }
        case let .failed(reason):
            VStack(spacing: 12) {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Stop and Keep Audio") {
                    Task { await viewModel.stop() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func phaseText(_ phase: RecordingViewModel.Phase) -> String {
        switch phase {
        case .idle, .starting: "Starting"
        case .requestingPermission: "Requesting microphone access"
        case .permissionDenied: "Microphone access denied"
        case .recording: "Recording"
        case .interrupted: "Paused by the system"
        case .stopping: "Finishing"
        case .finished: "Saved"
        case .failed: "Recording problem"
        }
    }

    private func indicatorColor(_ phase: RecordingViewModel.Phase) -> Color {
        switch phase {
        case .recording: .red
        case .interrupted: .orange
        case .failed, .permissionDenied: .red.opacity(0.5)
        default: .gray
        }
    }
}

private struct TranscriptionStatusView: View {
    let status: LiveTranscriptionStatus

    var body: some View {
        if let text {
            Label(text, systemImage: icon)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var text: String? {
        switch status {
        case .notConfigured: "Live transcription is off. Audio is still recorded."
        case .preparing: "Preparing on-device transcription…"
        case .active: nil
        case let .unavailable(reason): "Live transcription unavailable: \(reason) Audio is still recorded."
        case let .failed(reason): "Live transcription stopped: \(reason) Audio is still recorded."
        case .finished: nil
        }
    }

    private var icon: String {
        switch status {
        case .preparing: "hourglass"
        case .unavailable, .failed: "text.badge.xmark"
        default: "text.bubble"
        }
    }
}

/// Finalized text in the primary color, the provisional hypothesis dimmed.
private struct LiveTranscriptView: View {
    let transcript: LiveTranscript

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if transcript.finalizedSegments.isEmpty, transcript.volatileText.isEmpty {
                        Text("Listening…")
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(transcript.finalizedSegments) { segment in
                        Text(segment.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !transcript.volatileText.isEmpty {
                        Text(transcript.volatileText)
                            .italic()
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
                .textSelection(.enabled)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: transcript) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .accessibilityLabel("Live transcript")
    }
}
