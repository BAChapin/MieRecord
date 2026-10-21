# MieRecord — Implementation Plan

Tracks progress against `SPEC.md`. Updated as milestones land.

**Status:** Milestones 1–2 hardware-verified by the user. Milestone 3 (persistent identity) implemented and verified on the Mac with the real models; iPhone hands-on run pending.
**Last updated:** 2026-10-21

## Architecture summary

One Xcode project (`MieRecord.xcodeproj`) plus one local Swift package
(`ConversationKit/`) with five library targets. The package never imports
SwiftUI; the app target is the only place that does.

| Module | Role | Key types |
|---|---|---|
| `ConversationCore` | Domain entities, processing states, speaker policy, identity matching and calibration, repository protocols | `Recording`, `TranscriptSegment`, `TimeRange`, `ProcessingState`, `SpeakerCluster`/`SpeakerTurn`/`SpeakerProfile`/`SpeakerAttributionStatus`, `IdentityConfidencePolicy`, `UnknownSpeakerNumbering`, `RecordingRepository`, `AudioFileStore` |
| `ConversationAudio` | Capture, durable file writing, interruptions | `AudioCaptureSource` (protocol), `AudioCaptureSession` (actor, AVAudioEngine), `CaptureFileWriter`, `AudioChunk`, `MicrophonePermission`, `AudioSessionController` |
| `ConversationML` | Engine protocols and implementations | `StreamingTranscriptionEngine`, `AppleSpeechTranscriptionEngine` (SpeechAnalyzer/SpeechTranscriber), `SpeakerDiarizationEngine`, `SpeakerEmbeddingEngine`, `SpeakerIdentityMatcher` (interfaces only) |
| `ConversationPipeline` | Orchestration | `RecordingSession`, `LiveTranscriptAssembler`, `RecordingRecovery`, `RetranscriptionService`, `PostProcessingCoordinator`, `TranscriptSpeakerAligner`, `SpeakerEditor`, `IdentityService` |
| `ConversationStorage` | Persistence | `SwiftDataRecordingRepository` (`@ModelActor`), `DirectoryAudioFileStore`, SwiftData models incl. speaker clusters and turns |
| `ConversationDiarization` | FluidAudio adapter | `FluidAudioDiarizationEngine` (only module that imports FluidAudio) |
| `MieRecord` (app) | SwiftUI | `AppDependencies` (composition root), `RecordingListView`, `RecordingView`, `RecordingDetailView`, view models, `AudioPlaybackController` |

The SPEC's seven logical modules map as: Core → `ConversationCore`; Audio →
`ConversationAudio`; Transcription + Diarization + Identity →
`ConversationML`; Pipeline → `ConversationPipeline`; Persistence →
`ConversationStorage`; Export → not yet created (Milestone 4); App → `MieRecord`.

### Data flow (Milestone 1)

```
AVAudioEngine tap ──► CaptureFileWriter ──► <id>.caf (source of truth)
        │                    │
        │                    └─► AudioChunk(startTime = file position)
        │                                   │ bounded AsyncStream (drops oldest if consumer stalls)
        ▼                                   ▼
AudioCaptureEvent (progress,     AppleSpeechTranscriptionEngine
interruption, failure)           → TranscriptionEvent (volatile | finalized)
        │                                   │
        └──────────► RecordingSession ◄─────┘
                      │  LiveTranscriptAssembler
                      │  saves Recording before capture, each final segment on arrival
                      ▼
            RecordingRepository (SwiftData)  ──► SwiftUI views
```

## Technical decisions

1. **Timeline = file position, not wall clock.** `AudioChunk.startTime` and
   every `TimeRange` are seconds of audio written to the file. Interruptions
   pause the timeline instead of inserting gaps, so transcript timestamps and
   later diarization line up with the audio file without correction.
2. **Lossless capture format.** Audio is written as PCM in the input node's
   format (typically 48 kHz Float32 mono, ~11.5 MB/min) to a `.caf`. This keeps
   full quality for diarization/embeddings and avoids encoder state in the
   real-time tap. Compression (AAC copy after processing) is a later option.
3. **Capture never blocks on consumers.** `AudioCaptureSession.chunks` uses
   `.bufferingNewest(64)`; a stalled transcriber loses live coverage, the file
   does not. The tap thread touches only a lock-protected writer and stream
   continuations.
4. **Live transcription via `SpeechAnalyzer` + `SpeechTranscriber`** with
   `.volatileResults` and `.audioTimeRange`/`.transcriptionConfidence`
   attributes. Chunks are converted to the analyzer's preferred format with
   `AVAudioConverter` and tagged with `bufferStartTime`, so result ranges are
   already on the file timeline. Asset download (`AssetInventory`) is the only
   network use and runs only through `prepare()`.
5. **Persist early and often.** `RecordingSession.start()` saves the
   `Recording` in `.recording` state before the engine starts; each finalized
   segment is saved as it arrives; `stop()` saves duration and `.completed`.
   `RecordingRecovery` marks `.recording` rows found at launch as
   `.interrupted` and reads their duration from the audio file.
6. **Protocol boundaries + injection.** `RecordingSessionDependencies` takes a
   repository, audio file store, optional transcription engine, and a capture
   factory. Tests drive `RecordingSession` with fakes; the app wires real
   implementations in `AppDependencies`.
7. **Speaker policy lives in Core now.** `IdentityConfidencePolicy` encodes
   the 60/80 tiers and quality gate, and `UnknownSpeakerNumbering` encodes
   first-appearance numbering with identified clusters skipped. Both are pure
   and tested but not yet wired, since no diarization/matching exists.
   Matchers must return calibrated confidence or `nil`; raw similarity is never
   accepted by the policy.
8. **SwiftData as an implementation detail.** Models are `internal`; the
   repository returns Core value types. `ProcessingState` is stored as JSON
   `Data` so new cases/associated values do not need migrations.
9. **Swift 6 strict concurrency.** Package targets use default (nonisolated)
   isolation with actors for `AudioCaptureSession`, `RecordingSession`, and
   the `@ModelActor` repository. The app target uses
   `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` for views and view models.
10. **No speech-recognition permission prompt.** `SpeechTranscriber` is on
    device and does not go through `SFSpeechRecognizer` authorization; only
    microphone permission is requested. If hardware testing shows otherwise,
    add `NSSpeechRecognitionUsageDescription` and a request step.
11. **Background audio** is declared (`UIBackgroundModes: audio`) so a
    recording survives backgrounding and lock. Needs device validation.

## Milestone 1 — Capture and live ASR

### Completed

- [x] Xcode project + local Swift package with five modules and three test targets
- [x] Domain models: recordings, segments, time ranges, processing states, speaker entities, attribution states
- [x] `IdentityConfidencePolicy` and `UnknownSpeakerNumbering` (pure, tested, unwired)
- [x] AVAudioEngine capture to durable `.caf`, format-change conversion, interruption pause/resume, configuration-change re-arm
- [x] Apple on-device streaming transcription with volatile/final distinction and file-timeline timestamps
- [x] `RecordingSession` orchestration with early persistence, bounded finalization wait, failure isolation
- [x] SwiftData repository and audio file store (Application Support, file protection until first unlock)
- [x] Launch-time recovery of interrupted recordings
- [x] SwiftUI: recording list, live recording screen (elapsed, status, finalized vs provisional text), detail screen with playback, seek-by-segment, playhead highlight, rename, delete
- [x] Microphone permission flow with Settings deep link
- [x] Re-transcription of a saved recording (added 2026-10-21, ahead of Milestone 2): `FileTranscriptionEngine` protocol, `AppleSpeechTranscriptionEngine.transcribeFile` (`SpeechAnalyzer.analyzeSequence(from:)` + `finalizeAndFinish`), `RetranscriptionService` actor, app-wide `TranscriptionJobs` with progress, cancel, retry, and a background-task assertion; atomic `RecordingRepository.updateRecording`; launch recovery of stuck processing states
- [x] Unit/integration tests (22) and an XCUITest for record → stop → open

### Testing status

| Check | Result |
|---|---|
| `swift build` (macOS host, all modules, Swift 6 strict) | passes, no warnings |
| `swift test` — Core (8), ML (4), Pipeline (19), Storage (6) | 37/37 pass |
| `xcodebuild build` iOS Simulator (iPhone 17 Pro) | passes |
| `xcodebuild build` physical iPhone (signed, device-registered) | passes; installed and launched on the paired iPhone |
| XCUITest record → stop → open on simulator | **not executed**: the test runner could not connect to xcodebuild on either booted simulator (`DTServiceHubClient failed to bless service hub`, runner SIGTERMed before the test started). Environment issue, not a test failure; see verification log |
| Live transcription on simulator | not expected to be available; the UI reports it and recording continues |
| Live transcription, interruptions, background recording on hardware | **unverified** — needs a hands-on device session |
| 10-minute recording recoverable after interruption (Phase 1 exit criterion) | **unverified** |

### Verification log

- 2026-10-21: `swift test` 22/22 green. App built for simulator and launched to the empty Recordings screen (screenshot verified); SwiftData store and `Recordings/` folder created in Application Support. Device build signed with automatic provisioning, installed and launched on "Brett's iPhone" (iPhone 17 Pro, iOS 26). Nobody has yet tapped Record on either target, so capture, live transcription, playback, and interruption handling remain unexercised at runtime.
- 2026-10-21: `xcodebuild test` for `MieRecordUITests` failed three times (iOS 26.4 and iOS 27.0 simulators, with and without the shell sandbox) with "The test runner hung before establishing connection" / "DTServiceHubClient failed to bless service hub". The runner app launched and was killed before any test method ran. Likely remedy: restart CoreSimulatorService / the Simulator app and rerun from Xcode. Not attempted automatically because it kills the user's running simulators.

- 2026-10-21: **Bug found on hardware and fixed.** Live transcription stopped after the first ~0.1 s of every recording on iPhone with `SFSpeechErrorDomain 17` ("Audio input timestamp overlaps or precedes prior audio input"). Cause: the 48→16 kHz `AVAudioConverter` holds samples back and releases them in bursts, so stamping each converted buffer with its input chunk's start time produced overlapping ranges. Fix: `AnalyzerTimeline` stamps buffers from a running analyzer-sample clock (forward jumps only on real upstream gaps), the converter has burst headroom and is flushed at end of input, tap buffers are copied before being handed to consumers, and transcription failures are logged via `OSLog` (subsystem `com.mietech.MieRecord`). Verified by replaying both device recordings through the engine on the Mac at real-time pace (full transcripts, correct timestamps) and by `ConversationMLTests` (real resampler, 3 chunk sizes). Earlier batch-fed tests had hidden the bug. Fixed build installed on the iPhone; awaiting a hands-on recording to confirm.

- 2026-10-21: Re-transcription verified on the Mac against both device recordings (4 spans each, ~0.25 s per file, timestamps and confidence present) and by 10 new service tests (replace, failure keeps transcript, empty result protection, user-edit protection, missing file, in-progress refusal, unsupported engine, concurrent-run rejection, cancellation restores state, launch recovery). Built, installed, and launched on the iPhone; the in-app flow has not been tapped through on hardware yet.

### Known limitations

- Live transcription availability depends on `SpeechTranscriber.isAvailable`
  and installed locale assets. The first run may download assets (network).
- Re-transcription replaces the whole transcript; there is no per-segment merge yet. It refuses to discard user-edited segments, but the UI has no text editing yet, so that path is only exercised by tests.
- Re-transcription runs in the foreground with a background-task grace period. If iOS ends that time, the job is cancelled and the old transcript is kept.
- Simulator typically cannot run `SpeechTranscriber`; the recording screen
  shows "Live transcription unavailable" and still records.
- No post-recording transcription fallback yet: if live transcription was
  unavailable, the recording has no transcript until Milestone 2 adds a
  file-based `SpeechAnalyzer` pass.
- Transcript text is not yet editable in the UI (storage supports `editedAt`).
- Recording title is auto-generated (`Recording <date>`) and can be renamed.
- `.caf` PCM files are large (~11.5 MB/min at 48 kHz mono).
- Processing status UI shows only a placeholder footer; `ProcessingState`
  is persisted but always `.notStarted`.

## Milestone 2 — Offline diarization and alignment

### Completed (2026-10-21)

- [x] Engine evaluation: Apple's iOS 27.1 SDK has no diarization API. Candidates compared: FluidAudio, sherpa-onnx, Argmax SpeakerKit OSS. **FluidAudio 0.17.7 selected** (native Swift, Core ML, file-URL entry point that resamples internally, 256-d speaker embeddings for Milestone 3).
- [x] FluidAudio source audited at v0.17.7: only network code is the Hugging Face model downloader; no telemetry. `ModelHub.offlineMode = true` turns missing models into errors instead of downloads.
- [x] Models (21 MB, HF `FluidInference/speaker-diarization-coreml` at `df2625ac`) bundled in `Models/DiarizationModels` with `SHA256SUMS`, `MODEL_NOTICE.md`, `MODEL_CARD.md`, and a provenance README; copied into the app as a folder reference.
- [x] `ConversationDiarization` adapter target; FluidAudio pinned `exact: "0.17.7"` with `traits: []` so the NemoTextProcessing binary is not linked (verified in the built app).
- [x] Word-level timing captured from `SpeechTranscriber` runs (live and file passes) and persisted.
- [x] `TranscriptSpeakerAligner`: per-word attribution with splitting at speaker changes; segment-level fallback; overlap, mixed-segment, and far-from-turn ambiguity flagged rather than forced.
- [x] `PostProcessingCoordinator`: transcript repair only when missing/provisional/untimed (never over user text edits), diarization checkpoint reused on retry for the same engine version, alignment, `.ready` / `.needsReview` / `.failed(stage)` states; runs automatically after every recording stops.
- [x] `SpeakerEditor`: move a line to another or a new speaker, confirm an uncertain line, merge two speakers. Corrections are marked user-chosen and block silent reprocessing.
- [x] `Speaker N` labels computed from segments (first appearance, gap-free after edits, identified speakers skip numbers).
- [x] UI: colored speaker labels with correction menus, needs-review prompt, per-stage progress and cancel, Identify Speakers (Again), list badges, Acknowledgements screen (CC-BY-4.0 attribution with all three model-card citations, FluidAudio Apache-2.0 text).
- [x] SwiftData schema migration (new optional/defaulted fields and two new models) verified on a copy of the phone's store and on the phone itself.

### Technical decisions

12. **FluidAudio behind `SpeakerDiarizationEngine`.** Only `ConversationDiarization` imports it; the protocol takes a file URL and returns a `SpeakerTimeline`, so sherpa-onnx or SpeakerKit could replace it without touching other modules.
13. **Models bundled, never downloaded.** Fully offline from first launch (SPEC §13 scenario 12) at the cost of 21 MB app size and 21 MB in git. The `.fluidaudio-revision` marker and `speaker-diarization/` folder name are required by FluidAudio.
14. **Engine speaker IDs are discarded.** "S1"/"S2" map to fresh cluster UUIDs per run; labels are always derived from stable IDs.
15. **Ambiguity thresholds (provisional).** Word overlap ratio 0.5; segment runner-up ≥ 0.3 share or ≥ 0.5 s; snap distance ≤ 0.5 s confident, ≤ 1.0 s flagged; beyond that, unattributed. Tune with real recordings.
16. **Non-Sendable `OfflineDiarizerManager`** is created per run as a local inside the adapter actor; only the `Sendable` loaded models are cached.

### Testing status (Milestone 2)

| Check | Result |
|---|---|
| `swift test`: Core 10, ML 4, Pipeline 36, Storage 7, Diarization 3 | 60/60 pass |
| Real bundled models on a 34 s three-voice synthetic meeting (fixture in tests) | 3 speakers, every line correctly attributed |
| Full stack on the Mac (Apple file transcription + FluidAudio + alignment + SwiftData) | 12/12 lines correct, `Speaker 1–3` by first appearance, about 2 s |
| Real one-speaker recordings from the iPhone | 1 speaker found |
| iPhone build, install, launch, store migration | pass |
| Diarization speed, memory, accuracy on iPhone; real multi-person conversations | **unverified** |

### Known limitations

- Two similar synthetic female voices (Samantha, Karen) were merged into one speaker; forcing three speakers still misassigned one line. Real voices are expected to separate better, but accuracy on real conversations is unmeasured. Users can fix merges with "Move this line to → New Speaker".
- FluidAudio's per-segment `embedding` is the cluster centroid copied onto every turn, not a per-turn vector. Milestone 3 must use `embedSpans` for per-turn quality checks.
- No published iPhone memory figures; 30–60 minute recordings still need benchmarking (SPEC §9).
- Splitting an incorrectly merged speaker is per line only; a bulk split tool is not built.
- Corrections cannot be undone except by "Identify Speakers Again" (which discards all corrections).

## Milestone 3 — Persistent identity

### Completed (2026-10-21)

- [x] Embedding source verified in FluidAudio 0.17.7 source: there is no per-span embedding API (the research summary's `embedSpans` does not exist), and the standalone CAM++ embedder is beta and uses separate, unreviewed models. Identity therefore uses the diarizer's own per-window 256-d embeddings (`exposeChunkEmbeddings`), keeping clustering and matching in one embedding space.
- [x] Score measurements on 2026-10-21 (raw cosine of window-centroid voiceprints): same real person across two sessions 0.80; different clean speakers −0.15 to 0.42; cluster consistency 0.94–0.96 for pure clusters versus 0.76–0.82 for clusters mixing voices. A mixed cluster scored 0.81 against one of its members, which the consistency gate blocks.
- [x] Core: `VectorMath`, `WindowEmbedding`, `ClusterVoiceprint` (consistency, clean speech), `SpeakerProfile`, `VoiceSample` with provenance, `ProfileVoiceprint`, `SpeakerAttributionStatus` (unidentified, needsVerification, recognized, userConfirmed, userKeptUnidentified), `IdentityEvidence`, `IdentityFeedback`.
- [x] `IdentityMatchingPolicy` + `IdentityMatcher`: quality gates (≥ 4 s clean speech, consistency ≥ 0.88), margin ≥ 0.15 to the next person, one person per recording (strongest claim wins; a fallback match is never top tier), rejected people never re-suggested, user decisions never overwritten. Provisional tiers on raw similarity (≥ 0.70 verify, ≥ 0.85 recognized) until calibrated; calibrated mode applies the SPEC 60/80 tiers.
- [x] `IdentityCalibration` / `CalibrationFitting`: Platt scaling (Newton, label smoothing), expected calibration error, k-fold held-out ECE. Validated only with ≥ 30 examples per class and ECE ≤ 0.05. Not enabled in the app.
- [x] `IdentityService`: matching, cheap re-matching of all recordings from stored voiceprints, explicit enrollment (consent, ≥ 5 s of approved lines, selection consistency check), adding samples to a person, confirm/reject/assign/keep-unidentified/clear, rename, delete sample, delete person (reverts history), delete all. Feedback logged locally on confirm/reject/manual assignment, excluding self-comparisons.
- [x] Recordings diarized before voice data existed (Milestone 2) are diarized again on their next processing run instead of reusing the checkpoint, so they can be matched and enrolled.
- [x] Pipeline: voice data stored after diarization; identity matching stage; identity decisions survive reused diarization and block a fresh one without consent; merges move voice windows and carry user decisions.
- [x] Storage: voice data and attributions cascade with recordings; profiles, samples, and feedback are independent; profile deletion cascades to samples and feedback.
- [x] UI: names on speaker labels, verify badge with "Yes, this is …" / "Not …", "This is…", "Save Voice as New Person…", "Add This Voice to …", "Remove Name", "Not Anyone Saved"; enrollment sheet with line selection, playback, minimum speech, consent toggle, voiceprint explanation; People screen with samples, rename, delete person, delete all, and an explanation of provisional matching with calibration progress.

### Technical decisions

17. **Diarizer embeddings for identity.** Window embeddings are masked per speaker within each 10 s analysis chunk, so they are speaker-specific. Profiles are centroids of approved samples; matching compares centroids by cosine.
18. **No percentages before calibration** (SPEC FR-5). Evidence stores raw similarity and margin; calibrated confidence is nil while provisional. The UI shows names, a verify badge, or `Speaker N`, never a number.
19. **Rematch on library change.** Enrolling, adding or deleting samples, and deleting people re-match every recording from stored voiceprints (no audio work). Recognition never changes profiles.
20. **Deleting a person reverts history.** Every recording that named them shows a numbered speaker again, including user-confirmed ones; their samples and calibration feedback are deleted.
21. **Merging into a confirmed person.** Assigning a person who is already confirmed for another speaker in the same recording merges the two speakers.

### Testing status (Milestone 3)

| Check | Result |
|---|---|
| `swift test`: Core 20, ML 4, Pipeline 45, Storage 8, Diarization 4 | 81/81 pass |
| Real stack on the Mac: enroll Samantha and Daniel from one synthetic meeting, process another meeting with different lines | both recognized (raw 0.94, margins 0.74 and 0.77); unenrolled Fred stays `Speaker 1`; 2 profiles, 2 samples, no automatic enrollment |
| iPhone build | pass |
| iPhone install, launch, and store migration (3 recordings, 11 segments intact; identity tables present) | pass |
| Hands-on enrollment and recognition on the iPhone | **pending** |

### Known limitations

- Provisional thresholds rest on one real same-person measurement. Expect real voices across rooms and microphones to score lower than synthetic voices; tune after collecting confirmations.
- Calibration is implemented but never enabled automatically; enabling it needs a deliberate decision and a representative evaluation set (SPEC §9).
- A speaker created by hand ("New Speaker") has no voiceprint and cannot be enrolled.
- Enrollment selection is by line; window embeddings are about 10 s, so a short approved line can include neighboring audio from the same speaker's window.
- Identity evidence on user-confirmed speakers keeps the pre-decision scores (not shown in the UI).

## Milestone 4 — Quality, exports, hardening

- [ ] `ConversationExport` module: UTF-8 text and versioned JSON (schema from SPEC §11)
- [ ] Transcript text editing with provenance
- [ ] Benchmarks on 5/10/30/60-minute recordings (time, battery, memory, thermals)
- [ ] Offline (airplane mode) acceptance run; background task scheduling for processing
- [ ] Accessibility pass; schema migration plan

## Milestone 5 — Integration ecosystem (post-MVP)

- [ ] Public export API; MCP strategy (macOS companion or user-initiated export). No always-on iPhone server.

## Next development steps

1. Hands-on iPhone run of Milestone 3: enroll yourself from one recording, make a new recording, confirm the verify flow, reject a wrong suggestion, delete and re-add a person.
2. Collect confirmations and rejections from real use; revisit the provisional thresholds with that data, then decide whether to validate and enable calibration.
3. Benchmark diarization and matching on 10-, 30-, and 60-minute recordings on the iPhone.
4. Milestone 4: `ConversationExport` (UTF-8 text and versioned JSON with identity state and provenance), transcript text editing, accessibility, offline acceptance run.
