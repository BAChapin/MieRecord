# MieRecord — Implementation Plan

Tracks progress against `SPEC.md`. Updated as milestones land.

**Status:** Milestone 1 implemented; simulator-verified, hardware verification pending.
**Last updated:** 2026-10-21

## Architecture summary

One Xcode project (`MieRecord.xcodeproj`) plus one local Swift package
(`ConversationKit/`) with five library targets. The package never imports
SwiftUI; the app target is the only place that does.

| Module | Role | Key types |
|---|---|---|
| `ConversationCore` | Domain entities, processing states, speaker policy, repository protocols | `Recording`, `TranscriptSegment`, `TimeRange`, `ProcessingState`, `SpeakerCluster`/`SpeakerTurn`/`SpeakerProfile`/`SpeakerAttributionStatus`, `IdentityConfidencePolicy`, `UnknownSpeakerNumbering`, `RecordingRepository`, `AudioFileStore` |
| `ConversationAudio` | Capture, durable file writing, interruptions | `AudioCaptureSource` (protocol), `AudioCaptureSession` (actor, AVAudioEngine), `CaptureFileWriter`, `AudioChunk`, `MicrophonePermission`, `AudioSessionController` |
| `ConversationML` | Engine protocols and implementations | `StreamingTranscriptionEngine`, `AppleSpeechTranscriptionEngine` (SpeechAnalyzer/SpeechTranscriber), `SpeakerDiarizationEngine`, `SpeakerEmbeddingEngine`, `SpeakerIdentityMatcher` (interfaces only) |
| `ConversationPipeline` | Orchestration | `RecordingSession` (actor), `LiveTranscriptAssembler`, `RecordingRecovery` |
| `ConversationStorage` | Persistence | `SwiftDataRecordingRepository` (`@ModelActor`), `DirectoryAudioFileStore`, SwiftData models |
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

- [ ] Evaluate on-device diarization candidates (sherpa-onnx speaker segmentation + embedding models; Core ML conversions). Verify iOS build, license, model size, memory, timestamped turn output before adopting anything.
- [ ] Run the existing file transcription pass automatically when live transcription was unavailable or left gaps (the engine and service exist; only the trigger is missing)
- [ ] `PostProcessingCoordinator` with resumable stages driving `ProcessingState`
- [ ] `SpeakerDiarizationEngine` implementation → `SpeakerCluster`/`SpeakerTurn` persistence
- [ ] Transcript-to-turn alignment; `Speaker N` labeling via `UnknownSpeakerNumbering`
- [ ] UI for speaker assignment, merge/split groundwork
- [ ] Processing status UI (queued/processing/needs review/ready/failed), cancel/retry

## Milestone 3 — Persistent identity

- [ ] `SpeakerEmbeddingEngine` implementation and profile storage (SwiftData + managed embedding files)
- [ ] Explicit enrollment flow from vetted segments; no automatic enrollment
- [ ] `SpeakerIdentityMatcher` with quality gates and margin checks; calibration experiment harness and evaluation set before surfacing percentages
- [ ] Wire `IdentityConfidencePolicy`; verification indicator and confirm/override UI
- [ ] Profile deletion policy and its effect on historical labels

## Milestone 4 — Quality, exports, hardening

- [ ] `ConversationExport` module: UTF-8 text and versioned JSON (schema from SPEC §11)
- [ ] Transcript text editing with provenance
- [ ] Benchmarks on 5/10/30/60-minute recordings (time, battery, memory, thermals)
- [ ] Offline (airplane mode) acceptance run; background task scheduling for processing
- [ ] Accessibility pass; schema migration plan

## Milestone 5 — Integration ecosystem (post-MVP)

- [ ] Public export API; MCP strategy (macOS companion or user-initiated export). No always-on iPhone server.

## Next development steps

1. Rerun `MieRecordUITests` from Xcode (Product ▸ Test) after restarting the Simulator; it covers record → stop → open → playable.
2. Hands-on hardware run: record ~10 minutes on the iPhone, trigger an incoming call, background the app, confirm playback and transcript persistence. Record results in the verification log.
3. If `SpeechTranscriber` assets need downloading on first use, add a visible progress UI around `prepare()`.
4. Begin Milestone 2 with the file-based transcription pass, since it also closes the "no live transcript" gap.
