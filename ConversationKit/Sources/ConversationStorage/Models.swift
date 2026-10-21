import ConversationCore
import Foundation
import SwiftData

// SwiftData models are an implementation detail of ConversationStorage. The
// rest of the system works with the value types in ConversationCore, which the
// repository maps to and from these records.

@Model
final class RecordingRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var audioFileName: String
    var sampleRate: Double
    var channelCount: Int
    var recordingStateRaw: String
    /// JSON-encoded `ProcessingState`; stored opaquely so associated values and
    /// future cases never require a schema migration.
    var processingStateData: Data
    var liveEngineIdentifier: String?
    var liveEngineVersion: String?

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegmentRecord.recording)
    var segments: [TranscriptSegmentRecord] = []

    init(
        id: UUID,
        title: String,
        createdAt: Date,
        duration: TimeInterval,
        audioFileName: String,
        sampleRate: Double,
        channelCount: Int,
        recordingStateRaw: String,
        processingStateData: Data,
        liveEngineIdentifier: String?,
        liveEngineVersion: String?
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.recordingStateRaw = recordingStateRaw
        self.processingStateData = processingStateData
        self.liveEngineIdentifier = liveEngineIdentifier
        self.liveEngineVersion = liveEngineVersion
    }
}

@Model
final class TranscriptSegmentRecord {
    @Attribute(.unique) var id: UUID
    var recordingID: UUID
    var startTime: TimeInterval?
    var endTime: TimeInterval?
    var text: String
    var isFinal: Bool
    var sourceIdentifier: String
    var sourceVersion: String?
    var speakerClusterID: UUID?
    var transcriptionConfidence: Double?
    var editedAt: Date?
    /// Insertion order, used to keep untimed segments in arrival order.
    var orderIndex: Int

    var recording: RecordingRecord?

    init(
        id: UUID,
        recordingID: UUID,
        startTime: TimeInterval?,
        endTime: TimeInterval?,
        text: String,
        isFinal: Bool,
        sourceIdentifier: String,
        sourceVersion: String?,
        speakerClusterID: UUID?,
        transcriptionConfidence: Double?,
        editedAt: Date?,
        orderIndex: Int
    ) {
        self.id = id
        self.recordingID = recordingID
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.isFinal = isFinal
        self.sourceIdentifier = sourceIdentifier
        self.sourceVersion = sourceVersion
        self.speakerClusterID = speakerClusterID
        self.transcriptionConfidence = transcriptionConfidence
        self.editedAt = editedAt
        self.orderIndex = orderIndex
    }
}

// MARK: - Mapping

extension RecordingRecord {
    func toDomain() -> Recording {
        Recording(
            id: id,
            title: title,
            createdAt: createdAt,
            duration: duration,
            audioFile: AudioFileReference(fileName: audioFileName, sampleRate: sampleRate, channelCount: channelCount),
            recordingState: RecordingState(rawValue: recordingStateRaw) ?? .interrupted,
            processingState: (try? JSONDecoder().decode(ProcessingState.self, from: processingStateData)) ?? .notStarted,
            liveTranscriptionEngine: liveEngineIdentifier.map { EngineDescriptor(identifier: $0, version: liveEngineVersion) }
        )
    }

    func update(from recording: Recording) throws {
        title = recording.title
        createdAt = recording.createdAt
        duration = recording.duration
        audioFileName = recording.audioFile.fileName
        sampleRate = recording.audioFile.sampleRate
        channelCount = recording.audioFile.channelCount
        recordingStateRaw = recording.recordingState.rawValue
        processingStateData = try Self.encode(recording.processingState)
        liveEngineIdentifier = recording.liveTranscriptionEngine?.identifier
        liveEngineVersion = recording.liveTranscriptionEngine?.version
    }

    static func encode(_ state: ProcessingState) throws -> Data {
        do {
            return try JSONEncoder().encode(state)
        } catch {
            throw StorageError.encodingFailed(error.localizedDescription)
        }
    }

    convenience init(from recording: Recording) throws {
        self.init(
            id: recording.id,
            title: recording.title,
            createdAt: recording.createdAt,
            duration: recording.duration,
            audioFileName: recording.audioFile.fileName,
            sampleRate: recording.audioFile.sampleRate,
            channelCount: recording.audioFile.channelCount,
            recordingStateRaw: recording.recordingState.rawValue,
            processingStateData: try Self.encode(recording.processingState),
            liveEngineIdentifier: recording.liveTranscriptionEngine?.identifier,
            liveEngineVersion: recording.liveTranscriptionEngine?.version
        )
    }
}

extension TranscriptSegmentRecord {
    func toDomain() -> TranscriptSegment {
        var range: TimeRange?
        if let startTime, let endTime {
            range = TimeRange(start: startTime, end: endTime)
        }
        return TranscriptSegment(
            id: id,
            recordingID: recordingID,
            timeRange: range,
            text: text,
            isFinal: isFinal,
            source: EngineDescriptor(identifier: sourceIdentifier, version: sourceVersion),
            speakerClusterID: speakerClusterID,
            transcriptionConfidence: transcriptionConfidence,
            editedAt: editedAt
        )
    }

    func update(from segment: TranscriptSegment) {
        recordingID = segment.recordingID
        startTime = segment.timeRange?.start
        endTime = segment.timeRange?.end
        text = segment.text
        isFinal = segment.isFinal
        sourceIdentifier = segment.source.identifier
        sourceVersion = segment.source.version
        speakerClusterID = segment.speakerClusterID
        transcriptionConfidence = segment.transcriptionConfidence
        editedAt = segment.editedAt
    }

    convenience init(from segment: TranscriptSegment, orderIndex: Int) {
        self.init(
            id: segment.id,
            recordingID: segment.recordingID,
            startTime: segment.timeRange?.start,
            endTime: segment.timeRange?.end,
            text: segment.text,
            isFinal: segment.isFinal,
            sourceIdentifier: segment.source.identifier,
            sourceVersion: segment.source.version,
            speakerClusterID: segment.speakerClusterID,
            transcriptionConfidence: segment.transcriptionConfidence,
            editedAt: segment.editedAt,
            orderIndex: orderIndex
        )
    }
}
