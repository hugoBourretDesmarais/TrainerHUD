import Foundation

struct WorkoutStep: Equatable {
    enum Kind: String { case warmup, steady, on, off, ramp, cooldown, free }

    var kind: Kind
    var duration: TimeInterval
    var start: Double
    var end: Double
    var cadence: Int?

    var isFree: Bool { kind == .free || (start <= 0 && end <= 0) }

    func fraction(at t: TimeInterval) -> Double {
        guard duration > 0 else { return start }
        return start + (end - start) * min(max(t / duration, 0), 1)
    }

    var label: String {
        switch kind {
        case .warmup: return "Warm-up"
        case .steady: return "Steady"
        case .on: return "Interval"
        case .off: return "Recovery"
        case .ramp: return "Ramp"
        case .cooldown: return "Cool-down"
        case .free: return "Free ride"
        }
    }
}

struct Workout: Equatable {
    var name: String
    var steps: [WorkoutStep]
    var source: URL?

    var totalDuration: TimeInterval { steps.reduce(0) { $0 + $1.duration } }

    func stepStart(_ index: Int) -> TimeInterval {
        steps.prefix(max(0, min(index, steps.count))).reduce(0) { $0 + $1.duration }
    }

    /// nil once past the end.
    func position(at t: TimeInterval) -> (index: Int, offset: TimeInterval)? {
        var acc: TimeInterval = 0
        for (i, s) in steps.enumerated() {
            if t < acc + s.duration { return (i, t - acc) }
            acc += s.duration
        }
        return nil
    }
}

enum ZWOParser {
    static func parse(_ data: Data, source: URL? = nil) -> Workout? {
        let d = Delegate()
        let p = XMLParser(data: data)
        p.delegate = d
        guard p.parse(), !d.steps.isEmpty else { return nil }
        let name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Workout(name: name.isEmpty ? (source?.deletingPathExtension().lastPathComponent ?? "Workout") : name, steps: d.steps, source: source)
    }

    static func load(_ url: URL) -> Workout? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data, source: url)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var name = ""
        var steps: [WorkoutStep] = []
        private var inName = false

        func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            func num(_ k: String) -> Double? { a.first { $0.key.lowercased() == k.lowercased() }.flatMap { Double($0.value) } }
            let dur = num("Duration") ?? 0
            let cad = num("Cadence").map { Int($0) }
            switch el.lowercased() {
            case "name": inName = true
            case "warmup": steps.append(.init(kind: .warmup, duration: dur, start: num("PowerLow") ?? 0.5, end: num("PowerHigh") ?? 0.75, cadence: cad))
            case "cooldown": steps.append(.init(kind: .cooldown, duration: dur, start: num("PowerLow") ?? 0.75, end: num("PowerHigh") ?? 0.5, cadence: cad))
            case "ramp": steps.append(.init(kind: .ramp, duration: dur, start: num("PowerLow") ?? 0.5, end: num("PowerHigh") ?? 0.75, cadence: cad))
            case "steadystate":
                let p = num("Power") ?? ((num("PowerLow") ?? 0) + (num("PowerHigh") ?? 0)) / 2
                steps.append(.init(kind: .steady, duration: dur, start: p, end: p, cadence: cad))
            case "intervalst":
                let reps = max(1, Int(num("Repeat") ?? 1))
                let on = num("OnPower") ?? 1, off = num("OffPower") ?? 0.5
                for _ in 0..<reps {
                    steps.append(.init(kind: .on, duration: num("OnDuration") ?? 60, start: on, end: on, cadence: num("Cadence").map { Int($0) }))
                    steps.append(.init(kind: .off, duration: num("OffDuration") ?? 60, start: off, end: off, cadence: num("CadenceResting").map { Int($0) }))
                }
            case "freeride", "maxeffort": steps.append(.init(kind: .free, duration: dur, start: 0, end: 0, cadence: cad))
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if inName { name += string } }

        func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
            if el.lowercased() == "name" { inName = false }
        }
    }
}

/// Watches ~/Library/Application Support/TrainerHUD/workouts for `<yyyy-MM-dd>*.zwo` files.
final class WorkoutLibrary {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TrainerHUD/workouts", isDirectory: true)
    }()

    var onChange: (() -> Void)?
    private var source: DispatchSourceFileSystemObject?

    init() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let fd = open(Self.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.onChange?() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }

    static func todays(now: Date = Date()) -> URL? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let prefix = f.string(from: now)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "zwo" && $0.lastPathComponent.hasPrefix(prefix) }
            .max { modDate($0) < modDate($1) }
    }

    static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
