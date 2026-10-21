import ConversationCore
import ConversationPipeline
import SwiftUI

/// The persistent voice library: people saved explicitly from recordings.
struct PeopleView: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State private var summaries: [ProfileSummary] = []
    @State private var calibration: CalibrationStatus?
    @State private var errorMessage: String?
    @State private var isConfirmingDeleteAll = false

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if summaries.isEmpty {
                    ContentUnavailableView {
                        Label("No People Saved", systemImage: "person.2")
                    } description: {
                        Text("In a recording, tap a speaker label and choose Save Voice as New Person. Nobody is ever saved automatically.")
                    }
                } else {
                    Section {
                        ForEach(summaries) { summary in
                            NavigationLink(value: summary.id) {
                                PersonRow(summary: summary)
                            }
                        }
                    }
                }
                if let calibration {
                    Section {
                        Text(matchingDescription(calibration))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("How names are suggested")
                    }
                }
                if !summaries.isEmpty {
                    Section {
                        Button("Delete All Voice Data", role: .destructive) { isConfirmingDeleteAll = true }
                    }
                }
            }
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                PersonDetailView(profileID: id, onChange: { Task { await load() } })
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete all voice data?", isPresented: $isConfirmingDeleteAll, titleVisibility: .visible) {
                Button("Delete All People", role: .destructive) {
                    Task {
                        do {
                            try await dependencies.identity.deleteAllProfiles()
                            dependencies.processingJobs.noteDataChanged()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                        await load()
                    }
                }
            } message: {
                Text("Every saved person and voiceprint is deleted. Recordings keep their audio and text; named speakers become numbered speakers again.")
            }
            .task { await load() }
        }
    }

    private func load() async {
        do {
            summaries = try await dependencies.identity.profileSummaries()
            calibration = try await dependencies.identity.calibrationStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func matchingDescription(_ status: CalibrationStatus) -> String {
        if status.isCalibrated {
            return "Names are suggested using calibrated confidence. Names marked with a checkmark badge are less certain and ask you to verify."
        }
        return "Names are suggested from voice similarity with conservative trial thresholds. These scores are not probabilities, so no percentages are shown. Less certain suggestions are marked for you to verify. Your confirmations and rejections are saved on this device to calibrate matching later (\(status.confirmedMatches) confirmed and \(status.rejectedMatches) rejected so far; \(status.requiredPerClass) of each are needed)."
    }
}

private struct PersonRow: View {
    let summary: ProfileSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.profile.displayName)
                .font(.headline)
            Text("\(summary.samples.count) sample\(summary.samples.count == 1 ? "" : "s") · \(Int(summary.enrolledSeconds.rounded())) s of speech · in \(summary.recordingCount) recording\(summary.recordingCount == 1 ? "" : "s")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if summary.compatibleSampleCount == 0 {
                Label("Needs a new voice sample for the current speaker model.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// One person: rename, review and delete samples, or delete the person.
private struct PersonDetailView: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    let profileID: UUID
    let onChange: () -> Void

    @State private var summary: ProfileSummary?
    @State private var name = ""
    @State private var recordingTitles: [UUID: String] = [:]
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            Section("Name") {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .onSubmit { Task { await rename() } }
            }
            if let summary {
                Section {
                    ForEach(summary.samples) { sample in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sample.sourceRecordingID.flatMap { recordingTitles[$0] } ?? "Deleted recording")
                            Text("\(sample.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(Int(sample.speechSeconds.rounded())) s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { summary.samples[$0].id }
                        Task {
                            for id in ids {
                                do { try await dependencies.identity.deleteSample(id: id) } catch { errorMessage = error.localizedDescription }
                            }
                            dependencies.processingJobs.noteDataChanged()
                            await load()
                            onChange()
                        }
                    }
                } header: {
                    Text("Voice samples")
                } footer: {
                    Text("Each sample came from lines you approved. Samples don't depend on the recording; deleting the recording keeps them.")
                }
            }
            Section {
                Button("Delete Person", role: .destructive) { isConfirmingDelete = true }
            } footer: {
                Text("Deleting removes this person's voiceprints. Recordings where they were named keep their audio and text, and show a numbered speaker instead.")
            }
        }
        .navigationTitle(summary?.profile.displayName ?? "Person")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete \(summary?.profile.displayName ?? "this person")?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await dependencies.identity.deleteProfile(id: profileID)
                        dependencies.processingJobs.noteDataChanged()
                        onChange()
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
        .task { await load() }
        .onDisappear { Task { await rename() } }
    }

    private func load() async {
        do {
            summary = try await dependencies.identity.profileSummaries().first { $0.id == profileID }
            if name.isEmpty { name = summary?.profile.displayName ?? "" }
            recordingTitles = Dictionary(try await dependencies.repository.allRecordings().map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rename() async {
        guard let summary, name.trimmingCharacters(in: .whitespaces) != summary.profile.displayName,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try await dependencies.identity.rename(profileID: profileID, to: name)
            dependencies.processingJobs.noteDataChanged()
            onChange()
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
