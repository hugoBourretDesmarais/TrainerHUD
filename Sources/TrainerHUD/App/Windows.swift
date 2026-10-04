import AppKit
import SwiftUI

final class SettingsWindowController {
    private var window: NSWindow?
    private let session: Session
    private let overlay: OverlayController

    init(session: Session, overlay: OverlayController) {
        self.session = session
        self.overlay = overlay
    }

    func show() {
        if window == nil {
            let view = SettingsView(settings: session.settings, session: session, overlay: overlay)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "TrainerHUD Settings"
            w.contentView = NSHostingView(rootView: view)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class LogWindowController {
    private var window: NSWindow?
    private var textView: NSTextView?

    func show() {
        if window == nil {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
            let tv = NSTextView(frame: scroll.bounds)
            tv.isEditable = false
            tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            tv.autoresizingMask = [.width]
            tv.textContainer?.widthTracksTextView = true
            tv.isVerticallyResizable = true
            scroll.documentView = tv
            scroll.hasVerticalScroller = true
            let w = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "TrainerHUD Log"
            w.contentView = scroll
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            textView = tv
            tv.string = Log.shared.lines.joined(separator: "\n") + "\n"
            Log.shared.onAppend = { [weak self] line in
                guard let tv = self?.textView else { return }
                tv.textStorage?.append(NSAttributedString(string: line + "\n", attributes: [.font: tv.font!, .foregroundColor: NSColor.textColor]))
                if tv.textStorage!.length > 400_000 {
                    tv.textStorage?.deleteCharacters(in: NSRange(location: 0, length: 100_000))
                }
                tv.scrollToEndOfDocument(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        textView?.scrollToEndOfDocument(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    let session: Session
    let overlay: OverlayController
    @State private var gearText = ""
    @State private var gearError: String?

    var body: some View {
        TabView {
            ridingTab.tabItem { Text("Riding") }
            overlayTab.tabItem { Text("Overlay") }
            controllersTab.tabItem { Text("Controllers") }
            devicesTab.tabItem { Text("Devices") }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 560)
        .onAppear { gearText = settings.gearRatios.map { String(format: "%.2f", $0) }.joined(separator: ", ") }
    }

    private var ridingTab: some View {
        Form {
            Section("Rider") {
                HStack {
                    Text("FTP (power zones)")
                    Spacer()
                    TextField("W", value: $settings.ftpWatts, format: .number).frame(width: 80)
                    Text("W")
                }
                HStack {
                    Text("Max heart rate (HR zones)")
                    Spacer()
                    TextField("bpm", value: $settings.maxHeartRate, format: .number).frame(width: 80)
                    Text("bpm")
                }
                HStack {
                    Text("Rider weight")
                    Spacer()
                    TextField("kg", value: $settings.riderWeightKg, format: .number).frame(width: 80)
                    Text("kg")
                }
                HStack {
                    Text("Bike weight")
                    Spacer()
                    TextField("kg", value: $settings.bikeWeightKg, format: .number).frame(width: 80)
                    Text("kg")
                }
            }
            Section("Virtual gears") {
                VStack(alignment: .leading) {
                    Text("Gear ratios (comma separated, low → high)")
                    TextEditor(text: $gearText).frame(height: 60).font(.system(.body, design: .monospaced))
                    HStack {
                        Button("Apply") { applyGears() }
                        Button("Zwift default (24)") {
                            gearText = Settings.zwiftGears.map { String(format: "%.2f", $0) }.joined(separator: ", ")
                            applyGears()
                        }
                        if let e = gearError { Text(e).foregroundStyle(.red) }
                    }
                }
                Stepper("Start gear: \(settings.clampedStartGear + 1)", value: $settings.startGearIndex, in: 0...(settings.gearRatios.count - 1))
                Picker("Ratio sent to trainer", selection: $settings.gearScaling) {
                    ForEach(GearScaling.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: settings.gearScaling) { _, _ in session.gearSettingsChanged() }
                if settings.gearScaling == .relativeToPhysical {
                    HStack {
                        Text("Physical chainring / cog")
                        Spacer()
                        TextField("T", value: $settings.physicalChainring, format: .number).frame(width: 50)
                        Text("/")
                        TextField("T", value: $settings.physicalCog, format: .number).frame(width: 50)
                    }
                }
                Text("With the Zwift protocol the trainer firmware simulates the gear. Zwift itself sends the ratio as-is; use the QZ-style option only if the feel is wrong.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Fallback (trainers without Zwift protocol)") {
                HStack {
                    Text("Grade change per gear step")
                    Spacer()
                    TextField("%", value: $settings.ftmsGearGradeStep, format: .number).frame(width: 60)
                    Text("%")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var overlayTab: some View {
        Form {
            Section("Appearance") {
                Slider(value: $settings.overlayScale, in: 0.6...2.0, step: 0.1) { Text("Size \(String(format: "%.1f", settings.overlayScale))×") }
                Slider(value: $settings.overlayOpacity, in: 0.0...1.0, step: 0.05) { Text("Background darkness") }
                Toggle("Click-through (ignore mouse; hover controls disabled)", isOn: Binding(get: { settings.overlayLocked }, set: { overlay.applyLock($0) }))
                Picker("Mode", selection: $settings.overlayMode) { ForEach(OverlayMode.allCases, id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                Text("Drag the overlay anywhere by its background. Hover it for the mode button, or press ⌃⇧M anywhere to cycle Minimal / Standard / Full.").font(.caption).foregroundStyle(.secondary)
                Button("Reset position") { overlay.centerTop() }
            }
            Section("Fields") {
                Toggle("Power (3 s)", isOn: $settings.showPower)
                Toggle("Cadence", isOn: $settings.showCadence)
                Toggle("Heart rate", isOn: $settings.showHeartRate)
                Toggle("Speed", isOn: $settings.showSpeed)
                Toggle("Elapsed time", isOn: $settings.showTime)
                Toggle("Distance", isOn: $settings.showDistance)
                Toggle("Gear", isOn: $settings.showGear)
                Toggle("Grade / ERG target", isOn: $settings.showGrade)
                Toggle("Resistance level (FTMS)", isOn: $settings.showResistance)
                Toggle("Clock", isOn: $settings.showClock)
            }
        }
        .formStyle(.grouped)
    }

    private var controllersTab: some View {
        Form {
            Section("Zwift Click v2 (left puck)") {
                Picker("Left puck mode", selection: $settings.clickV2LeftMode) {
                    ForEach(ClickV2LeftMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                HStack {
                    if let d = settings.lastZwiftUnlock {
                        Text("Last Zwift unlock: \(d.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("Last Zwift unlock: never recorded")
                    }
                    Spacer()
                    Button("I just used it in Zwift") { session.markZwiftUnlockNow() }
                }
                Text("Zwift locks the Click v2 left puck to its own app: it stops sending button presses about a minute after connecting unless Zwift 'blessed' it in the last ~24 h. The right puck (+) has no such lock. Either pair the Clicks in Zwift for 30 s once a day, or use the restart loop, or shift with the right puck only (+ up, B down).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behaviour") {
                Toggle("Keep-alive polling (every 20 s)", isOn: $settings.controllerKeepAlive)
                Toggle("Vibrate Play/Ride on shift", isOn: $settings.hapticOnShift)
            }
            Section("Button mapping") {
                ForEach(ControllerButton.allCases, id: \.self) { b in
                    Picker(b.label, selection: Binding(
                        get: { settings.buttonActions[b] ?? ButtonAction.none },
                        set: { settings.buttonActions[b] = $0 }
                    )) {
                        ForEach(ButtonAction.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Button("Restore defaults") { settings.buttonActions = Settings.defaultButtonActions }
            }
        }
        .formStyle(.grouped)
    }

    private var devicesTab: some View {
        Form {
            Section("Connection") {
                Toggle("Auto-connect remembered devices", isOn: $settings.autoConnect)
                Toggle("Prefer pedals/power meter over trainer for power & cadence", isOn: $settings.preferPedalsForPower)
                Button("Forget all remembered devices") {
                    settings.rememberedTrainer = nil
                    settings.rememberedHeartRate = nil
                    settings.rememberedPowerMeter = nil
                    settings.rememberedControllers = []
                }
            }
            Section("How to connect") {
                Text("Use the menu bar icon → Devices. Wake the trainer (pedal), press a button on each Click, and put on the HR strap. Pick a role for each device; it is remembered and reconnected automatically next time. Quit Zwift first: most trainers accept only one app at a time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func applyGears() {
        let parts = gearText.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
        let values = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count >= 2, values.allSatisfy({ $0 > 0.2 && $0 < 15 }) else {
            gearError = "Need at least 2 ratios between 0.2 and 15"
            return
        }
        gearError = nil
        settings.gearRatios = values
        settings.startGearIndex = min(settings.startGearIndex, values.count - 1)
        session.gearSettingsChanged()
    }
}
