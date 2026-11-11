import Carbon.HIToolbox
import Foundation

/// System-wide hotkeys (work even when another app is in front, no Accessibility permission needed).
///   ⌃⌥R  start / stop recording
///   ⌃⌥P  pause / resume
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    static let toggleRecordID: UInt32 = 1
    static let togglePauseID: UInt32 = 2

    /// Called on the main queue with the id of the hotkey that fired.
    var handler: ((UInt32) -> Void)?

    private var installed = false
    private var refs: [EventHotKeyRef?] = []

    func register() {
        guard !installed else { return }
        installed = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let id = hotKeyID.id
                DispatchQueue.main.async {
                    HotKeyCenter.shared.handler?(id)
                }
                return noErr
            },
            1,
            &spec,
            nil,
            nil
        )

        let modifiers = UInt32(controlKey | optionKey)
        add(keyCode: UInt32(kVK_ANSI_R), modifiers: modifiers, id: HotKeyCenter.toggleRecordID)
        add(keyCode: UInt32(kVK_ANSI_P), modifiers: modifiers, id: HotKeyCenter.togglePauseID)
    }

    /// Releases the hotkeys (used before relaunching so the new instance can take them).
    func unregisterAll() {
        for ref in refs {
            if let ref = ref { UnregisterEventHotKey(ref) }
        }
        refs.removeAll()
    }

    private func add(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4252_4543), id: id) // 'BREC'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}
