import SwiftUI
import TrainerCore

/// Runs the trainer calibration: intro and plan, then one screen per step
/// telling the rider what cadence to hold, then the fitted result.
struct CalibrationView: View {
    @Bindable var bridge: BridgeController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Calibration")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(isRunning ? "Stop" : "Close", role: isRunning ? .destructive : nil) {
                            if isRunning { bridge.cancelCalibration() }
                            dismiss()
                        }
                    }
                }
        }
        .interactiveDismissDisabled(isRunning)
    }

    private var isRunning: Bool { bridge.calibrationRun?.phase.isActive ?? false }

    @ViewBuilder
    private var content: some View {
        switch bridge.calibrationRun?.phase {
        case nil, .notStarted?, .cancelled?:
            IntroView(bridge: bridge)
        case .settling?, .sampling?:
            if let run = bridge.calibrationRun { RunningView(bridge: bridge, run: run) }
        case .finished(let result)?:
            ResultView(result: result, unit: bridge.speedUnit, save: {
                bridge.saveCalibration()
                dismiss()
            }, discard: {
                bridge.discardCalibrationResult()
            })
        case .failed(let error)?:
            ContentUnavailableView {
                Label("Calibration failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failureText(error))
            } actions: {
                Button("Back") { bridge.discardCalibrationResult() }
            }
        }
    }

    private func failureText(_ error: CalibrationError) -> String {
        switch error {
        case .insufficientSamples(let n):
            "Only \(n) steps were measured; at least three are needed. Try a lower power cap so every step is rideable."
        case .degenerate:
            "The measurements didn't vary enough in grade and speed to fit the trainer. Hold each step's target cadence and try again."
        }
    }
}

// MARK: - Intro

private struct IntroView: View {
    @Bindable var bridge: BridgeController

    var body: some View {
        let steps = bridge.calibrationPlan.steps(for: bridge.rider)
        let climb = steps.filter { !$0.isFloor }
        let minutes = Double(steps.count) * 20 / 60
        Form {
            Section {
                Text("The app sets a series of grades on the trainer while you hold a target cadence at each. From the speed and power it measures how the trainer's resistance responds, which the calibrated shifting model needs.")
            }
            Section("Before you start") {
                Label("Run Tacx's own calibration first.", systemImage: "1.circle")
                Label("Put the chain in the cog you ride in: \(bridge.rider.realChainring)×\(bridge.rider.realCog).", systemImage: "2.circle")
                Label("Warm up. Zwift can stay paired; its commands wait until calibration ends.", systemImage: "3.circle")
            }
            Section {
                Stepper(value: $bridge.calibrationPowerCap, in: 150...800, step: 25) {
                    LabeledContent("Power cap", value: "\(Int(bridge.calibrationPowerCap)) W")
                }
                LabeledContent("Steps", value: "\(steps.count), about \(Int(minutes.rounded(.up))) min")
                LabeledContent("Steepest grade", value: String(format: "%.0f%%", (climb.map(\.grade).max() ?? 0) * 100))
            } header: {
                Text("Plan")
            } footer: {
                Text("No step asks for more than the power cap. A higher cap reaches steeper grades, so the trainer's limit is measured instead of assumed.")
            }
            if bridge.source == .mock {
                Section {
                    Toggle("Mock rider follows targets", isOn: $bridge.mockFollowsCalibration)
                }
            }
            Section {
                Button("Start calibration") { bridge.startCalibration() }
                    .disabled(!bridge.canCalibrate)
            } footer: {
                if !bridge.isRiding {
                    Text("Start a ride first, so the trainer is connected.")
                } else if !bridge.trainerState.isConnected {
                    Text("Waiting for the trainer to connect.")
                }
            }
        }
    }
}

// MARK: - Running

private struct RunningView: View {
    @Bindable var bridge: BridgeController
    let run: CalibrationRun

    var body: some View {
        let step = run.steps[run.stepIndex]
        List {
            Section {
                VStack(spacing: 8) {
                    Text("Step \(run.stepIndex + 1) of \(run.steps.count)")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("\(Int(step.targetCadence)) rpm")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(String(format: "≈ %@ · grade %.0f%%%@",
                                bridge.speedUnit.format(kilometersPerHour: step.targetSpeed * 3.6),
                                step.grade * 100, step.isFloor ? " (minimum resistance)" : ""))
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    ProgressView(value: run.stepProgress(at: bridge.calibrationTime))
                        .padding(.top, 4)
                    Text(statusText).font(.footnote).foregroundStyle(run.restarts > 0 ? .orange : .secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                LabeledContent("Cadence", value: format(bridge.latestData?.instantaneousCadence, "%.0f rpm"))
                LabeledContent("Speed", value: bridge.latestData?.instantaneousSpeed.map { bridge.speedUnit.format(kilometersPerHour: $0) } ?? "–")
                LabeledContent("Power", value: bridge.latestData?.instantaneousPower.map { "\($0) W" } ?? "–")
            }
            if bridge.source == .mock {
                Section {
                    Toggle("Mock rider follows targets", isOn: $bridge.mockFollowsCalibration)
                    if !bridge.mockFollowsCalibration {
                        CadenceSlider(cadence: $bridge.mockCadence)
                    }
                }
            }
            Section {
                Button("Skip this step") { bridge.skipCalibrationStep() }
            } footer: {
                Text("Skip a step you can't hold. The fit needs at least three measured steps.")
            }
        }
    }

    private var statusText: String {
        switch run.phase {
        case .settling: "Settle into the cadence…"
        case .sampling where run.restarts > 0: "Not steady enough. Hold the cadence, measuring again…"
        case .sampling: "Hold steady, measuring…"
        default: ""
        }
    }

    private func format(_ value: Double?, _ pattern: String) -> String {
        value.map { String(format: pattern, $0) } ?? "–"
    }
}

// MARK: - Result

private struct ResultView: View {
    let result: CalibrationResult
    let unit: SpeedUnit
    let save: () -> Void
    let discard: () -> Void

    var body: some View {
        let c = result.calibration
        Form {
            Section {
                CalibrationSummary(calibration: c, maxGradeMeasured: result.maxGradeMeasured)
                LabeledContent("Fit quality (R²)", value: String(format: "%.3f", result.fit.rSquared))
                LabeledContent("Steps measured", value: "\(result.measurements.count)")
            } header: {
                Text("Result")
            } footer: {
                Text(qualityNote)
            }
            Section("Measurements") {
                ForEach(Array(result.measurements.enumerated()), id: \.offset) { _, m in
                    LabeledContent(
                        String(format: "%@%.0f%% · %@", m.step.isFloor ? "floor " : "", m.step.grade * 100,
                               unit.format(kilometersPerHour: m.sample.speed * 3.6)),
                        value: String(format: "%.0f W · %.1f N", m.sample.power, m.sample.force)
                    )
                    .monospacedDigit()
                }
            }
            Section {
                Button("Save and use") { save() }
                Button("Discard", role: .destructive) { discard() }
            }
        }
    }

    private var qualityNote: String {
        let rms = result.calibration.residualRMS ?? 0
        if result.fit.rSquared < 0.95 || rms > 5 {
            return "The fit is loose. Steadier cadence at each step, or a fresh Tacx calibration, usually helps."
        }
        return "Good fit. Calibrated shifting will use these values."
    }
}

/// The fitted values in rider-friendly terms; also used in Settings.
struct CalibrationSummary: View {
    let calibration: TrainerCalibration
    let maxGradeMeasured: Bool

    var body: some View {
        LabeledContent("Simulated mass", value: String(format: "%.0f kg", calibration.b / BikePhysics.gravity))
        LabeledContent("Trainer drag", value: String(format: "%.1f N + %.2f N per m/s", calibration.a, calibration.c))
        LabeledContent("Max grade", value: String(format: "%.0f%%%@", calibration.maxGrade * 100, maxGradeMeasured ? "" : " (assumed)"))
        LabeledContent("Min force", value: String(format: "%.1f N + %.2f N per m/s",
                                                  calibration.floorForce.intercept, calibration.floorForce.slope))
        if let rms = calibration.residualRMS {
            LabeledContent("Fit error (RMS)", value: String(format: "%.1f N", rms))
        }
    }
}
