import Foundation
import Combine

enum ButtonAction: String, CaseIterable, Codable {
    case none, shiftUp, shiftDown, gradeUp, gradeDown, gradeReset, toggleTimer, resetRide, toggleOverlay, minimizeOverlay, toggleErg, ergUp, ergDown, workoutPause, workoutSkip, workoutBack

    var label: String {
        switch self {
        case .none: return "Nothing"
        case .shiftUp: return "Shift up"
        case .shiftDown: return "Shift down"
        case .gradeUp: return "Grade +0.5%"
        case .gradeDown: return "Grade −0.5%"
        case .gradeReset: return "Grade → 0%"
        case .toggleTimer: return "Pause / resume timer"
        case .resetRide: return "Reset ride"
        case .toggleOverlay: return "Show / hide overlay"
        case .minimizeOverlay: return "Cycle overlay mode"
        case .toggleErg: return "Toggle ERG mode"
        case .ergUp: return "ERG target +5 W"
        case .ergDown: return "ERG target −5 W"
        case .workoutPause: return "Workout start / pause"
        case .workoutSkip: return "Workout next step"
        case .workoutBack: return "Workout previous step"
        }
    }
}

enum ClickV2LeftMode: String, CaseIterable, Codable {
    case unlockWithZwift, restartLoop, ignore

    var label: String {
        switch self {
        case .unlockWithZwift: return "Unlocked via Zwift (daily)"
        case .restartLoop: return "Restart loop (reboot every ~50 s)"
        case .ignore: return "Don't use left puck"
        }
    }
}

enum GearScaling: String, CaseIterable, Codable {
    case absolute, relativeToPhysical

    var label: String {
        switch self {
        case .absolute: return "Zwift ratio as-is"
        case .relativeToPhysical: return "Scale by physical gear (QZ style)"
        }
    }
}

enum OverlayMode: String, CaseIterable, Codable {
    case minimal, standard, full

    var label: String {
        switch self {
        case .minimal: return "Minimal"
        case .standard: return "Standard"
        case .full: return "Full"
        }
    }

    var next: OverlayMode { OverlayMode.allCases[(OverlayMode.allCases.firstIndex(of: self)! + 1) % OverlayMode.allCases.count] }
}

final class Settings: ObservableObject {
    static let zwiftGears: [Double] = [0.75, 0.87, 0.99, 1.11, 1.23, 1.38, 1.53, 1.68, 1.86, 2.04, 2.22, 2.40,
                                       2.61, 2.82, 3.03, 3.24, 3.49, 3.74, 3.99, 4.24, 4.54, 4.84, 5.14, 5.49]

    static let defaultButtonActions: [ControllerButton: ButtonAction] = [
        .shiftUpRight: .shiftUp, .b: .shiftDown, .a: .toggleTimer, .y: .toggleOverlay, .z: .gradeReset,
        .shiftUpLeft: .shiftDown, .up: .gradeUp, .down: .gradeDown,
        .clickPlus: .shiftUp, .clickMinus: .shiftDown,
        .paddleRight: .shiftUp, .paddleLeft: .shiftDown,
        .shiftDownRight: .shiftDown, .shiftDownLeft: .shiftUp,
    ]

    private let d = UserDefaults.standard
    private var loading = true

    @Published var riderWeightKg: Double { didSet { save() } }
    @Published var bikeWeightKg: Double { didSet { save() } }
    @Published var gearRatios: [Double] { didSet { save() } }
    @Published var startGearIndex: Int { didSet { save() } }
    @Published var gearScaling: GearScaling { didSet { save() } }
    @Published var physicalChainring: Int { didSet { save() } }
    @Published var physicalCog: Int { didSet { save() } }
    @Published var gradePercent: Double { didSet { save() } }
    @Published var ftmsGearGradeStep: Double { didSet { save() } }
    @Published var ergTargetWatts: Int { didSet { save() } }
    @Published var ftpWatts: Int { didSet { save() } }
    @Published var maxHeartRate: Int { didSet { save() } }

    @Published var overlayScale: Double { didSet { save() } }
    @Published var overlayOpacity: Double { didSet { save() } }
    @Published var overlayLocked: Bool { didSet { save() } }
    @Published var overlayMode: OverlayMode { didSet { save() } }
    @Published var overlayVisible: Bool { didSet { save() } }
    @Published var overlayFrame: CGRect? { didSet { save() } }
    @Published var showPower: Bool { didSet { save() } }
    @Published var showCadence: Bool { didSet { save() } }
    @Published var showHeartRate: Bool { didSet { save() } }
    @Published var showSpeed: Bool { didSet { save() } }
    @Published var showTime: Bool { didSet { save() } }
    @Published var showGear: Bool { didSet { save() } }
    @Published var showGrade: Bool { didSet { save() } }
    @Published var showResistance: Bool { didSet { save() } }
    @Published var showDistance: Bool { didSet { save() } }
    @Published var showClock: Bool { didSet { save() } }

    @Published var clickV2LeftMode: ClickV2LeftMode { didSet { save() } }
    @Published var lastZwiftUnlock: Date? { didSet { save() } }
    @Published var controllerKeepAlive: Bool { didSet { save() } }
    @Published var hapticOnShift: Bool { didSet { save() } }
    @Published var buttonActions: [ControllerButton: ButtonAction] { didSet { save() } }

    @Published var preferPedalsForPower: Bool { didSet { save() } }
    @Published var autoConnect: Bool { didSet { save() } }
    @Published var rememberedTrainer: String? { didSet { save() } }
    @Published var rememberedHeartRate: String? { didSet { save() } }
    @Published var rememberedPowerMeter: String? { didSet { save() } }
    @Published var rememberedControllers: [String] { didSet { save() } }
    @Published var controllerTypes: [String: Int] { didSet { save() } }

    init() {
        let d = UserDefaults.standard
        func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
        func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }

        riderWeightKg = dbl("riderWeightKg", 75)
        bikeWeightKg = dbl("bikeWeightKg", 8.31)
        gearRatios = (d.array(forKey: "gearRatios") as? [Double]).flatMap { $0.isEmpty ? nil : $0 } ?? Settings.zwiftGears
        startGearIndex = int("startGearIndex", 11)
        gearScaling = GearScaling(rawValue: d.string(forKey: "gearScaling") ?? "") ?? .absolute
        physicalChainring = int("physicalChainring", 42)
        physicalCog = int("physicalCog", 14)
        gradePercent = dbl("gradePercent", 0)
        ftmsGearGradeStep = dbl("ftmsGearGradeStep", 0.5)
        ergTargetWatts = int("ergTargetWatts", 150)
        ftpWatts = int("ftpWatts", 200)
        maxHeartRate = int("maxHeartRate", 185)

        overlayScale = dbl("overlayScale", 1.0)
        overlayOpacity = dbl("overlayOpacity2", 0.45)
        overlayLocked = bool("overlayClickThrough", false)
        overlayMode = OverlayMode(rawValue: d.string(forKey: "overlayMode") ?? "") ?? (bool("overlayMinimized", false) ? .minimal : .standard)
        overlayVisible = bool("overlayVisible", true)
        if let arr = d.array(forKey: "overlayFrame") as? [Double], arr.count == 4 {
            overlayFrame = CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
        } else {
            overlayFrame = nil
        }
        showPower = bool("showPower", true)
        showCadence = bool("showCadence", true)
        showHeartRate = bool("showHeartRate", true)
        showSpeed = bool("showSpeed", true)
        showTime = bool("showTime", true)
        showGear = bool("showGear", true)
        showGrade = bool("showGrade", true)
        showResistance = bool("showResistance", false)
        showDistance = bool("showDistance", false)
        showClock = bool("showClock", true)

        clickV2LeftMode = ClickV2LeftMode(rawValue: d.string(forKey: "clickV2LeftMode") ?? "") ?? .unlockWithZwift
        lastZwiftUnlock = d.object(forKey: "lastZwiftUnlock") as? Date
        controllerKeepAlive = bool("controllerKeepAlive", true)
        hapticOnShift = bool("hapticOnShift", true)
        var actions = Settings.defaultButtonActions
        if let raw = d.dictionary(forKey: "buttonActions") as? [String: String] {
            for (k, v) in raw {
                if let b = ControllerButton(rawValue: k), let a = ButtonAction(rawValue: v) { actions[b] = a }
            }
        }
        buttonActions = actions

        preferPedalsForPower = bool("preferPedalsForPower", true)
        autoConnect = bool("autoConnect", true)
        rememberedTrainer = d.string(forKey: "rememberedTrainer")
        rememberedHeartRate = d.string(forKey: "rememberedHeartRate")
        rememberedPowerMeter = d.string(forKey: "rememberedPowerMeter")
        rememberedControllers = d.stringArray(forKey: "rememberedControllers") ?? []
        controllerTypes = (d.dictionary(forKey: "controllerTypes") as? [String: Int]) ?? [:]
        loading = false
    }

    var clampedStartGear: Int { min(max(0, startGearIndex), gearRatios.count - 1) }

    func save() {
        guard !loading else { return }
        d.set(riderWeightKg, forKey: "riderWeightKg")
        d.set(bikeWeightKg, forKey: "bikeWeightKg")
        d.set(gearRatios, forKey: "gearRatios")
        d.set(startGearIndex, forKey: "startGearIndex")
        d.set(gearScaling.rawValue, forKey: "gearScaling")
        d.set(physicalChainring, forKey: "physicalChainring")
        d.set(physicalCog, forKey: "physicalCog")
        d.set(gradePercent, forKey: "gradePercent")
        d.set(ftmsGearGradeStep, forKey: "ftmsGearGradeStep")
        d.set(ergTargetWatts, forKey: "ergTargetWatts")
        d.set(ftpWatts, forKey: "ftpWatts")
        d.set(maxHeartRate, forKey: "maxHeartRate")
        d.set(overlayScale, forKey: "overlayScale")
        d.set(overlayOpacity, forKey: "overlayOpacity2")
        d.set(overlayLocked, forKey: "overlayClickThrough")
        d.set(overlayMode.rawValue, forKey: "overlayMode")
        d.set(overlayVisible, forKey: "overlayVisible")
        if let f = overlayFrame {
            d.set([f.origin.x, f.origin.y, f.width, f.height], forKey: "overlayFrame")
        } else {
            d.removeObject(forKey: "overlayFrame")
        }
        d.set(showPower, forKey: "showPower")
        d.set(showCadence, forKey: "showCadence")
        d.set(showHeartRate, forKey: "showHeartRate")
        d.set(showSpeed, forKey: "showSpeed")
        d.set(showTime, forKey: "showTime")
        d.set(showGear, forKey: "showGear")
        d.set(showGrade, forKey: "showGrade")
        d.set(showResistance, forKey: "showResistance")
        d.set(showDistance, forKey: "showDistance")
        d.set(showClock, forKey: "showClock")
        d.set(clickV2LeftMode.rawValue, forKey: "clickV2LeftMode")
        d.set(lastZwiftUnlock, forKey: "lastZwiftUnlock")
        d.set(controllerKeepAlive, forKey: "controllerKeepAlive")
        d.set(hapticOnShift, forKey: "hapticOnShift")
        d.set(Dictionary(uniqueKeysWithValues: buttonActions.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: "buttonActions")
        d.set(preferPedalsForPower, forKey: "preferPedalsForPower")
        d.set(autoConnect, forKey: "autoConnect")
        d.set(rememberedTrainer, forKey: "rememberedTrainer")
        d.set(rememberedHeartRate, forKey: "rememberedHeartRate")
        d.set(rememberedPowerMeter, forKey: "rememberedPowerMeter")
        d.set(rememberedControllers, forKey: "rememberedControllers")
        d.set(controllerTypes, forKey: "controllerTypes")
    }
}
