import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var session: Session!
    private var overlay: OverlayController!
    private var menu: StatusMenuController!

    override init() {
        super.init()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let str = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: str) else { return }
        handle(url)
    }

    // trainerhud://shift-up | shift-down | gear/12 | grade/+0.5 | grade/3 | erg/on | erg/off | erg/220
    //            | workout/load/<abs path> | workout/today | workout/pause | workout/next | workout/back | workout/stop
    //            | timer/toggle | ride/reset | overlay/toggle | overlay/minimal | overlay/standard | overlay/full | overlay/cycle | overlay/lock | overlay/unlock
    private func handle(_ url: URL) {
        guard let session, url.scheme == "trainerhud" else { return }
        let host = url.host ?? ""
        let arg = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        Log.info("URL command \(host)/\(arg)")
        switch host {
        case "shift-up": session.shift(up: true)
        case "shift-down": session.shift(up: false)
        case "gear": if let g = Int(arg) { session.setGear(index: g - 1) }
        case "grade":
            if arg.hasPrefix("+") || arg.hasPrefix("-"), let d = Double(arg) { session.setGrade(session.state.gradePercent + d) }
            else if let g = Double(arg) { session.setGrade(g) }
        case "erg":
            if arg == "on" { session.setErg(enabled: true) }
            else if arg == "off" { session.setErg(enabled: false) }
            else if let w = Int(arg) { session.setErgTarget(w); session.setErg(enabled: true) }
        case "workout":
            switch arg {
            case "today": session.loadTodaysWorkout(force: true)
            case "pause": session.toggleWorkoutPause()
            case "next": session.skipWorkoutStep(forward: true)
            case "back": session.skipWorkoutStep(forward: false)
            case "stop": session.stopWorkout()
            default:
                if arg.hasPrefix("load/") { session.loadWorkout(URL(fileURLWithPath: "/" + arg.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: "/")))) }
            }
        case "timer": session.perform(.toggleTimer)
        case "ride": session.state.resetRide()
        case "overlay":
            switch arg {
            case "lock": overlay.applyLock(true)
            case "unlock": overlay.applyLock(false)
            case "minimize", "minimal": session.settings.overlayMode = .minimal
            case "expand", "standard": session.settings.overlayMode = .standard
            case "full": session.settings.overlayMode = .full
            case "cycle": session.settings.overlayMode = session.settings.overlayMode.next
            case "show": overlay.setVisible(true)
            case "hide": overlay.setVisible(false)
            default: overlay.toggleVisible()
            }
        default: break
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("TrainerHUD starting (\(ProcessInfo.processInfo.operatingSystemVersionString))")
        session = Session()
        overlay = OverlayController(session: session)
        session.overlay = overlay
        menu = StatusMenuController(session: session, overlay: overlay)
        NSApp.servicesProvider = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.shutdown()
        Log.info("TrainerHUD quitting")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
