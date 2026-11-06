import SwiftUI
import TrainerCore

/// The mock rider's cadence slider, 0–120 rpm. Non-linear (see `CadenceScale`):
/// 60–100 rpm takes 70 % of the track; 0–60 and 100–120 go by quickly.
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
