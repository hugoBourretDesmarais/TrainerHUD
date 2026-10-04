import AppKit

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let session: Session
    private let overlay: OverlayController
    private let settingsWindow: SettingsWindowController
    private let logWindow: LogWindowController
    private let menu = NSMenu()

    init(session: Session, overlay: OverlayController) {
        self.session = session
        self.overlay = overlay
        settingsWindow = SettingsWindowController(session: session, overlay: overlay)
        logWindow = LogWindowController()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let img = NSImage(systemSymbolName: "bicycle", accessibilityDescription: "TrainerHUD") {
            img.isTemplate = true
            item.button?.image = img
        } else {
            item.button?.title = "HUD"
        }
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = session.state

        let header = NSMenuItem(title: "TrainerHUD  ·  gear \(s.gearIndex + 1)/\(s.gearCount)  ·  \(s.power3s) W  ·  \(s.heartRate) bpm", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(make("Shift Up", #selector(shiftUp), key: String(UnicodeScalar(NSUpArrowFunctionKey)!), mask: [.command]))
        menu.addItem(make("Shift Down", #selector(shiftDown), key: String(UnicodeScalar(NSDownArrowFunctionKey)!), mask: [.command]))
        menu.addItem(make(String(format: "Grade %+.1f%%  →  +0.5", s.gradePercent), #selector(gradeUp), key: "=", mask: [.command]))
        menu.addItem(make("Grade  −0.5", #selector(gradeDown), key: "-", mask: [.command]))
        menu.addItem(make("Grade  0%", #selector(gradeReset), key: "0", mask: [.command]))
        let erg = make(s.mode == .erg ? "ERG mode  (\(s.ergTarget) W)  ✓" : "ERG mode  (\(s.ergTarget) W)", #selector(toggleErg), key: "e", mask: [.command])
        menu.addItem(erg)
        if s.mode == .erg {
            menu.addItem(make("ERG target +5 W", #selector(ergUp), key: "]", mask: [.command]))
            menu.addItem(make("ERG target −5 W", #selector(ergDown), key: "[", mask: [.command]))
        }
        menu.addItem(.separator())

        menu.addItem(make(s.timerRunning ? "Pause Timer" : "Resume Timer", #selector(toggleTimer), key: "p", mask: [.command]))
        menu.addItem(make("Reset Ride", #selector(resetRide), key: "r", mask: [.command, .shift]))
        menu.addItem(.separator())

        let workout = NSMenuItem(title: s.workout.map { "Workout: \($0.name)" } ?? "Workout", action: nil, keyEquivalent: "")
        workout.submenu = buildWorkoutMenu()
        menu.addItem(workout)

        let devices = NSMenuItem(title: "Devices", action: nil, keyEquivalent: "")
        devices.submenu = buildDevicesMenu()
        menu.addItem(devices)
        menu.addItem(.separator())

        menu.addItem(make(session.settings.overlayVisible ? "Hide Overlay" : "Show Overlay", #selector(toggleOverlay), key: "h", mask: [.command]))
        menu.addItem(make("Overlay: \(session.settings.overlayMode.label)  →  \(session.settings.overlayMode.next.label)", #selector(toggleMinimize), key: "m", mask: [.command]))
        let ct = make("Click-through (ignore mouse)", #selector(toggleLock), key: "l", mask: [.command])
        ct.state = session.settings.overlayLocked ? .on : .off
        menu.addItem(ct)
        menu.addItem(make("Reset Overlay Position", #selector(resetPosition), key: "", mask: []))
        menu.addItem(.separator())
        menu.addItem(make("Settings…", #selector(openSettings), key: ",", mask: [.command]))
        menu.addItem(make("Log…", #selector(openLog), key: "", mask: []))
        menu.addItem(.separator())
        menu.addItem(make("Quit TrainerHUD", #selector(quit), key: "q", mask: [.command]))
    }

    private func buildWorkoutMenu() -> NSMenu {
        let m = NSMenu()
        let s = session.state
        if let w = s.workout {
            let pos = s.workoutPosition
            let info = NSMenuItem(title: "\(w.steps.count) steps · \(RideState.clock(w.totalDuration)) · step \((pos?.index ?? 0) + 1)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            m.addItem(info)
            m.addItem(make(s.workoutPaused ? "Resume" : "Pause", #selector(workoutPause), key: "", mask: []))
            m.addItem(make("Next Step", #selector(workoutNext), key: String(UnicodeScalar(NSRightArrowFunctionKey)!), mask: [.command]))
            m.addItem(make("Previous Step", #selector(workoutBack), key: String(UnicodeScalar(NSLeftArrowFunctionKey)!), mask: [.command]))
            m.addItem(make("Stop Workout", #selector(workoutStop), key: "", mask: []))
            m.addItem(.separator())
        }
        m.addItem(make("Load .zwo…", #selector(workoutLoad), key: "o", mask: [.command]))
        m.addItem(make("Reload Today's Workout", #selector(workoutReload), key: "", mask: []))
        m.addItem(make("Open Workouts Folder", #selector(workoutFolder), key: "", mask: []))
        return m
    }

    @objc private func workoutPause() { session.toggleWorkoutPause() }
    @objc private func workoutNext() { session.skipWorkoutStep(forward: true) }
    @objc private func workoutBack() { session.skipWorkoutStep(forward: false) }
    @objc private func workoutStop() { session.stopWorkout() }
    @objc private func workoutReload() { session.loadTodaysWorkout(force: true) }
    @objc private func workoutFolder() { NSWorkspace.shared.open(WorkoutLibrary.folder) }
    @objc private func workoutLoad() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "zwo")!]
        panel.directoryURL = WorkoutLibrary.folder
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { session.loadWorkout(url) }
    }

    private func buildDevicesMenu() -> NSMenu {
        let m = NSMenu()
        let devs = session.ble.discovered.values
            .filter { $0.isCyclingRelevant || session.ble.handler(for: $0.id) != nil }
            .sorted { ($0.lastSeen > $1.lastSeen) }
        if !session.state.bluetoothOn {
            let i = NSMenuItem(title: "Bluetooth is off", action: nil, keyEquivalent: ""); i.isEnabled = false; m.addItem(i)
        }
        if devs.isEmpty {
            let i = NSMenuItem(title: "Scanning… (wake your devices)", action: nil, keyEquivalent: ""); i.isEnabled = false; m.addItem(i)
        }
        for d in devs {
            let handler = session.ble.handler(for: d.id)
            let connected = d.peripheral.state == .connected
            let statusText = handler == nil ? "" : (connected ? "  ● \(handler!.role.label)" : "  ◔ \(handler!.role.label)…")
            let title = "\(d.name)\(d.zwiftType.map { " (\($0.label))" } ?? "")\(statusText)"
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for role in d.roles {
                let it = NSMenuItem(title: "Connect as \(role.label)", action: #selector(connectDevice(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = [d.id.uuidString, role.rawValue]
                if handler?.role == role { it.state = .on }
                sub.addItem(it)
            }
            if handler != nil {
                sub.addItem(.separator())
                let dis = NSMenuItem(title: "Disconnect & forget", action: #selector(disconnectDevice(_:)), keyEquivalent: "")
                dis.target = self
                dis.representedObject = d.id.uuidString
                sub.addItem(dis)
                if handler is ZwiftControllerDevice {
                    let rst = NSMenuItem(title: "Send reset command", action: #selector(resetController(_:)), keyEquivalent: "")
                    rst.target = self
                    rst.representedObject = d.id.uuidString
                    sub.addItem(rst)
                }
            }
            let info = NSMenuItem(title: "RSSI \(d.rssi)  ·  \(d.services.map(\.uuidString).sorted().joined(separator: ", "))", action: nil, keyEquivalent: "")
            info.isEnabled = false
            sub.addItem(.separator())
            sub.addItem(info)
            parent.submenu = sub
            m.addItem(parent)
        }
        m.addItem(.separator())
        let rescan = NSMenuItem(title: "Rescan", action: #selector(rescan), keyEquivalent: "")
        rescan.target = self
        m.addItem(rescan)
        return m
    }

    private func make(_ title: String, _ sel: Selector, key: String, mask: NSEvent.ModifierFlags) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.keyEquivalentModifierMask = mask
        i.target = self
        return i
    }

    @objc private func shiftUp() { session.shift(up: true) }
    @objc private func shiftDown() { session.shift(up: false) }
    @objc private func gradeUp() { session.setGrade(session.state.gradePercent + 0.5) }
    @objc private func gradeDown() { session.setGrade(session.state.gradePercent - 0.5) }
    @objc private func gradeReset() { session.setGrade(0) }
    @objc private func toggleErg() { session.setErg(enabled: session.state.mode != .erg) }
    @objc private func ergUp() { session.setErgTarget(session.state.ergTarget + 5) }
    @objc private func ergDown() { session.setErgTarget(session.state.ergTarget - 5) }
    @objc private func toggleTimer() { session.perform(.toggleTimer) }
    @objc private func resetRide() { session.state.resetRide() }
    @objc private func toggleOverlay() { overlay.toggleVisible() }
    @objc private func toggleLock() { overlay.applyLock(!session.settings.overlayLocked) }
    @objc private func toggleMinimize() { session.settings.overlayMode = session.settings.overlayMode.next }
    @objc private func resetPosition() { overlay.centerTop() }
    @objc private func openSettings() { settingsWindow.show() }
    @objc private func openLog() { logWindow.show() }
    @objc private func rescan() { session.ble.stopScanning(); session.ble.startScanning() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func connectDevice(_ sender: NSMenuItem) {
        guard let arr = sender.representedObject as? [String], arr.count == 2,
              let id = UUID(uuidString: arr[0]), let role = DeviceRole(rawValue: arr[1]) else { return }
        session.ble.connect(id: id, role: role)
    }

    @objc private func disconnectDevice(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let id = UUID(uuidString: s) else { return }
        session.ble.disconnect(id: id, forget: true)
    }

    @objc private func resetController(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let id = UUID(uuidString: s),
              let c = session.ble.handler(for: id) as? ZwiftControllerDevice else { return }
        c.requestReset()
    }
}
