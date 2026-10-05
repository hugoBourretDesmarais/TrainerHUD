import SwiftUI

struct HUDView: View {
    @ObservedObject var state: RideState
    @ObservedObject var settings: Settings
    var controllerLabel: (String) -> String
    var onQuit: () -> Void = {}
    var onToggleErg: () -> Void = {}
    var onDrag: (_ ended: Bool) -> Void = { _ in }
    @State private var hovering = false
    @State private var clock = Date()
    @State private var gearBump = false
    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var k: CGFloat { CGFloat(settings.overlayScale) }

    var body: some View {
        Group {
            if settings.overlayMode == .minimal { minimized } else { expanded }
        }
        .onHover { hovering = $0 }
        .onReceive(clockTimer) { clock = $0 }
        .onChange(of: state.gearIndex) { _, _ in
            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { gearBump = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { gearBump = false }
            }
        }
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                if settings.showPower { powerCell; divider }
                if state.workout != nil { workoutCell; divider }
                if settings.showHeartRate { heartCell; divider }
                if settings.showCadence { cadenceCell; divider }
                if settings.showGear { gearCell; divider }
                if settings.showGrade { gradeCell; divider }
                if settings.showSpeed { smallCell(label: "SPEED", value: String(format: "%.1f", state.speedKmh), unit: "km/h") }
                if settings.showDistance { smallCell(label: "DIST", value: String(format: "%.1f", state.distanceKm), unit: "km") }
                if settings.showTime { smallCell(label: state.timerRunning ? "TIME" : "PAUSED", value: state.elapsedString, unit: "", dim: !state.timerRunning) }
                if settings.showResistance, let r = state.resistance { smallCell(label: "RES", value: "\(r)", unit: "") }
                if settings.showClock { smallCell(label: "CLOCK", value: clockString, unit: "", dim: true) }
                statusColumn.padding(.leading, 10 * k).frame(height: cellHeight, alignment: .top)
            }
            if settings.overlayMode == .full { fullRow.padding(.top, 6 * k) }
            if let toast = state.toast {
                Text(toast)
                    .font(.system(size: 10.5 * k, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 8 * k).padding(.vertical, 2.5 * k)
                    .background(Capsule().fill(Color(hue: 0.13, saturation: 0.9, brightness: 1)))
                    .padding(.top, 5 * k)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16 * k)
        .padding(.vertical, 9 * k)
        .padding(.top, hovering ? 6 * k : 0)
        .background(chrome)
        .gesture(windowDrag)
        .overlay(alignment: .topTrailing) { if hovering { toolbar } }
        .overlay(alignment: .top) {
            if hovering {
                Capsule().fill(.white.opacity(0.28)).frame(width: 28 * k, height: 3 * k).padding(.top, 4 * k)
            }
        }
        .fixedSize()
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var windowDrag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { _ in onDrag(false) }
            .onEnded { _ in onDrag(true) }
    }

    private var chrome: some View {
        RoundedRectangle(cornerRadius: 16 * k, style: .continuous)
            .fill(Color.black.opacity(settings.overlayOpacity))
            .overlay(
                RoundedRectangle(cornerRadius: 16 * k, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.10)).frame(width: 1, height: 40 * k).padding(.horizontal, 12 * k).padding(.top, 8 * k)
    }

    private var cellHeight: CGFloat { 58 * k }

    // MARK: Cells

    private func label(_ s: String, color: Color = .white.opacity(0.5)) -> some View {
        Text(s).font(.system(size: 8.5 * k, weight: .bold, design: .rounded)).tracking(1.4).foregroundStyle(color).lineLimit(1).fixedSize()
    }

    private func big(_ s: String, size: CGFloat, color: Color = .white) -> some View {
        Text(s).font(.system(size: size * k, weight: .heavy, design: .rounded)).monospacedDigit()
            .foregroundStyle(color).lineLimit(1).fixedSize()
    }

    private func unit(_ s: String) -> some View {
        Text(s).font(.system(size: 10 * k, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).fixedSize()
    }

    private var ergToggle: some View {
        let on = state.mode == .erg
        return Button(action: onToggleErg) {
            Text(on ? "ERG" : "SIM")
                .font(.system(size: 8 * k, weight: .black, design: .rounded)).tracking(1)
                .foregroundStyle(on ? Color.black.opacity(0.85) : .white.opacity(0.75))
                .padding(.horizontal, 5 * k).padding(.vertical, 1.5 * k)
                .background(Capsule().fill(on ? Color.orange : Color.white.opacity(0.15)))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .help(on ? "ERG on — click to hold resistance and ride the targets yourself (⌃⇧E)" : "Click to turn ERG on (⌃⇧E)")
    }

    private var target: Int? { state.workoutTargetWatts(ftp: settings.ftpWatts) }

    static func compliance(_ w: Int, target: Int) -> Color {
        guard w > 0, target > 0 else { return .white }
        let r = Double(w) / Double(target)
        if r < 0.95 { return Color(hue: 0.11, saturation: 0.9, brightness: 1) }
        if r > 1.05 { return Color(hue: 0.0, saturation: 0.75, brightness: 1) }
        return Color(hue: 0.38, saturation: 0.75, brightness: 0.95)
    }

    private var workoutCell: some View {
        let w = state.workout!
        let pos = state.workoutPosition
        let step = pos.map { w.steps[$0.index] }
        let remaining = pos.map { w.steps[$0.index].duration - $0.offset } ?? 0
        let next = pos.flatMap { $0.index + 1 < w.steps.count ? w.steps[$0.index + 1] : nil }
        let color = step.map { $0.isFree ? Color.white : Zones.power(Int($0.fraction(at: pos!.offset) * 100), ftp: 100).color } ?? .white
        return VStack(alignment: .leading, spacing: 2 * k) {
            HStack(spacing: 5 * k) {
                label("STEP \((pos?.index ?? w.steps.count - 1) + 1)/\(w.steps.count)")
                if let step { label(step.label.uppercased(), color: color) }
                if state.workoutPaused { label("PAUSED", color: .orange) }
                else if !state.timerRunning { label("PEDAL TO START", color: .white.opacity(0.35)) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3 * k) {
                big(RideState.clock(remaining), size: 30, color: state.workoutPaused ? .white.opacity(0.4) : color)
                if let next {
                    unit("then \(next.isFree ? "free" : "\(Int((next.start * Double(settings.ftpWatts)).rounded()))W") · \(RideState.clock(next.duration))")
                }
            }
            .fixedSize()
            ZoneBar(fraction: step.map { 1 - remaining / max($0.duration, 1) } ?? 1, color: color, k: k)
                .frame(width: 96 * k)
        }
        .frame(height: cellHeight, alignment: .top)
    }

    private var fullRow: some View {
        HStack(alignment: .top, spacing: 0) {
            if let w = state.workout {
                VStack(alignment: .leading, spacing: 3 * k) {
                    HStack(spacing: 6 * k) {
                        label(w.name.uppercased(), color: .white.opacity(0.7))
                        label("\(RideState.clock(max(0, w.totalDuration - state.workoutElapsed))) LEFT")
                    }
                    WorkoutProfile(workout: w, elapsed: state.workoutElapsed, k: k)
                        .frame(width: 380 * k, height: 34 * k)
                }
                divider
            } else {
                VStack(alignment: .leading, spacing: 3 * k) {
                    label("WORKOUT")
                    Text("None for today · ask Claude to sync COROS, or ⌘O to load a .zwo")
                        .font(.system(size: 10 * k, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.45))
                }
                .frame(height: 46 * k, alignment: .top)
                divider
            }
            smallCell(label: "AVG", value: "\(state.avgPower)", unit: "W")
            smallCell(label: "NP", value: state.normalizedPower > 0 ? "\(state.normalizedPower)" : "—", unit: "W")
            smallCell(label: "WORK", value: "\(Int(state.kilojoules))", unit: "kJ")
            if !settings.showDistance { smallCell(label: "DIST", value: String(format: "%.1f", state.distanceKm), unit: "km") }
            smallCell(label: "AVG HR", value: state.avgHeartRate > 0 ? "\(state.avgHeartRate)" : "—", unit: "bpm")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var powerCell: some View {
        let zone = Zones.power(state.power3s, ftp: settings.ftpWatts)
        return VStack(alignment: .leading, spacing: 2 * k) {
            HStack(spacing: 5 * k) {
                label("POWER")
                ergToggle
                if let t = target { label("→ \(t)W", color: state.mode == .erg ? .orange : .white.opacity(0.8)) }
                else if state.mode == .erg { label("\(state.ergTarget)W", color: .orange) }
                else if zone.index > 0 { label("Z\(zone.index)", color: zone.color) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3 * k) {
                big("\(state.power3s)", size: 34, color: target.map { Self.compliance(state.power3s, target: $0) } ?? .white)
                unit("W")
            }
            .fixedSize()
            ZoneBar(fraction: min(Double(state.power3s) / Double(max(settings.ftpWatts, 1)) / 1.5, 1), color: zone.color, k: k)
                .frame(width: 96 * k)
        }
        .frame(height: cellHeight, alignment: .top)
    }

    private var heartCell: some View {
        let zone = Zones.heart(state.heartRate, max: settings.maxHeartRate)
        return VStack(alignment: .leading, spacing: 2 * k) {
            HStack(spacing: 4 * k) {
                Image(systemName: "heart.fill").font(.system(size: 8 * k)).foregroundStyle(zone.color)
                    .scaleEffect(state.heartRate > 0 && clock.timeIntervalSince1970.truncatingRemainder(dividingBy: 2) < 1 ? 1.15 : 1)
                label("HEART")
                if zone.index > 0 { label("Z\(zone.index)", color: zone.color) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3 * k) {
                big(state.heartRate > 0 ? "\(state.heartRate)" : "—", size: 30, color: state.heartRate > 0 ? zone.color : .white.opacity(0.3))
                unit("bpm")
            }
        }
        .frame(height: cellHeight, alignment: .top)
    }

    private var cadenceCell: some View {
        VStack(alignment: .leading, spacing: 2 * k) {
            label("CADENCE")
            HStack(alignment: .firstTextBaseline, spacing: 3 * k) {
                big("\(state.cadence)", size: 30, color: state.cadence == 0 ? .white.opacity(0.35) : .white)
                unit("rpm")
            }
        }
        .frame(height: cellHeight, alignment: .top)
    }

    private var gearCell: some View {
        let accent = Color(hue: 0.52, saturation: 0.85, brightness: 1)
        let recent = state.lastShift.map { Date().timeIntervalSince($0.at) < 0.6 } ?? false
        return VStack(alignment: .leading, spacing: 2 * k) {
            HStack(spacing: 5 * k) {
                label("GEAR")
                label(String(format: "%.2f", state.gearRatio), color: .white.opacity(0.35))
                if !state.trainerHasZwiftProtocol, state.trainerStatus == .ready { label("FTMS", color: .orange.opacity(0.8)) }
            }
            HStack(alignment: .center, spacing: 8 * k) {
                Text(String(state.gearIndex + 1))
                    .font(.system(size: 40 * k, weight: .heavy, design: .rounded))
                    .foregroundStyle(recent ? Color.white : accent)
                    .fixedSize()
                GearLadder(index: state.gearIndex, count: state.gearCount, accent: accent, k: k)
            }
        }
        .frame(height: cellHeight, alignment: .top)
    }

    private var gradeCell: some View {
        let g = state.gradePercent
        let color: Color = g > 0.05 ? Color(hue: 0.08, saturation: 0.85, brightness: 1) : (g < -0.05 ? Color(hue: 0.38, saturation: 0.7, brightness: 0.95) : .white)
        return VStack(alignment: .leading, spacing: 2 * k) {
            label("GRADE")
            HStack(alignment: .firstTextBaseline, spacing: 3 * k) {
                Image(systemName: g > 0.05 ? "arrow.up.right" : (g < -0.05 ? "arrow.down.right" : "arrow.right"))
                    .font(.system(size: 12 * k, weight: .black)).foregroundStyle(color.opacity(0.85))
                big(String(format: "%.1f", abs(g)), size: 24, color: color)
                unit("%")
            }
        }
        .frame(height: cellHeight, alignment: .top)
    }

    private func smallCell(label l: String, value: String, unit u: String, dim: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2 * k) {
            label(l)
            HStack(alignment: .firstTextBaseline, spacing: 3 * k) {
                big(value, size: 22, color: dim ? .white.opacity(0.6) : .white)
                if !u.isEmpty { unit(u) }
            }
        }
        .frame(height: cellHeight, alignment: .top)
        .padding(.trailing, 14 * k)
    }

    private var clockString: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: clock)
    }

    // MARK: Status

    private var statusColumn: some View {
        VStack(alignment: .leading, spacing: 2.5 * k) {
            statusLine(state.trainerHasZwiftProtocol ? "Trainer · VS" : "Trainer", state.trainerStatus)
            statusLine("HR", state.heartRateStatus)
            if state.powerMeterStatus != .disconnected { statusLine("Pedals", state.powerMeterStatus) }
            ForEach(state.controllerStatuses.keys.sorted(), id: \.self) { id in
                let bat = state.controllerBattery[id].map { " \($0)%" } ?? ""
                statusLine(controllerLabel(id) + bat, state.controllerStatuses[id] ?? .disconnected)
            }
            if !state.bluetoothOn { statusLine("Bluetooth off", .stalled) }
        }
    }

    private func statusLine(_ text: String, _ s: ConnectionStatus) -> some View {
        HStack(spacing: 4 * k) {
            Circle().fill(statusColor(s)).frame(width: 5 * k, height: 5 * k)
                .shadow(color: statusColor(s).opacity(s == .ready ? 0.8 : 0), radius: 3 * k)
            Text(text).font(.system(size: 8.5 * k, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.6))
        }
    }

    private func statusColor(_ s: ConnectionStatus) -> Color {
        switch s {
        case .disconnected: return .white.opacity(0.25)
        case .connecting, .connected: return .yellow
        case .ready: return Color(hue: 0.38, saturation: 0.8, brightness: 0.95)
        case .stalled: return .red
        }
    }

    // MARK: Minimized

    private var minimized: some View {
        let hz = Zones.heart(state.heartRate, max: settings.maxHeartRate)
        let pz = Zones.power(state.power3s, ftp: settings.ftpWatts)
        return HStack(spacing: 12 * k) {
            if settings.showGear {
                HStack(spacing: 4 * k) {
                    Text("\(state.gearIndex + 1)").foregroundStyle(Color(hue: 0.52, saturation: 0.85, brightness: 1))
                        .scaleEffect(gearBump ? 1.15 : 1)
                    GearLadder(index: state.gearIndex, count: state.gearCount, accent: Color(hue: 0.52, saturation: 0.85, brightness: 1), k: k * 0.6)
                }
            }
            if settings.showPower {
                HStack(alignment: .firstTextBaseline, spacing: 2 * k) {
                    Text("\(state.power3s)").foregroundStyle(target.map { Self.compliance(state.power3s, target: $0) } ?? (pz.index > 0 ? pz.color : .white))
                    Text(target.map { "/\($0) W" } ?? "W").font(.system(size: 9 * k, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                }
            }
            if let w = state.workout, let pos = state.workoutPosition {
                HStack(alignment: .firstTextBaseline, spacing: 3 * k) {
                    Text(RideState.clock(w.steps[pos.index].duration - pos.offset)).foregroundStyle(.white.opacity(state.workoutPaused ? 0.4 : 0.9))
                    Text("\(pos.index + 1)/\(w.steps.count)").font(.system(size: 9 * k, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                }
            }
            if settings.showHeartRate {
                HStack(spacing: 3 * k) {
                    Image(systemName: "heart.fill").font(.system(size: 9 * k)).foregroundStyle(hz.color)
                    Text(state.heartRate > 0 ? "\(state.heartRate)" : "—").foregroundStyle(state.heartRate > 0 ? hz.color : .white.opacity(0.35))
                }
            }
            if settings.showCadence {
                HStack(alignment: .firstTextBaseline, spacing: 2 * k) {
                    Text("\(state.cadence)").foregroundStyle(.white.opacity(0.85))
                    Text("rpm").font(.system(size: 9 * k, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                }
            }
            if settings.showTime { Text(state.elapsedString).foregroundStyle(.white.opacity(0.7)) }
            Button { settings.overlayMode = .standard } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9 * k, weight: .black))
                    .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.35))
                    .frame(width: 16 * k, height: 16 * k).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 15 * k, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .padding(.horizontal, 14 * k)
        .padding(.vertical, 7 * k)
        .background(
            Capsule().fill(Color.black.opacity(settings.overlayOpacity))
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        )
        .gesture(windowDrag)
        .fixedSize()
    }

    private var toolbar: some View {
        HStack(spacing: 3 * k) {
            toolButton(settings.overlayMode == .full ? "minus" : "plus", help: "Next mode (⌃⇧M)") { settings.overlayMode = settings.overlayMode.next }
            toolButton("xmark", help: "Quit TrainerHUD") { onQuit() }
        }
        .padding(5 * k)
    }

    private func toolButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8 * k, weight: .black))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 15 * k, height: 15 * k)
                .background(Circle().fill(.white.opacity(0.18)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct WorkoutProfile: View {
    let workout: Workout
    let elapsed: TimeInterval
    let k: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let total = max(workout.totalDuration, 1)
            let peak = max(workout.steps.map { max($0.start, $0.end) }.max() ?? 1, 1.2)
            var x0: CGFloat = 0
            for step in workout.steps {
                let w = size.width * step.duration / total
                let h0 = size.height * (step.isFree ? 0.35 : step.start / peak)
                let h1 = size.height * (step.isFree ? 0.35 : step.end / peak)
                var p = Path()
                p.move(to: CGPoint(x: x0, y: size.height))
                p.addLine(to: CGPoint(x: x0, y: size.height - h0))
                p.addLine(to: CGPoint(x: x0 + w, y: size.height - h1))
                p.addLine(to: CGPoint(x: x0 + w, y: size.height))
                p.closeSubpath()
                let color = step.isFree ? Color.white.opacity(0.3) : Zones.power(Int((step.start + step.end) * 50), ftp: 100).color
                ctx.fill(p, with: .color(color.opacity(0.85)))
                x0 += w
            }
            let cx = size.width * min(elapsed / total, 1)
            ctx.fill(Path(CGRect(x: 0, y: 0, width: cx, height: size.height)), with: .color(.black.opacity(0.55)))
            ctx.fill(Path(CGRect(x: cx - k, y: 0, width: 2 * k, height: size.height)), with: .color(.white))
        }
        .clipShape(RoundedRectangle(cornerRadius: 3 * k))
    }
}

private struct ZoneBar: View {
    let fraction: Double
    let color: Color
    let k: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(LinearGradient(colors: [color.opacity(0.6), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4 * k, geo.size.width * fraction))
                    .animation(.easeOut(duration: 0.4), value: fraction)
            }
        }
        .frame(height: 3 * k)
    }
}

private struct GearLadder: View {
    let index: Int
    let count: Int
    let accent: Color
    let k: CGFloat

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.6 * k) {
            ForEach(0..<max(count, 1), id: \.self) { i in
                RoundedRectangle(cornerRadius: 1 * k)
                    .fill(i == index ? Color.white : (i < index ? accent.opacity(0.85) : Color.white.opacity(0.16)))
                    .frame(width: 3 * k, height: (6 + CGFloat(i) * 14 / CGFloat(max(count - 1, 1))) * k)
                    .shadow(color: i == index ? accent.opacity(0.9) : .clear, radius: 3 * k)
            }
        }
        .animation(.easeOut(duration: 0.15), value: index)
    }
}

enum Zones {
    struct Zone { let index: Int; let color: Color }

    static func power(_ w: Int, ftp: Int) -> Zone {
        guard ftp > 0, w > 0 else { return Zone(index: 0, color: .white.opacity(0.35)) }
        let p = Double(w) / Double(ftp) * 100
        switch p {
        case ..<55: return Zone(index: 1, color: Color(white: 0.75))
        case ..<75: return Zone(index: 2, color: Color(hue: 0.58, saturation: 0.75, brightness: 1))
        case ..<90: return Zone(index: 3, color: Color(hue: 0.38, saturation: 0.75, brightness: 0.95))
        case ..<105: return Zone(index: 4, color: Color(hue: 0.14, saturation: 0.9, brightness: 1))
        case ..<120: return Zone(index: 5, color: Color(hue: 0.07, saturation: 0.9, brightness: 1))
        case ..<150: return Zone(index: 6, color: Color(hue: 0.0, saturation: 0.85, brightness: 1))
        default: return Zone(index: 7, color: Color(hue: 0.8, saturation: 0.7, brightness: 1))
        }
    }

    static func heart(_ bpm: Int, max: Int) -> Zone {
        guard max > 0, bpm > 0 else { return Zone(index: 0, color: .white.opacity(0.35)) }
        let p = Double(bpm) / Double(max) * 100
        switch p {
        case ..<60: return Zone(index: 1, color: Color(white: 0.8))
        case ..<70: return Zone(index: 2, color: Color(hue: 0.58, saturation: 0.75, brightness: 1))
        case ..<80: return Zone(index: 3, color: Color(hue: 0.38, saturation: 0.75, brightness: 0.95))
        case ..<90: return Zone(index: 4, color: Color(hue: 0.09, saturation: 0.9, brightness: 1))
        default: return Zone(index: 5, color: Color(hue: 0.0, saturation: 0.85, brightness: 1))
        }
    }
}
