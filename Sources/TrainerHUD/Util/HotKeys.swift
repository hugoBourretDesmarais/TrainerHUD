import AppKit
import Carbon.HIToolbox

/// System-wide ⌃⇧ hotkeys (menu key equivalents only fire when this menu-bar app is frontmost, which it never is).
final class HotKeys {
    static let modifiers: NSEvent.ModifierFlags = [.control, .shift]

    struct Binding {
        let keyCode: Int
        let key: String
        let action: ButtonAction
    }

    static let bindings: [Binding] = [
        .init(keyCode: kVK_UpArrow, key: String(UnicodeScalar(NSUpArrowFunctionKey)!), action: .shiftUp),
        .init(keyCode: kVK_DownArrow, key: String(UnicodeScalar(NSDownArrowFunctionKey)!), action: .shiftDown),
        .init(keyCode: kVK_RightArrow, key: String(UnicodeScalar(NSRightArrowFunctionKey)!), action: .workoutSkip),
        .init(keyCode: kVK_LeftArrow, key: String(UnicodeScalar(NSLeftArrowFunctionKey)!), action: .workoutBack),
        .init(keyCode: kVK_Space, key: " ", action: .workoutPause),
        .init(keyCode: kVK_ANSI_M, key: "m", action: .minimizeOverlay),
        .init(keyCode: kVK_ANSI_E, key: "e", action: .toggleErg),
        .init(keyCode: kVK_ANSI_H, key: "h", action: .toggleOverlay),
        .init(keyCode: kVK_ANSI_Equal, key: "=", action: .gradeUp),
        .init(keyCode: kVK_ANSI_Minus, key: "-", action: .gradeDown),
    ]

    static func key(for action: ButtonAction) -> String? { bindings.first { $0.action == action }?.key }

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private let perform: (ButtonAction) -> Void

    init(perform: @escaping (ButtonAction) -> Void) {
        self.perform = perform
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hk = Unmanaged<HotKeys>.fromOpaque(userData!).takeUnretainedValue()
            if Int(id.id) < HotKeys.bindings.count { hk.perform(HotKeys.bindings[Int(id.id)].action) }
            return noErr
        }, 1, &spec, me, &handler)
        let mods = UInt32(controlKey | shiftKey)
        for (i, b) in Self.bindings.enumerated() {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(b.keyCode), mods, EventHotKeyID(signature: OSType(0x54485544), id: UInt32(i)), GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { Log.warn("Hotkey ⌃⇧\(b.key) unavailable (\(status))") }
        }
    }

    deinit {
        refs.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}
