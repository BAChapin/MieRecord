import ConversationCore
import Foundation
import Observation

@Observable
final class RecordingListViewModel {
    private(set) var recordings: [Recording] = []
    private(set) var isLoading = false
    var errorMessage: String?

    private let dependencies: AppDependencies
    private var didRecover = false

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        if !didRecover {
            didRecover = true
            await dependencies.recoverInterruptedRecordings()
        }
        do {
            recordings = try await dependencies.repository.allRecordings()
        } catch {
            errorMessage = "Could not load recordings: \(error.localizedDescription)"
        }
    }

    func delete(at offsets: IndexSet) async {
        let targets = offsets.map { recordings[$0] }
        for recording in targets {
            do {
                try await dependencies.deleteRecording(recording)
            } catch {
                errorMessage = "Could not delete \"\(recording.title)\": \(error.localizedDescription)"
            }
        }
        await load()
    }
}
