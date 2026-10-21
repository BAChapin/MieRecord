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
    // Added in Milestone 2. Optional so existing stores migrate automatically.
    var diarizationEngineIdentifier: String?
    var diarizationEngineVersion: String?

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegmentRecord.recording)
    var segments: [TranscriptSegmentRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \SpeakerClusterRecord.recording)
    var speakerClusters: [SpeakerClusterRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \SpeakerTurnRecord.recording)
    var speakerTurns: [SpeakerTurnRecord] = []
    // Added in Milestone 3. Voice data is biometric-like and goes with its recording.
    @Relationship(deleteRule: .cascade, inverse: \RecordingVoiceDataRecord.recording)
    var voiceData: [RecordingVoiceDataRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \SpeakerAttributionRecord.recording)
    var speakerAttributions: [SpeakerAttributionRecord] = []

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
    // Added in Milestone 2. Defaults let existing stores migrate automatically.
    /// JSON-encoded `[TimedWord]`; nil when no word timing is known.
    var wordsData: Data?
    var speakerAssignedByUser: Bool = false
    var speakerIsUncertain: Bool = false

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

@Model
final class SpeakerClusterRecord {
    @Attribute(.unique) var id: UUID
    var recordingID: UUID
    var firstAppearance: TimeInterval
    var recording: RecordingRecord?

    init(id: UUID, recordingID: UUID, firstAppearance: TimeInterval) {
        self.id = id
        self.recordingID = recordingID
        self.firstAppearance = firstAppearance
    }
}

@Model
final class SpeakerTurnRecord {
    @Attribute(.unique) var id: UUID
    var recordingID: UUID
    var clusterID: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var isUncertain: Bool
    var recording: RecordingRecord?

    init(id: UUID, recordingID: UUID, clusterID: UUID, startTime: TimeInterval, endTime: TimeInterval, isUncertain: Bool) {
        self.id = id
        self.recordingID = recordingID
        self.clusterID = clusterID
        self.startTime = startTime
        self.endTime = endTime
        self.isUncertain = isUncertain
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
            liveTranscriptionEngine: liveEngineIdentifier.map { EngineDescriptor(identifier: $0, version: liveEngineVersion) },
            diarizationEngine: diarizationEngineIdentifier.map { EngineDescriptor(identifier: $0, version: diarizationEngineVersion) }
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
        diarizationEngineIdentifier = recording.diarizationEngine?.identifier
        diarizationEngineVersion = recording.diarizationEngine?.version
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
        diarizationEngineIdentifier = recording.diarizationEngine?.identifier
        diarizationEngineVersion = recording.diarizationEngine?.version
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
            editedAt: editedAt,
            words: Self.decodeWords(wordsData),
            speakerAssignedByUser: speakerAssignedByUser,
            speakerIsUncertain: speakerIsUncertain
        )
    }

    static func decodeWords(_ data: Data?) -> [TimedWord] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([TimedWord].self, from: data)) ?? []
    }

    static func encodeWords(_ words: [TimedWord]) -> Data? {
        words.isEmpty ? nil : try? JSONEncoder().encode(words)
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
        wordsData = Self.encodeWords(segment.words)
        speakerAssignedByUser = segment.speakerAssignedByUser
        speakerIsUncertain = segment.speakerIsUncertain
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
        wordsData = Self.encodeWords(segment.words)
        speakerAssignedByUser = segment.speakerAssignedByUser
        speakerIsUncertain = segment.speakerIsUncertain
    }
}

extension SpeakerClusterRecord {
    func toDomain() -> SpeakerCluster {
        SpeakerCluster(id: id, recordingID: recordingID, firstAppearance: firstAppearance)
    }
}

extension SpeakerTurnRecord {
    func toDomain() -> SpeakerTurn {
        SpeakerTurn(
            id: id,
            recordingID: recordingID,
            clusterID: clusterID,
            timeRange: TimeRange(start: startTime, end: endTime),
            isUncertain: isUncertain
        )
    }
}
