import Foundation
import AppKit

final class Session {
    let settings = Settings()
    let state = RideState()
    private(set) var ble: BLEManager!
    weak var overlay: OverlayController?
    private var timer: Timer?
    private var trainer: TrainerDevice?
    private var controllers: [UUID: ZwiftControllerDevice] = [:]
    private var pedalPowerAt = Date.distantPast
    private var trainerPowerAt = Date.distantPast
    private var lastTrainerSpeedAt = Date.distantPast
    var onDevicesChanged: (() -> Void)?
    private let library = WorkoutLibrary()
    private var lastWorkoutStep: Int?
    private var dismissedWorkout: URL?

    init() {
        state.gearIndex = settings.clampedStartGear
        state.gearCount = settings.gearRatios.count
        state.gearRatio = settings.gearRatios[state.gearIndex]
        state.gradePercent = settings.gradePercent
        state.ergTarget = settings.ergTargetWatts
        ble = BLEManager(session: self)
        ble.onChange = { [weak self] in self?.onDevicesChanged?() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        library.onChange = { [weak self] in self?.loadTodaysWorkout() }
        loadTodaysWorkout()
    }

    private func tick() {
        state.tick()
        driveWorkout()
        let now = Date()
        for (_, c) in controllers where c.checkStall(now: now) {
            if state.controllerStatuses[c.id.uuidString] != .stalled {
                controllerStatusChanged(c, .stalled)
                Log.warn("\(c.displayName): no frames for 45 s (Click v2 lock, or asleep)")
            }
        }
        if state.cadence > 0, now.timeIntervalSince(lastCadenceAt) > 4 { state.updateCadence(0) }
        if now.timeIntervalSince(lastTrainerSpeedAt) > 4, state.speedKmh > 0 { state.speedKmh = 0 }
    }

    // MARK: Gear / grade / mode

    func currentGearRatioX10000() -> Int {
        let ratio = settings.gearRatios[min(state.gearIndex, settings.gearRatios.count - 1)]
        var effective = ratio
        if settings.gearScaling == .relativeToPhysical, settings.physicalCog > 0 {
            let physical = Double(settings.physicalChainring) / Double(settings.physicalCog)
            effective = ratio * 3.0 / physical
        }
        return Int((effective * 10000).rounded())
    }

    func effectiveFTMSGrade() -> Double {
        let steps = state.gearIndex - settings.clampedStartGear
        return state.gradePercent + Double(steps) * settings.ftmsGearGradeStep
    }

    func shift(up: Bool) {
        let count = settings.gearRatios.count
        let next = state.gearIndex + (up ? 1 : -1)
        guard next >= 0, next < count else {
            state.showToast(up ? "Top gear" : "Lowest gear", seconds: 1)
            return
        }
        state.gearIndex = next
        state.gearRatio = settings.gearRatios[next]
        state.gearCount = count
        state.lastShift = (up, Date())
        if state.mode == .erg {
            state.mode = .sim
            state.showToast("SIM mode", seconds: 1)
            trainer?.setErg(watts: nil)
        }
        trainer?.setGear(ratioX10000: currentGearRatioX10000())
        Log.info("Shift \(up ? "up" : "down") → gear \(next + 1)/\(count) ratio \(state.gearRatio)")
        if settings.hapticOnShift { controllers.values.forEach { $0.vibrate() } }
    }

    func setGear(index: Int) {
        guard index >= 0, index < settings.gearRatios.count else { return }
        state.gearIndex = index
        state.gearRatio = settings.gearRatios[index]
        trainer?.setGear(ratioX10000: currentGearRatioX10000())
    }

    func setGrade(_ percent: Double) {
        let g = min(max(percent, -10), 20)
        state.gradePercent = (g * 10).rounded() / 10
        settings.gradePercent = state.gradePercent
        trainer?.setGrade(percent: state.gradePercent)
    }

    func setErg(enabled: Bool) {
        if enabled {
            state.mode = .erg
            trainer?.setErg(watts: state.ergTarget)
            state.showToast("ERG \(state.ergTarget) W", seconds: 1.5)
        } else {
            state.mode = .sim
            trainer?.setErg(watts: nil)
            state.showToast("SIM mode", seconds: 1)
        }
    }

    /// User intent: during a workout, ERG off holds until turned back on; on resumes the current step's target.
    func userSetErg(_ enabled: Bool) {
        state.ergHeldOff = state.workout != nil && !enabled
        if enabled, let t = state.workoutTargetWatts(ftp: settings.ftpWatts) { state.ergTarget = t }
        if enabled, state.workout != nil, state.workoutTargetWatts(ftp: settings.ftpWatts) == nil {
            state.showToast("Free-ride step: ERG resumes at next step", seconds: 2)
            return
        }
        setErg(enabled: enabled)
    }

    func setErgTarget(_ watts: Int) {
        state.ergTarget = min(max(watts, 30), 1500)
        settings.ergTargetWatts = state.ergTarget
        if state.mode == .erg { trainer?.setErg(watts: state.ergTarget) }
    }

    func gearSettingsChanged() {
        state.gearCount = settings.gearRatios.count
        state.gearIndex = min(state.gearIndex, settings.gearRatios.count - 1)
        state.gearRatio = settings.gearRatios[state.gearIndex]
        trainer?.setGear(ratioX10000: currentGearRatioX10000())
    }

    func perform(_ action: ButtonAction) {
        switch action {
        case .none: break
        case .shiftUp: shift(up: true)
        case .shiftDown: shift(up: false)
        case .gradeUp: setGrade(state.gradePercent + 0.5)
        case .gradeDown: setGrade(state.gradePercent - 0.5)
        case .gradeReset: setGrade(0)
        case .toggleTimer:
            state.timerRunning.toggle()
            state.showToast(state.timerRunning ? "Timer running" : "Timer paused", seconds: 1.5)
        case .resetRide: state.resetRide()
        case .toggleOverlay: overlay?.toggleVisible()
        case .minimizeOverlay: settings.overlayMode = settings.overlayMode.next
        case .toggleErg: userSetErg(state.mode != .erg)
        case .ergUp: setErgTarget(state.ergTarget + 5)
        case .ergDown: setErgTarget(state.ergTarget - 5)
        case .workoutPause: toggleWorkoutPause()
        case .workoutSkip: skipWorkoutStep(forward: true)
        case .workoutBack: skipWorkoutStep(forward: false)
        }
    }

    // MARK: Workout

    func loadTodaysWorkout(force: Bool = false) {
        guard let url = WorkoutLibrary.todays() else {
            if force { state.showToast("No workout for today in the workouts folder") }
            return
        }
        if !force {
            if url == dismissedWorkout { return }
            if let cur = state.workout?.source, cur == url, WorkoutLibrary.modDate(url) <= loadedAt { return }
        }
        loadWorkout(url)
    }

    private var loadedAt = Date.distantPast

    func loadWorkout(_ url: URL) {
        guard let w = ZWOParser.load(url) else {
            Log.warn("Workout: could not parse \(url.lastPathComponent)")
            state.showToast("Can't read \(url.lastPathComponent)")
            return
        }
        loadedAt = Date()
        dismissedWorkout = nil
        state.workout = w
        state.workoutElapsed = 0
        state.workoutPaused = false
        state.ergHeldOff = false
        lastWorkoutStep = nil
        Log.info("Workout loaded: \(w.name), \(w.steps.count) steps, \(RideState.clock(w.totalDuration))")
        state.showToast("Workout: \(w.name) · \(RideState.clock(w.totalDuration)) · starts when you pedal", seconds: 4)
    }

    func stopWorkout() {
        dismissedWorkout = state.workout?.source
        state.workout = nil
        state.workoutElapsed = 0
        state.ergHeldOff = false
        lastWorkoutStep = nil
        if state.mode == .erg { setErg(enabled: false) }
    }

    func toggleWorkoutPause() {
        guard state.workout != nil else { return }
        state.workoutPaused.toggle()
        state.showToast(state.workoutPaused ? "Workout paused" : "Workout resumed", seconds: 1.5)
        if state.workoutPaused, state.mode == .erg { setErg(enabled: false) }
        if !state.workoutPaused { lastWorkoutStep = nil }
    }

    func skipWorkoutStep(forward: Bool) {
        guard let w = state.workout else { return }
        let pos = state.workoutPosition
        let i = pos?.index ?? w.steps.count
        let target = forward ? i + 1 : ((pos?.offset ?? 0) > 5 ? i : i - 1)
        state.workoutElapsed = w.stepStart(max(0, target))
        driveWorkout()
    }

    private func driveWorkout() {
        guard let w = state.workout, !state.workoutPaused else { return }
        guard let pos = state.workoutPosition else {
            Log.info("Workout complete: \(w.name)")
            state.showToast("Workout complete · \(state.avgPower) W avg · NP \(state.normalizedPower)", seconds: 6)
            stopWorkout()
            return
        }
        let step = w.steps[pos.index]
        let target = state.workoutTargetWatts(ftp: settings.ftpWatts)
        if !state.timerRunning {
            if let target { state.ergTarget = target }
            return
        }
        if pos.index != lastWorkoutStep {
            lastWorkoutStep = pos.index
            Log.info("Workout step \(pos.index + 1)/\(w.steps.count) \(step.label) \(target.map { "\($0) W" } ?? "free") for \(Int(step.duration)) s")
            if let target {
                state.ergTarget = target
                if !state.ergHeldOff { setErg(enabled: true) }
            } else if state.mode == .erg {
                setErg(enabled: false)
            }
        } else if let target, target != state.ergTarget {
            state.ergTarget = target
            if state.mode == .erg { trainer?.setErg(watts: target) }
        }
    }

    // MARK: Device callbacks

    func remember(id: UUID, role: DeviceRole) {
        let s = id.uuidString
        switch role {
        case .trainer: settings.rememberedTrainer = s
        case .heartRate: settings.rememberedHeartRate = s
        case .powerMeter: settings.rememberedPowerMeter = s
        case .controller: if !settings.rememberedControllers.contains(s) { settings.rememberedControllers.append(s) }
        }
    }

    func forget(id: UUID) {
        let s = id.uuidString
        if settings.rememberedTrainer == s { settings.rememberedTrainer = nil }
        if settings.rememberedHeartRate == s { settings.rememberedHeartRate = nil }
        if settings.rememberedPowerMeter == s { settings.rememberedPowerMeter = nil }
        settings.rememberedControllers.removeAll { $0 == s }
    }

    func handlerCreated(_ h: DeviceHandler, id: UUID, name: String) {
        switch h {
        case let t as TrainerDevice:
            trainer = t
            state.trainerName = name
            state.trainerStatus = .connecting
        case let c as ZwiftControllerDevice:
            controllers[id] = c
            state.controllerStatuses[id.uuidString] = .connecting
        case is HeartRateDevice: state.heartRateStatus = .connecting
        case is PowerMeterDevice: state.powerMeterStatus = .connecting
        default: break
        }
    }

    func handlerConnected(_ h: DeviceHandler, id: UUID) {
        switch h {
        case is TrainerDevice: state.trainerStatus = .connected
        case is ZwiftControllerDevice: state.controllerStatuses[id.uuidString] = .connected
        case is HeartRateDevice: state.heartRateStatus = .ready
        case is PowerMeterDevice: state.powerMeterStatus = .ready
        default: break
        }
    }

    func handlerDropped(_ h: DeviceHandler, id: UUID) {
        switch h {
        case is TrainerDevice:
            state.trainerStatus = .connecting
            state.trainerHasZwiftProtocol = false
        case is ZwiftControllerDevice: state.controllerStatuses[id.uuidString] = .connecting
        case is HeartRateDevice: state.heartRateStatus = .connecting; state.heartRate = 0
        case is PowerMeterDevice: state.powerMeterStatus = .connecting
        default: break
        }
    }

    func handlerDisconnected(_ h: DeviceHandler, id: UUID) {
        switch h {
        case is TrainerDevice:
            trainer = nil
            state.trainerStatus = .disconnected
            state.trainerHasZwiftProtocol = false
            state.trainerName = ""
        case is ZwiftControllerDevice:
            controllers[id] = nil
            state.controllerStatuses[id.uuidString] = nil
            state.controllerBattery[id.uuidString] = nil
        case is HeartRateDevice: state.heartRateStatus = .disconnected; state.heartRate = 0
        case is PowerMeterDevice: state.powerMeterStatus = .disconnected
        default: break
        }
    }

    func trainerCapabilitiesChanged() {
        state.trainerHasZwiftProtocol = trainer?.hasZwiftProtocol ?? false
    }

    func trainerZwiftReady(_ ready: Bool) {
        state.trainerHasZwiftProtocol = ready
        state.trainerStatus = .ready
        if ready {
            state.showToast("Virtual shifting ready", seconds: 2)
        } else if trainer?.hasFTMSControl == true {
            state.showToast("FTMS fallback (grade steps)", seconds: 3)
            trainer?.setGrade(percent: state.gradePercent)
        }
    }

    private var lastCadenceAt = Date.distantPast

    func trainerReport(power: Int?, cadence: Int?, speedKmh: Double?, resistance: Int?, source: String) {
        if state.trainerStatus == .connected { state.trainerStatus = .ready }
        let pedalsFresh = Date().timeIntervalSince(pedalPowerAt) < 3
        if let power, !(settings.preferPedalsForPower && pedalsFresh) {
            trainerPowerAt = Date()
            state.updatePower(power, source: "trainer")
        }
        if let cadence, !(settings.preferPedalsForPower && pedalsFresh && source != "ftms") {
            lastCadenceAt = Date()
            state.updateCadence(cadence)
        }
        if let speedKmh {
            lastTrainerSpeedAt = Date()
            state.speedKmh = speedKmh
        }
        if let resistance { state.resistance = resistance }
    }

    func trainerZwiftData(_ t: TrainerData) {
        if let s = t.speedX100 {
            lastTrainerSpeedAt = Date()
            state.speedKmh = Double(s) / 100 * 3.6
        }
        if Date().timeIntervalSince(trainerPowerAt) > 2, Date().timeIntervalSince(pedalPowerAt) > 2 {
            if let p = t.power { state.updatePower(p, source: "zwift") }
            if let c = t.cadence { lastCadenceAt = Date(); state.updateCadence(c) }
        }
    }

    func powerMeterReport(power: Int, cadence: Int?) {
        pedalPowerAt = Date()
        if settings.preferPedalsForPower || Date().timeIntervalSince(trainerPowerAt) > 3 {
            state.updatePower(power, source: "pedals")
            if let cadence { lastCadenceAt = Date(); state.updateCadence(cadence) }
        }
    }

    func heartRateReport(bpm: Int) {
        state.heartRate = bpm
    }

    func controllerStatusChanged(_ c: ZwiftControllerDevice, _ status: ConnectionStatus) {
        if state.controllerStatuses[c.id.uuidString] != status {
            state.controllerStatuses[c.id.uuidString] = status
        }
    }

    func controllerIdentified(_ c: ZwiftControllerDevice) {
        if let t = c.type { settings.controllerTypes[c.id.uuidString] = Int(t.rawValue) }
        // Republish so the HUD re-renders the label.
        let st = state.controllerStatuses[c.id.uuidString]
        state.controllerStatuses[c.id.uuidString] = st
    }

    func controllerBattery(_ c: ZwiftControllerDevice, _ pct: Int) {
        state.controllerBattery[c.id.uuidString] = pct
    }

    private static let rightSideButtons: Set<ControllerButton> = [.a, .b, .y, .z, .shiftUpRight, .shiftDownRight, .powerUpRight, .onOffRight, .paddleRight]
    private var lastPress: [ControllerButton: (UUID, Date)] = [:]

    func controllerPressed(_ button: ControllerButton, from c: ZwiftControllerDevice) {
        // The Click v2 left puck relays the right puck's buttons; drop the relay when the right puck is connected itself.
        if c.type == .clickV2Left, Session.rightSideButtons.contains(button),
           controllers.values.contains(where: { $0.type == .clickV2Right && $0.handshakeDone }) {
            return
        }
        let now = Date()
        if let (id, at) = lastPress[button], id != c.id, now.timeIntervalSince(at) < 0.2 { return }
        lastPress[button] = (c.id, now)
        let action = settings.buttonActions[button] ?? ButtonAction.none
        Log.info("\(c.displayName) pressed \(button.rawValue) → \(action.rawValue)")
        perform(action)
    }

    func controllerLabel(_ id: String) -> String {
        controllers.first { $0.key.uuidString == id }?.value.shortLabel ?? "Ctrl"
    }

    func resetControllers() { controllers.values.forEach { $0.requestReset() } }

    func markZwiftUnlockNow() {
        settings.lastZwiftUnlock = Date()
        state.showToast("Marked Click v2 as unlocked", seconds: 2)
    }

    func shutdown() {
        trainer?.releaseVirtualShifting()
    }
}
