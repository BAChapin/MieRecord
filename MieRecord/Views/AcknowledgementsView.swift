import SwiftUI

/// Third-party attributions required by the licenses of bundled components.
///
/// The speaker models are CC-BY-4.0: attribution must name pyannote, WeSpeaker,
/// BUT Speech@FIT, and Fluid Inference, link the license, and say the files are
/// modified conversions (see Models/DiarizationModels/MODEL_NOTICE.md).
/// FluidAudio is Apache-2.0, which requires including its license text.
struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    private var fluidAudioLicense: String {
        guard
            let url = Bundle.main.url(forResource: "FluidAudio-LICENSE", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "The Apache License 2.0 text could not be loaded." }
        return text
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Recording, transcription, and speaker detection run entirely on this device. Audio and transcripts are not uploaded.")
                        .font(.subheadline)
                }

                Section("Speaker detection models") {
                    Text(
                        "Speaker detection uses modified Core ML conversions, made by Fluid Inference, "
                            + "of the pyannote speaker-diarization-community-1 pipeline by pyannote, "
                            + "with WeSpeaker speaker embeddings and PLDA parameters from "
                            + "Brno University of Technology / BUT Speech@FIT."
                    )
                    Text("Licensed under Creative Commons Attribution 4.0 International (CC BY 4.0).")
                    Link("CC BY 4.0 license", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                    Link("Model source (FluidInference/speaker-diarization-coreml)", destination: URL(string: "https://huggingface.co/FluidInference/speaker-diarization-coreml")!)
                    Link("pyannote/speaker-diarization-community-1", destination: URL(string: "https://huggingface.co/pyannote/speaker-diarization-community-1")!)
                    Text(
                        "Citations: Plaquet & Bredin, \"Powerset multi-class cross entropy loss for neural speaker "
                            + "diarization\", Interspeech 2023. Wang et al., \"WeSpeaker: A research and production "
                            + "oriented speaker embedding learning toolkit\", ICASSP 2023. Landini, Profant, Diez & "
                            + "Burget, \"Bayesian HMM clustering of x-vector sequences (VBx) in speaker diarization\", "
                            + "Computer Speech & Language, 2022."
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("FluidAudio") {
                    Text("Copyright Fluid Inference. Licensed under the Apache License, Version 2.0.")
                    Link("github.com/FluidInference/FluidAudio", destination: URL(string: "https://github.com/FluidInference/FluidAudio")!)
                    DisclosureGroup("License text") {
                        Text(fluidAudioLicense)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Acknowledgements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
