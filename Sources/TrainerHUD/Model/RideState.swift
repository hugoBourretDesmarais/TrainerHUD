import Foundation
import Combine

enum ConnectionStatus: Equatable {
    case disconnected, connecting, connected, ready, stalled

    var symbol: String {
        switch self {
        case .disconnected: return "○"
        case .connecting: return "◔"
        case .connected: return "◑"
        case .ready: return "●"
        case .stalled: return "⚠"
        }
    }
}

enum TrainerMode: String { case sim, erg }

final class RideState: ObservableObject {
    @Published var power: Int = 0
    @Published var power3s: Int = 0
    @Published var cadence: Int = 0
    @Published var heartRate: Int = 0
    @Published var speedKmh: Double = 0
    @Published var resistance: Int?
    @Published var gearIndex: Int = 11
    @Published var gearCount: Int = 24
    @Published var gearRatio: Double = 2.40
    @Published var gradePercent: Double = 0
    @Published var mode: TrainerMode = .sim
    @Published var ergTarget: Int = 150
    @Published var elapsed: TimeInterval = 0
    @Published var timerRunning = false
    @Published var distanceKm: Double = 0
    @Published var kilojoules: Double = 0
    @Published var avgPower: Int = 0
    @Published var avgHeartRate: Int = 0
    @Published var maxHeartRate: Int = 0
    @Published var normalizedPower: Int = 0
    @Published var workout: Workout?
    @Published var workoutElapsed: TimeInterval = 0
    @Published var workoutPaused = false
    @Published var ergHeldOff = false
    @Published var lastShift: (up: Bool, at: Date)?
    @Published var toast: String?

    @Published var trainerStatus: ConnectionStatus = .disconnected
    @Published var trainerName: String = ""
    @Published var trainerHasZwiftProtocol = false
    @Published var heartRateStatus: ConnectionStatus = .disconnected
    @Published var powerMeterStatus: ConnectionStatus = .disconnected
    @Published var controllerStatuses: [String: ConnectionStatus] = [:]
    @Published var controllerBattery: [String: Int] = [:]
    @Published var bluetoothOn = false

    var powerSource: String = ""
    private var powerHistory: [(Date, Int)] = []
    private var powerSum: Double = 0
    private var powerSamples = 0
    private var hrSum: Double = 0
    private var hrSamples = 0
    private var npWindow: [Int] = []
    private var np4Sum: Double = 0
    private var np4Samples = 0
    private var lastTick = Date()
    private var lastActivity = Date.distantPast
    private var toastTimer: Timer?

    func updatePower(_ w: Int, source: String) {
        power = w
        powerSource = source
        let now = Date()
        powerHistory.append((now, w))
        powerHistory.removeAll { now.timeIntervalSince($0.0) > 3 }
        power3s = powerHistory.isEmpty ? w : Int((Double(powerHistory.map(\.1).reduce(0, +)) / Double(powerHistory.count)).rounded())
        if w > 0 { lastActivity = now }
    }

    func updateCadence(_ rpm: Int) {
        cadence = rpm
        if rpm > 0 { lastActivity = Date() }
    }

    func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        let active = now.timeIntervalSince(lastActivity) < 5
        if active && !timerRunning && elapsed == 0 { timerRunning = true }
        if timerRunning && active {
            elapsed += dt
            if workout != nil && !workoutPaused { workoutElapsed += dt }
            npWindow.append(power)
            if npWindow.count > 30 { npWindow.removeFirst() }
            if npWindow.count == 30 {
                np4Sum += pow(Double(npWindow.reduce(0, +)) / 30, 4); np4Samples += 1
                normalizedPower = Int(pow(np4Sum / Double(np4Samples), 0.25).rounded())
            }
            distanceKm += speedKmh * dt / 3600
            kilojoules += Double(power) * dt / 1000
            powerSum += Double(power); powerSamples += 1
            avgPower = Int((powerSum / Double(powerSamples)).rounded())
            if heartRate > 0 {
                hrSum += Double(heartRate); hrSamples += 1
                avgHeartRate = Int((hrSum / Double(hrSamples)).rounded())
            }
        }
        if heartRate > maxHeartRate { maxHeartRate = heartRate }
        if !active {
            if power3s != 0 && now.timeIntervalSince(powerHistory.last?.0 ?? .distantPast) > 3 { power3s = 0; power = 0 }
        }
    }

    func resetRide() {
        elapsed = 0
        distanceKm = 0
        kilojoules = 0
        avgPower = 0
        avgHeartRate = 0
        maxHeartRate = 0
        powerSum = 0; powerSamples = 0
        hrSum = 0; hrSamples = 0
        npWindow = []; np4Sum = 0; np4Samples = 0; normalizedPower = 0
        workoutElapsed = 0
        timerRunning = false
        showToast("Ride reset")
    }

    func showToast(_ s: String, seconds: Double = 2.5) {
        toast = s
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.toast = nil
        }
    }

    var elapsedString: String { Self.clock(elapsed.rounded(.down)) }

    static func clock(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds.rounded(.up)))
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) }
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    var workoutPosition: (index: Int, offset: TimeInterval)? { workout?.position(at: workoutElapsed) }

    func workoutTargetWatts(ftp: Int) -> Int? {
        guard let w = workout, let p = workoutPosition, !w.steps[p.index].isFree else { return nil }
        return Int((w.steps[p.index].fraction(at: p.offset) * Double(ftp)).rounded())
    }
}
