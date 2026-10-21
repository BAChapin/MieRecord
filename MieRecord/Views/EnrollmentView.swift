import ConversationCore
import ConversationPipeline
import SwiftUI

/// Saves a speaker's voice as a person, or adds it to one, from lines the
/// user approves. Requires explicit consent (SPEC §10: voiceprints are
/// biometric-like data).
struct EnrollmentView: View {
    let viewModel: RecordingDetailViewModel
    let request: EnrollmentRequest

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<UUID> = []
    @State private var consent = false
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var lines: [TranscriptSegment] { viewModel.enrollableLines(for: request.speaker) }
    private var selectedSeconds: Double {
        lines.filter { selected.contains($0.id) }.reduce(0) { $0 + ($1.timeRange?.duration ?? 0) }
    }
    private var minimum: Double { IdentityService.minimumEnrollmentSeconds }
    private var isNew: Bool { request.target == .newPerson }
    private var canSave: Bool {
        consent && selectedSeconds >= minimum && (!isNew || !name.trimmingCharacters(in: .whitespaces).isEmpty) && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(
                        "A voiceprint is a mathematical summary of how someone sounds. It is stored only on this "
                            + "device, is used to suggest names in your recordings, and can be deleted at any time from People."
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if case let .existing(_, personName) = request.target {
                    Section {
                        LabeledContent("Adding to", value: personName)
                    } footer: {
                        Text("More samples from different recordings help recognize \(personName) reliably.")
                    }
                } else {
                    Section("Name") {
                        TextField("Name", text: $name)
                            .textInputAutocapitalization(.words)
                    }
                }

                Section {
                    if lines.isEmpty {
                        Text("This speaker has no lines that are clearly theirs.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(lines) { line in
                        LineToggle(
                            line: line,
                            isOn: Binding(
                                get: { selected.contains(line.id) },
                                set: { isOn in
                                    if isOn { selected.insert(line.id) } else { selected.remove(line.id) }
                                }
                            ),
                            play: { viewModel.playback.play(from: line.timeRange?.start ?? 0) }
                        )
                    }
                } header: {
                    Text("Lines spoken only by this person")
                } footer: {
                    Text("Selected \(Int(selectedSeconds.rounded())) s of at least \(Int(minimum)) s. Leave out lines with other voices, overlapping speech, or loud noise.")
                }

                Section {
                    Toggle("I have this person's permission to save their voiceprint on this device.", isOn: $consent)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isNew ? "Save Voice" : "Add Voice Sample")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.enrollment = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                // Preselect lines long enough to be useful.
                selected = Set(lines.filter { ($0.timeRange?.duration ?? 0) >= 1.5 }.map(\.id))
            }
            .onDisappear { viewModel.playback.pause() }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        errorMessage = await viewModel.enroll(
            request,
            name: name,
            lines: lines.filter { selected.contains($0.id) },
            consent: consent
        )
    }
}

private struct LineToggle: View {
    let line: TranscriptSegment
    @Binding var isOn: Bool
    let play: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: play) {
                Image(systemName: "play.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Play this line")
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.text)
                        .font(.subheadline)
                        .lineLimit(3)
                    if let range = line.timeRange {
                        Text("\(Formatters.duration(range.start)) · \(String(format: "%.1f", range.duration)) s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
