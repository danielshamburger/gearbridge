import SwiftUI
import TrainerCore

/// The mock rider's cadence slider, 0–120 rpm. Non-linear (see `CadenceScale`):
/// 0–60 rpm flies by in the first 8 % of the track; 60–100 rpm gets most of it.
struct CadenceSlider: View {
    @Binding var cadence: Double
    private let scale = CadenceScale()

    var body: some View {
        Slider(value: Binding {
            scale.position(for: cadence)
        } set: { position in
            cadence = scale.cadence(at: position)
        })
        .accessibilityValue("\(Int(cadence)) rpm")
    }
}
