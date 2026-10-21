# MieRecord — Product & Technical Specification

**Status:** Draft v0.1  
**Date:** 2026-10-20  
**Target platform:** iOS (modern iPhone; initial development target iPhone 15 Pro Max)  
**Implementation:** Native Swift / SwiftUI, offline-first  
**Working name:** MieRecord

## 1. Executive Summary

Build a privacy-focused, entirely on-device conversation recording and transcription application. During recording, users see a near-real-time **unlabeled** transcript. After stopping, the app processes the saved recording to identify distinct speakers, match them to deliberately enrolled voice profiles, and produce a speaker-labeled, editable transcript. Unknown speakers are numbered **per recording**, without automatically creating persistent profiles.

The core product performs **no AI summarization**. Instead, it offers structured exports and, in a later phase, secure access for user-selected external AI tools and MCP clients.

## 2. Goals

1. Capture and retain high-quality conversation audio locally.
2. Present a responsive, plain-text live transcript during recording.
3. Produce a speaker-attributed transcript after recording using on-device inference.
4. Recognize recurring speakers from **opt-in, persistent voice profiles**.
5. Surface uncertain matches for verification and allow users to correct all assignments.
6. Support interrupted/resumable processing where practical and never lose the source audio due to inference failure.
7. Provide portable, timestamped transcript exports and a clean extensible architecture.
8. Perform the recording, transcription, diarization, and speaker recognition without requiring an internet connection.

## 3. Non-Goals (MVP)

- Real-time speaker labeling while recording.
- Built-in summarization, chat, sentiment analysis, or action item extraction.
- Cloud processing, cloud account requirements, or automatic syncing.
- Automatic persistent enrollment of unidentified voices.
- Guaranteed detection of all overlapping speech or perfect attribution in noisy environments.
- Always-on MCP hosting directly from a backgrounded iPhone.
- Voice authentication or security-sensitive identity verification. Speaker matching is an assistive labeling feature, not an authentication factor.

## 4. Target User Journey

1. **Start recording.** App requests microphone and speech authorization as needed, captures audio to a durable local file, and starts live speech recognition.
2. **Watch live text.** Display unassigned text from streaming recognition. Clearly distinguish provisional text that may change from finalized text. No speaker labels during recording.
3. **Stop and save.** Commit audio and available timestamped transcription segments immediately. The recording remains accessible even when later stages fail.
4. **Finalize.** Perform post-recording speech finalization or optional corrective retranscription, diarization, embedding extraction, profile matching, and transcript alignment.
5. **Review transcript.** Show recognized speakers by name, uncertain known matches with a verification indicator, and sequential `Speaker 1`, `Speaker 2`, etc. for unidentified voices.
6. **Correct as needed.** Change a speaker assignment, mark an identified match as confirmed, or optionally enroll an unknown voice into a new or existing persistent profile.
7. **Export.** Share human-readable text or structured JSON. Optional integrations are deferred to a later phase.

## 5. Functional Requirements

### FR-1 Audio Recording

- Record microphone audio using AVFoundation/AVAudioEngine to a durable local file.
- Maintain audio timestamps and an accurate recording clock; handle pauses/interruptions without silently misaligning times.
- Provide Start/Stop, elapsed time, basic recording status, and explicit microphone permission handling.
- Preserve original audio for playback, retry, and reprocessing until the user deletes it.
- Design for lock-screen/background audio recording subject to iOS entitlements, configuration, consent, and system constraints; validate on real hardware.
- Ensure metadata, file writes, and state transitions survive app termination or errors as safely as possible.

### FR-2 Live Transcription

- Stream captured audio into an on-device speech recognizer and display plain text as words arrive.
- Never block audio capture while recognition/inference is under load.
- Support evolving/partial hypotheses and stable/final segments; avoid duplicate words on result replacement.
- Save finalized text segments, including timestamps where provided.
- If live recognition becomes unavailable, continue recording audio and offer post-recording transcription.
- The live view intentionally omits speaker identity.

### FR-3 Post-Recording Processing

- Process a recording through independently retryable stages:
  1. Finalize or generate timestamped transcription.
  2. Detect speech and speaker turns (diarization).
  3. Group repeated turns from the same distinct voice into recording-local clusters.
  4. Extract embeddings from suitable speech samples per cluster.
  5. Match clusters against deliberately saved speaker profiles.
  6. Align timed words/segments to attributed speaker turns.
  7. Persist output and mark the recording ready for review.
- Prefer reusing timestamped live transcription over a second complete ASR pass, unless transcription quality or timestamp coverage is inadequate.
- Preserve unresolved overlap/ambiguous transitions explicitly; do not force incorrect attributions.
- Support cancel/retry and clear user-visible statuses (queued, processing, needs review, ready, failed).
- Persist enough progress to safely restart after interruption; do not promise uninterrupted background execution.

### FR-4 Speaker Diarization

- Determine the distinct speaker clusters **within each recording**, independent of any known identity.
- Associate multiple turns by the same unidentified speaker with one recording-local cluster.
- Generate the unknown speaker label in order of **first occurrence among unidentified clusters**, beginning with `Speaker 1` for each recording.
- Known/recognized speakers do **not** consume numeric indices.
- If there are three speakers, one known and two unknown, label them with the known name, `Speaker 1`, and `Speaker 2`.
- The same label in separate recordings conveys **no implied identity relationship**.

### FR-5 Persistent Speaker Identity and Confidence Policy

- Persist voice profiles only after an explicit enrollment action.
- A profile has a stable ID, user-editable name, embedding model/version, vetted embeddings, creation/update metadata, and optional enrollment provenance.
- For each recording-local cluster, compare quality-filtered embeddings against enrolled profiles and obtain an **appropriately calibrated identity-confidence value** in [0, 1].
- Apply this product policy:

| Calibrated identity confidence | Speaker label | Visual status | Action |
|---|---|---|---|
| `< 0.60` | `Speaker N` | Unidentified | Option to choose/enroll a speaker |
| `0.60 ≤ confidence < 0.80` | Matched profile name | **Needs verification** indicator | Easy confirm/change action |
| `≥ 0.80` | Matched profile name | Recognized, no verification indicator | Still editable |

- **Critical:** Model cosine similarity, logits, distances, and thresholds are **not intrinsically probability percentages**. Validate/calibrate scores empirically on representative held-out recordings before displaying them as probabilities or applying the above percentages literally. Before calibration, expose matching as uncalibrated and use conservative trial thresholds without misleading percentages.
- Require basic signal/embedding quality checks and separation from the next-best candidate; when samples are too short, noisy, overlapping, or ambiguous, return `Speaker N` regardless of nominal score.
- Prevent conflicting assignments of one known identity to distinct clusters by default, while allowing manual correction and documented exceptions if diarization inadvertently splits one person into multiple clusters.
- Do not enroll or update persistent profiles from automatically recognized speakers without explicit user approval.
- Allow manual assignment to a known profile even if below threshold; represent this as a **user-confirmed override**, not as a model prediction.

### FR-6 Corrections and Enrollment

- Tap/click a speaker label to assign a different enrolled speaker, keep unidentified, confirm a suggested identity, or create a new voice profile.
- Apply a speaker correction to the entire recording-local cluster by default, with ability to fix individual incorrect speaker turns.
- Support merging duplicate clusters and splitting an incorrectly combined cluster as a subsequent editing enhancement; design underlying IDs and storage to accommodate both.
- Enrollment from an existing recording uses explicit confirmation and approved clean audio segments; do not automatically accumulate profiles for one-off voices.
- User edits remain authoritative across reprocessing unless the user explicitly resets them.

### FR-7 Transcript Presentation and Export

- Show time-ordered utterances with speaker name/unknown number, start/end timestamps, and transcribed content.
- Show unobtrusive verification indicators for matches in the review tier.
- Permit editing transcript text without modifying the original recording.
- Play audio from the corresponding position when selecting a transcript segment.
- Export at least UTF-8 plain text and versioned structured JSON; include recording ID, segments/turns, timestamps, speaker identity state, speaker references, and schema version.
- Use stable identifiers internally. Avoid keying application logic by display names or `Speaker N` strings.

## 6. Proposed System Architecture

```text
Microphone / AVAudioEngine
      |
      +----> Audio file writer (durable source of truth)
      |
      +----> Live ASR engine ----> provisional/final text UI
                                      |
                                 timed ASR segments
                                      |
                     [User stops recording]
                                      |
                        ProcessingCoordinator
                                      |
          +---------------------------+--------------------+
          |                           |                    |
   Finalize / repair ASR       Diarization engine      VAD / quality filters
          |                           |                    |
          |                    recording-local clusters <-+
          |                           |
          |                  speaker embedding engine
          |                           |
          |                persistent profile matcher
          |                           |
          +------------> transcript / turn aligner
                                      |
                         editable labeled transcript
                                      |
                             local persistence
                                      |
                         JSON / text export APIs
                                      |
                        future secure MCP adapter
```

### Suggested Swift Package Layout

```text
MieRecord/
  Sources/
    ConversationCore/          # Domain models and protocols
    ConversationAudio/         # Capture, audio assets, preprocessing
    ConversationTranscription/ # Streaming and batch ASR adapters
    ConversationDiarization/   # Clustering and turn detection
    ConversationIdentity/      # Embeddings, profiles, matching, calibration
    ConversationPipeline/      # Processing orchestration and recovery
    ConversationPersistence/   # SwiftData metadata + audio file coordination
    ConversationExport/        # Versioned JSON / text output
  Tests/
    ...
ConversationApp/               # SwiftUI iOS client
```

### Interfaces (illustrative, not final API)

```swift
protocol StreamingTranscriptionEngine: Sendable {
    func transcribe<S: AsyncSequence>(
        audio: S
    ) -> AsyncThrowingStream<TranscriptionEvent, Error>
    where S.Element == AudioChunk
}

protocol SpeakerDiarizationEngine: Sendable {
    func diarize(audioURL: URL) async throws -> [SpeakerTurn]
}

protocol SpeakerEmbeddingEngine: Sendable {
    func embed(audioURL: URL, intervals: [TimeRange]) async throws -> [Float]
}

protocol SpeakerIdentityMatcher: Sendable {
    func match(embedding: [Float], profiles: [SpeakerProfile]) async throws -> SpeakerMatch?
}
```

Exact engine signatures may vary with audio format and backpressure needs. The important requirement is to preserve independently swappable implementations.

## 7. Domain Model and Storage

Proposed conceptual entities:

- **Recording:** `id`, title, createdAt, duration, audioFileReference, recordingState, processingState, modelVersions.
- **ASRWord / ASRSegment:** stable IDs, recording ID, text, start/end, provisional/final status, source engine/version.
- **SpeakerCluster:** stable **recording-local** ID, firstAppearance, optional numeric unknown label; one cluster may own many turns.
- **SpeakerTurn:** `id`, cluster ID, start/end, overlap/uncertainty flags.
- **SpeakerProfile:** persistent `id`, displayName, embedding model/version, curated embedding samples, timestamps.
- **SpeakerAttribution:** cluster ID, optional profile ID, calibrated confidence (nullable), status, evidence/quality flags, whether user confirmed/overrode.
- **TranscriptSegment:** stable ID, recording ID, start/end, text, speaker cluster ID or nullable for unresolved overlaps, edit metadata.
- **ProcessingJob:** recording ID, current stage, resumable checkpoint, last error, retry count.

Use SwiftData for indexed metadata and relationships, and store audio and potentially large inference artifacts in managed files. Keep migrations/versioned schemas in mind from the beginning. Use file protection suitable for device-locked data and optional encrypted backup/export policy.

### Suggested Attribution States

```swift
enum SpeakerAttributionStatus: Codable, Sendable {
    case unidentified(localSpeakerNumber: Int)
    case needsVerification(profileID: UUID, confidence: Float)
    case recognized(profileID: UUID, confidence: Float)
    case userConfirmed(profileID: UUID)
}
```

Keep **cluster identity**, **matched profile**, and **presentation label** separate. Confidence belongs to an identity match and should not be confused with transcription or diarization confidence.

## 8. On-Device Engine Candidates (To Validate)

- **Streaming ASR:** Apple's `SpeechAnalyzer` / `SpeechTranscriber` on supported OS/devices/languages. Alternate adapters could use WhisperKit or whisper.cpp if needed.
- **Diarization and speaker embeddings:** Prototype sherpa-onnx-based offline diarization/recognition and Core ML-compatible speaker segmentation/embedding models. Determine acceptable accuracy, package size, and actual iOS integration support by experiment.
- **Inference:** Prefer Neural Engine / Core ML where available; benchmark CPU/GPU fallback and monitor memory/thermal impact.

These are candidate integrations, **not committed dependencies**. Verify model weights, device/OS requirements, model licenses, redistribution rules, and attribution obligations before shipping. Verify Speech framework availability and required on-device language assets at runtime.

## 9. Performance and Reliability Requirements

The MVP must be validated on a physical iPhone 15 Pro Max and at least one additional supported device before broader release. Initial acceptance targets below are **engineering targets to benchmark, not claims of current model performance**:

- Live transcript should generally update within approximately **1–3 seconds** of speech under favorable conditions.
- Recording continues reliably if live ASR stalls or fails.
- Finalization begins after stop and offers visible, persistent progress/status.
- Benchmark processing time relative to audio duration on 5-, 10-, 30-, and 60-minute samples, with battery, memory, and thermals recorded; set a release threshold after collecting data.
- Test quiet rooms, vehicle/ambient noise, distance from microphone, accents, fast turns, overlapping speech, and varying speaker counts.
- Evaluate ASR word error rate (WER), diarization error rate (DER), unknown-speaker precision/recall, false-accept identity matches, and score calibration (e.g., reliability diagrams / expected calibration error).
- Favor **unknown** over falsely confident speaker identity. A mismatched identity should never silently poison the profile library.
- If processing is interrupted, preserve original audio and completed work and offer safe retry; use supported background task APIs as an optimization, not an execution guarantee.

## 10. Privacy, Consent, and Security

- Default to entirely local processing and storage; **no audio/transcript upload** in the MVP.
- Request microphone and speech permissions with clear contextual explanations.
- Remind users to obtain recording consent consistent with applicable laws and policies, including when recording other people.
- Explain that voice embeddings are sensitive biometric-like data; obtain explicit permission to enroll a voice and allow profile deletion.
- Provide delete controls for audio, transcript, and speaker profiles; document whether deleting a profile changes labels in historical transcripts.
- Avoid presenting speaker matching as secure authentication.
- For future third-party exports/integrations, provide scoped user approval, local-first defaults, access revocation, and clearly distinguish data sent off-device.
- Do not silently use recorded conversations to train shared models.

## 11. External Interfaces and MCP (Post-MVP)

The core transcript/export layer should be usable without any AI integration. Later, expose user-authorized capabilities such as:

- `list_recordings` — list permitted recordings.
- `get_transcript` — retrieve timestamped, speaker-labeled transcript.
- `search_transcripts` — search transcript content within authorized scope.
- `list_speakers` — retrieve permitted named speaker profiles/metadata.
- `get_speaker_conversations` — list recordings involving a named speaker.
- `export_transcript` — retrieve JSON/text for approved recordings.

Do **not** require the iPhone app itself to remain an always-on server. Candidate integration approaches include user-initiated export, a macOS companion MCP server, or an explicitly configured relay/sync service with authentication and access controls. Third-party summarization and downstream processing are entirely the user's choice.

### Minimal JSON Export Shape (Illustrative)

```json
{
  "schemaVersion": "1.0",
  "recordingID": "<uuid>",
  "durationSeconds": 45.0,
  "speakers": [
    { "clusterID": "cluster-a", "profileID": "<uuid>", "label": "Brett", "status": "recognized", "identityConfidence": 0.94 },
    { "clusterID": "cluster-b", "profileID": null, "label": "Speaker 1", "status": "unidentified", "identityConfidence": null }
  ],
  "segments": [
    { "id": "segment-1", "start": 3.0, "end": 10.5, "clusterID": "cluster-a", "text": "I think we should separate these processing stages." },
    { "id": "segment-2", "start": 12.0, "end": 18.0, "clusterID": "cluster-b", "text": "That makes sense." }
  ]
}
```

The example values are illustrative only; production exports should include explicit units, null-handling, versioning, and user-edit provenance as appropriate.

## 12. Delivery Phases

### Phase 1 — Capture and Live ASR

**Deliver:** start/stop, durable audio recording, live plain-text transcript, timestamped result storage, playback, basic transcript UI, and graceful ASR failure fallback.

**Exit criteria:** a 10-minute real-device recording shows updating text and remains playable and recoverable after interruption; no speaker identification required.

### Phase 2 — Offline Diarization and Alignment

**Deliver:** recording-local speaker clusters, turn timelines, `Speaker 1...N` labels, timed text-to-turn alignment, UI to edit speaker assignments, safe reprocessing.

**Exit criteria:** a three-person test recording yields reusable per-recording clusters/labels across multiple turns, with correction controls.

### Phase 3 — Persistent Identity Recognition

**Deliver:** explicit speaker enrollment, versioned embeddings, scoring and calibration experiments, configurable three-tier identity policy, match verification, override, deletion.

**Exit criteria:** a previously enrolled speaker can be matched in a separate recording, ambiguity is flagged or left unknown, and unknown speakers do not create persistent profiles.

### Phase 4 — Quality, Exports, and Hardening

**Deliver:** structured JSON and text exports, offline testing, reliability/thermal benchmarks, process recovery, permissions, privacy controls, accessibility, schema migrations.

**Exit criteria:** all MVP acceptance scenarios below pass on target hardware and conditions are documented.

### Phase 5 — Optional Integration Ecosystem (Post-MVP)

**Deliver:** versioned public/export API and a separately deployable, authenticated MCP integration strategy. No default summarization service.

## 13. MVP Acceptance Scenarios

1. **Live transcript:** Start a recording and see evolving, unlabeled text without interrupting capture.
2. **Durability:** Stop recording; audio and finalized transcript remain accessible when post-processing cannot complete.
3. **Three-person recording, one known:** If one speaker is recognized and two are unknown, show known name, `Speaker 1`, `Speaker 2`.
4. **Repeated unknown:** Every later turn of the same diarized unknown speaker keeps the same recording-local number.
5. **New recording:** `Speaker 1` numbering restarts and implies no global identity.
6. **60%–79.9%:** A calibrated match uses the known name with a verification indicator.
7. **80%+:** A calibrated match uses the known name without a verification indicator, while remaining editable.
8. **Below 60%:** A speaker uses `Speaker N`; do not create a profile.
9. **Low quality/ambiguous:** Even a high raw model similarity does not force a name when quality or margin checks fail.
10. **Manual confirmation:** Confirm/change a match; preserve user choice across ordinary reprocessing.
11. **Opt-in enrollment:** A user can create a profile from vetted samples; no automatic enrollment happens.
12. **Offline:** Existing necessary models/assets installed, recording and processing complete in airplane mode.
13. **Export:** JSON and text reflect current labels, timestamps, and corrections.
14. **Recovery:** An interrupted processing job can be resumed or retried without losing the original recording.

## 14. Risks and Open Questions

| Area | Risk / decision | Initial approach |
|---|---|---|
| Identity confidence | Raw embedding score is not calibrated probability | Collect a representative evaluation set; calibrate and validate thresholds before treating scores as % |
| Speaker overlap | Multiple people can talk at once | Preserve overlap/ambiguity; allow unknown attribution and correction |
| Word alignment | Live ASR timestamps may not align perfectly with diarization | Allow targeted alignment/retranscription during finalization |
| Battery and thermals | Long recordings/inference may be expensive | Streaming ASR lightweight; heavier inference after stop; benchmark |
| Model availability | OS/language/model assets vary | Runtime capability detection and fallback adapters |
| Model licensing | Weight redistribution/license constraints | Review all code and weights before selecting shipping dependencies |
| Background execution | iOS may suspend/terminate processing | Checkpoint queue and safe retry; background tasks where supported |
| Enrollment quality | Noise/short clips reduce identification accuracy | Curate multiple clean samples and abstain on weak evidence |
| Profile drift | Mistaken self-training can poison voice library | No implicit profile updates; explicit user approval |
| Voice privacy | Sensitive content and profiles | Local storage, deletion, permission controls, scoped exports |

## 15. Decisions Recorded

- iPhone-first, native Swift implementation.
- Live **raw text**, without real-time speaker labels.
- More computationally intensive speaker diarization and identity attribution **after recording stops**.
- Reuse live transcription where accurate rather than retranscribing by default.
- **60–80%**: known name with verification indicator; **80%+**: known name with no required verification; **below 60%**: `Speaker N`, subject to calibrated confidence and quality safeguards.
- Unknown identities numbered sequentially within each recording; numbering resets per recording.
- Unidentified voices are **not** automatically added to persistent voice profiles.
- Explicit speaker enrollment, user confirmation/correction, and optional profile sample enhancement.
- All recording and inference local by default; no built-in summarization in MVP.
- Future compatibility with user-chosen MCP/external AI analysis, without forcing a cloud service or an always-on iPhone server.

---

*This specification establishes product behavior and architecture while leaving specific model selection, performance thresholds, and calibration methods to be validated through a device-based proof of concept.*
