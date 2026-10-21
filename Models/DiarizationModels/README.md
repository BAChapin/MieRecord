# Bundled speaker diarization models

These Core ML models are copied into the app bundle as the `DiarizationModels`
folder and loaded by `FluidAudioDiarizationEngine`
(`ConversationKit/Sources/ConversationDiarization`). The app never downloads
them: FluidAudio's downloader runs in offline mode.

| | |
|---|---|
| Source | https://huggingface.co/FluidInference/speaker-diarization-coreml |
| Revision | `df2625ac79a7ac6b65ad868fee6d80f320da4232` (pinned by FluidAudio 0.17.7) |
| Fetched | 2026-10-21 with FluidAudio 0.17.7 `ModelHub.download(.diarizer, variant: "offline")` |
| Size | about 21 MB |
| License | CC-BY-4.0 (https://creativecommons.org/licenses/by/4.0/) for the Community-1-derived files; see `MODEL_NOTICE.md` |
| Integrity | `shasum -a 256 -c SHA256SUMS` from this folder |

## Attribution (CC-BY-4.0)

Speaker diarization uses modified Core ML conversions, made by Fluid Inference,
of the pyannote speaker-diarization-community-1 pipeline (pyannote, WeSpeaker)
with PLDA parameters from Brno University of Technology / BUT Speech@FIT.
Citations are retained in `MODEL_CARD.md`. The app shows this attribution on
its Acknowledgements screen.

Only these covered artifacts are shipped: `Segmentation.mlmodelc`,
`FBank.mlmodelc`, `Embedding.mlmodelc`, `PldaRho.mlmodelc`,
`plda-parameters.json`, `xvector-transform.json`. None of the legacy models
excluded by `MODEL_NOTICE.md` are included.

## Layout requirement

FluidAudio requires the folder name `speaker-diarization/` and the hidden
`.fluidaudio-revision` marker. Do not rename or drop it.

## Updating

When upgrading FluidAudio, check whether its pinned revision changed
(`ModelNames.swift`, `Repo.diarizer.revision`). If it did, refetch with that
release, replace this folder, regenerate `SHA256SUMS`, and update
`FluidAudioDiarizationEngine.modelRevision`.
