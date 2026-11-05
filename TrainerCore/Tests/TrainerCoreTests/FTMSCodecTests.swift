import Testing
@testable import TrainerCore

// Fixtures are hand-built from the FTMS spec. Replace or extend them with
// packets captured from the Flux S and Zwift once the bridge can log them.

@Suite("Indoor Bike Data")
struct IndoorBikeDataTests {
    @Test func decodesSpeedCadencePower() throws {
        // flags 0x0044: speed present (More Data = 0), cadence, power.
        // 31.50 km/h = 3150 = 0x0C4E; 85 rpm = 170 half-rpm; 177 W.
        let bytes: [UInt8] = [0x44, 0x00, 0x4E, 0x0C, 0xAA, 0x00, 0xB1, 0x00]
        let data = try IndoorBikeData(bytes: bytes)

        #expect(data.instantaneousSpeed == 31.5)
        #expect(data.instantaneousCadence == 85)
        #expect(data.instantaneousPower == 177)
        #expect(data.averageSpeed == nil)
        #expect(data.totalDistance == nil)
        #expect(data.encoded() == bytes)
    }

    @Test func moreDataFlagMeansSpeedIsAbsent() throws {
        let data = try IndoorBikeData(bytes: [0x41, 0x00, 0xB1, 0x00])
        #expect(data.instantaneousSpeed == nil)
        #expect(data.instantaneousPower == 177)
    }

    @Test func decodesNegativePower() throws {
        let data = try IndoorBikeData(bytes: [0x40, 0x00, 0x00, 0x00, 0xF6, 0xFF])
        #expect(data.instantaneousPower == -10)
    }

    @Test func speedInMetersPerSecond() {
        let data = IndoorBikeData(instantaneousSpeed: 36)
        #expect(data.speedMetersPerSecond == 10)
    }

    @Test func roundTripsEveryField() throws {
        let data = IndoorBikeData(
            instantaneousSpeed: 30.25,
            averageSpeed: 28.5,
            instantaneousCadence: 90.5,
            averageCadence: 88,
            totalDistance: 12345,
            resistanceLevel: 20,
            instantaneousPower: 250,
            averagePower: 230,
            expendedEnergy: .init(total: 100, perHour: 600, perMinute: 10),
            heartRate: 150,
            metabolicEquivalent: 7.5,
            elapsedTime: 3600,
            remainingTime: 600
        )
        let bytes = data.encoded()
        #expect(bytes.count == 2 + 2 + 2 + 2 + 2 + 3 + 2 + 2 + 2 + 5 + 1 + 1 + 2 + 2)
        #expect(try IndoorBikeData(bytes: bytes) == data)
    }

    @Test func truncatedValueThrows() {
        #expect(throws: FTMSDecodingError.self) {
            try IndoorBikeData(bytes: [0x44, 0x00, 0x4E])
        }
    }
}

@Suite("Control Point")
struct ControlPointTests {
    @Test func decodesSimulationParameters() throws {
        // grade 5 % = 500 (0x01F4), Crr 0.004 = 40, Cw 0.51 = 51.
        let bytes: [UInt8] = [0x11, 0x00, 0x00, 0xF4, 0x01, 0x28, 0x33]
        let request = try ControlPointRequest(bytes: bytes)
        #expect(request == .setIndoorBikeSimulation(.init(windSpeed: 0, grade: 0.05, crr: 0.004, cw: 0.51)))
        #expect(request.encoded() == bytes)
    }

    @Test func encodesNegativeGradeAndTailwind() {
        let request = ControlPointRequest.setIndoorBikeSimulation(
            .init(windSpeed: -3.5, grade: -0.025, crr: 0.004, cw: 0.51)
        )
        // -3500 = 0xF254, -250 = 0xFF06.
        #expect(request.encoded() == [0x11, 0x54, 0xF2, 0x06, 0xFF, 0x28, 0x33])
    }

    @Test func simpleCommands() throws {
        #expect(try ControlPointRequest(bytes: [0x00]) == .requestControl)
        #expect(try ControlPointRequest(bytes: [0x05, 0xC8, 0x00]) == .setTargetPower(watts: 200))
        #expect(try ControlPointRequest(bytes: [0x08, 0x02]) == .stopOrPause(.pause))
    }

    @Test func unknownOpcodeIsUnsupported() throws {
        let request = try ControlPointRequest(bytes: [0x42, 0x01, 0x02])
        #expect(request == .unsupported(opcode: 0x42, parameters: [0x01, 0x02]))
        #expect(request.opcode == 0x42)
        #expect(request.encoded() == [0x42, 0x01, 0x02])
    }

    @Test func truncatedSimulationThrows() {
        #expect(throws: FTMSDecodingError.self) {
            try ControlPointRequest(bytes: [0x11, 0x00])
        }
    }

    @Test(arguments: [
        ControlPointRequest.requestControl,
        .reset,
        .setTargetSpeed(kmh: 32.5),
        .setTargetInclination(percent: -4.5),
        .setTargetResistanceLevel(12.5),
        .setTargetPower(watts: 250),
        .setTargetHeartRate(bpm: 140),
        .startOrResume,
        .stopOrPause(.stop),
        .setIndoorBikeSimulation(.init(windSpeed: 1.25, grade: 0.0725, crr: 0.0041, cw: 0.42)),
        .setWheelCircumference(millimeters: 2105.5),
        .spinDownControl(.start),
        .setTargetedCadence(rpm: 92.5),
    ])
    func requestRoundTrips(_ request: ControlPointRequest) throws {
        #expect(try ControlPointRequest(bytes: request.encoded()) == request)
    }

    @Test func responseEncodesAndDecodes() throws {
        let response = ControlPointResponse(to: .setIndoorBikeSimulation(.flat), result: .success)
        #expect(response.encoded() == [0x80, 0x11, 0x01])
        #expect(try ControlPointResponse(bytes: [0x80, 0x11, 0x01]) == response)
    }

    @Test func responseRejectsWrongOpcode() {
        #expect(throws: FTMSDecodingError.unexpectedOpcode(0x11)) {
            try ControlPointResponse(bytes: [0x11, 0x00, 0x01])
        }
    }

    @Test func simulationParametersQuantize() {
        let p = SimulationParameters(windSpeed: 0.00049, grade: 0.051234, crr: 0.00404, cw: 0.5149)
        #expect(p.quantized == SimulationParameters(windSpeed: 0, grade: 0.0512, crr: 0.004, cw: 0.51))
    }
}

@Suite("Feature, ranges and status")
struct FeatureAndStatusTests {
    @Test func featureBitfields() throws {
        let feature = FitnessMachineFeature(
            machine: [.cadence, .powerMeasurement],
            targetSetting: [.power, .indoorBikeSimulation]
        )
        let bytes: [UInt8] = [0x02, 0x40, 0x00, 0x00, 0x08, 0x20, 0x00, 0x00]
        #expect(feature.encoded() == bytes)
        #expect(try FitnessMachineFeature(bytes: bytes) == feature)
    }

    @Test func rangesRoundTrip() throws {
        let power = SupportedPowerRange(minimum: 0, maximum: 1500, increment: 1)
        #expect(try SupportedPowerRange(bytes: power.encoded()) == power)

        let resistance = SupportedResistanceLevelRange(minimum: 0, maximum: 100, increment: 1)
        #expect(try SupportedResistanceLevelRange(bytes: resistance.encoded()) == resistance)
    }

    @Test(arguments: [
        FitnessMachineStatus.reset,
        .stoppedOrPausedByUser(.pause),
        .stoppedBySafetyKey,
        .startedOrResumedByUser,
        .targetPowerChanged(watts: 210),
        .indoorBikeSimulationParametersChanged(.init(windSpeed: 0, grade: 0.03, crr: 0.004, cw: 0.51)),
        .wheelCircumferenceChanged(millimeters: 2100),
        .controlPermissionLost,
        .other(opcode: 0x14, parameters: [0x01]),
    ])
    func statusRoundTrips(_ status: FitnessMachineStatus) throws {
        #expect(try FitnessMachineStatus(bytes: status.encoded()) == status)
    }
}
