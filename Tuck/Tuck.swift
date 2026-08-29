//
//  Tuck.swift  —  MVP
//
//  Every app you have assigned to "All Desktops" in the Dock gets an icon in the
//  right side of the menu bar. Click the icon to tuck the app away (hide) or to
//  bring it back. Because the app is assigned to All Desktops, bringing it back
//  shows it on whatever desktop you are currently on — no Space switching, no
//  private APIs, no SIP changes.
//
//  Core path uses only supported API:
//      NSRunningApplication.hide() / .unhide() / .activate()
//      CFPreferences read of com.apple.spaces -> app-bindings
//      NSStatusItem
//  and therefore needs NO permission prompts at all.
//
//  Optional extra: if the app has zero windows open, Tuck can ask it for a new
//  one (File > New Window, else Cmd-N). That single step needs Accessibility.
//  If not granted, Tuck silently skips it and just activates the app.
//
//  Build: ./build.sh
//

import Cocoa
import ApplicationServices
import Carbon

// MARK: - Reading the Dock's "Assign To" setting

enum SpacesPrefs {

    /// Bundle identifiers currently assigned to "All Desktops".
    ///
    /// Stored in ~/Library/Preferences/com.apple.spaces.plist under `app-bindings`:
    ///   "com.apple.Safari" = "AllSpaces"                    -> All Desktops
    ///   "com.apple.Safari" = "<space-uuid>"                 -> one specific desktop
    ///   (absent)                                            -> None
    static func allDesktopsBundleIDs() -> Set<String> {
        if let dict = viaCFPreferences() ?? viaPlistFile() {
            var out = Set<String>()
            for (key, value) in dict {
                if let s = value as? String, s == "AllSpaces" {
                    out.insert(key)
                }
            }
            return out
        }
        return []
    }

    private static func viaCFPreferences() -> [String: Any]? {
        let appID = "com.apple.spaces" as CFString
        _ = CFPreferencesAppSynchronize(appID)
        let raw = CFPreferencesCopyAppValue("app-bindings" as CFString, appID)
        return raw as? [String: Any]
    }

    private static func viaPlistFile() -> [String: Any]? {
        let path = NSHomeDirectory() + "/Library/Preferences/com.apple.spaces.plist"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let parsed = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
              let plist = parsed as? [String: Any] else { return nil }
        return plist["app-bindings"] as? [String: Any]
    }
}

// MARK: - Window helpers

enum Windows {

    /// Does this process own at least one normal, on-screen window right now?
    /// Reads only owner PID / layer / bounds, so no Screen Recording permission needed.
    static func hasVisibleWindow(pid: pid_t) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for info in infos {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            if rect.width >= 60 && rect.height >= 60 { return true }
        }
        return false
    }

    /// Best-effort "open a window please". Requires Accessibility; no-op without it.
    static func requestNewWindow(pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        if pressNewWindowMenuItem(pid: pid) { return }
        postCommandN(pid: pid)
    }

    private static func pressNewWindowMenuItem(pid: pid_t) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let raw = menuBarRef,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let menuBar = raw as! AXUIElement

        for menu in children(of: menuBar) {
            guard title(of: menu) == "File" else { continue }
            for submenu in children(of: menu) {
                for item in children(of: submenu) {
                    guard let t = title(of: item) else { continue }
                    guard t == "New Window" || t == "New Main Window" else { continue }
                    if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func postCommandN(pid: pid_t) {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let keyN: CGKeyCode = 45   // kVK_ANSI_N
        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyN, keyDown: true) {
            down.flags = .maskCommand
            down.postToPid(pid)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: keyN, keyDown: false) {
            up.flags = .maskCommand
            up.postToPid(pid)
        }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let kids = ref as? [AXUIElement] else { return [] }
        return kids
    }

    private static func title(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    static func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [])
        }
    }
}

// MARK: - Preferences

enum Settings {
    private static let key = "autoHideBundleIDs"

    static var autoHideBundleIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: key) }
    }

    static func isAutoHideEnabled(for bundleID: String) -> Bool {
        autoHideBundleIDs.contains(bundleID)
    }

    static func toggleAutoHide(for bundleID: String) {
        var ids = autoHideBundleIDs
        if ids.contains(bundleID) { ids.remove(bundleID) }
        else { ids.insert(bundleID) }
        autoHideBundleIDs = ids
    }
}

// MARK: - One menu bar icon

final class TrayEntry: NSObject {
    let bundleID: String          // empty string == the placeholder entry
    let statusItem: NSStatusItem
    private weak var controller: Controller?

    init(bundleID: String, controller: Controller) {
        self.bundleID = bundleID
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked(_:))
            _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refreshAppearance()
    }

    var app: NSRunningApplication? {
        guard !bundleID.isEmpty else { return nil }
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first { !$0.isTerminated }
    }

    func refreshAppearance() {
        guard let button = statusItem.button else { return }

        guard let app = app else {
            button.image = NSImage(systemSymbolName: "rectangle.on.rectangle",
                                   accessibilityDescription: "Tuck")
            button.image?.isTemplate = true
            button.alphaValue = 1.0
            button.toolTip = "Tuck — no apps assigned to All Desktops"
            return
        }

        button.image = TrayEntry.menuBarIcon(for: app)
        // Tucked away reads as dimmed; on screen reads as solid.
        button.alphaValue = app.isHidden ? 0.45 : 1.0
        button.toolTip = app.isHidden
            ? "\(app.localizedName ?? bundleID) — click to show"
            : "\(app.localizedName ?? bundleID) — click to tuck away"
    }

    private static func menuBarIcon(for app: NSRunningApplication) -> NSImage? {
        guard let icon = app.icon else { return nil }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func clicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)

        if isRightClick || bundleID.isEmpty {
            showMenu()
        } else {
            controller?.toggle(bundleID: bundleID)
        }
    }

    private func showMenu() {
        guard let button = statusItem.button, let controller = controller else { return }
        let menu = controller.buildMenu(for: self)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 5),
                   in: button)
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

// MARK: - Global hotkey (⌘⇧H toggles hide / show all)

final class GlobalHotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x5443554B      // "TUCK"

    var onPress: (() -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if handlerRef == nil {
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: UInt32(kEventHotKeyPressed))
            let callback: EventHandlerUPP = { _, _, userData in
                guard let userData else { return noErr }
                Unmanaged<GlobalHotKey>.fromOpaque(userData)
                    .takeUnretainedValue().onPress?()
                return noErr
            }
            let status = InstallEventHandler(GetApplicationEventTarget(), callback,
                                             1, &eventType, selfPtr, &handlerRef)
            if status != noErr { handlerRef = nil }
        }
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        return true
    }
}

// MARK: - Controller

final class Controller: NSObject {

    private var entries: [String: TrayEntry] = [:]     // bundleID -> entry
    private var placeholder: TrayEntry?
    private var refreshTimer: Timer?
    private var lastClickAt: TimeInterval = 0
    private var hotKey: GlobalHotKey?

    func start() {
        sync()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.sync()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDeactivated(_:)),
            name: NSWorkspace.didDeactivateApplicationNotification, object: nil)

        // ⌘⇧H — toggle "Tuck All Away " / "Show All".
        let modifiers = UInt32(cmdKey | shiftKey)
        hotKey = GlobalHotKey()
        hotKey?.onPress = { [weak self] in self?.toggleAll() }
        if hotKey?.register(keyCode: 4, modifiers: modifiers) == false {
            hotKey = nil
        }
    }

    func toggleAll() {
        var anyVisible = false
        for bundleID in entries.keys {
            let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .filter { !$0.isTerminated && !$0.isHidden }
            if !running.isEmpty { anyVisible = true }
        }
        if anyVisible {
            hideAll()
        } else {
            for bundleID in Array(entries.keys) {
                let running = NSRunningApplication
                    .runningApplications(withBundleIdentifier: bundleID)
                    .filter { !$0.isTerminated }
                for app in running {
                    _ = app.unhide()
                    Windows.activate(app)
                }
            }
            sync()
        }
    }

    // MARK: Keeping the icons in sync with the Dock setting

    func sync() {
        let assigned = SpacesPrefs.allDesktopsBundleIDs()
        let assignedLower = Set(assigned.map { $0.lowercased() })
        // Only show icons for apps that are actually running. Match bundle IDs
        // case-insensitively: Spaces may store "com.apple.mobilesms" but the
        // running app reports "com.apple.MobileSMS".
        var wanted = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, !app.isTerminated,
                  let bundleID = app.bundleIdentifier,
                  assignedLower.contains(bundleID.lowercased()) else { continue }
            wanted.insert(bundleID)   // use the running app's canonical ID as key
        }

        // Snapshot the keys: we mutate `entries` inside this loop.
        for bundleID in Array(entries.keys) where !wanted.contains(bundleID) {
            entries[bundleID]?.remove()
            entries.removeValue(forKey: bundleID)
        }
        for bundleID in wanted where entries[bundleID] == nil {
            entries[bundleID] = TrayEntry(bundleID: bundleID, controller: self)
        }
        for entry in entries.values {
            entry.refreshAppearance()
        }

        // Keep exactly one icon on screen when nothing is assigned, so Tuck is reachable.
        if entries.isEmpty {
            if placeholder == nil {
                placeholder = TrayEntry(bundleID: "", controller: self)
            }
            placeholder?.refreshAppearance()
        } else {
            placeholder?.remove()
            placeholder = nil
        }
    }

    // MARK: Show / hide

    func toggle(bundleID: String) {
        lastClickAt = Date().timeIntervalSince1970
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated }) else { return }

        if app.isHidden {
            show(app)
        } else if app.isActive {
            _ = app.hide()
        } else {
            // Visible but behind something: bring it forward rather than hiding it.
            show(app)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.sync()
        }
    }

    private func show(_ app: NSRunningApplication) {
        _ = app.unhide()
        Windows.activate(app)

        let pid = app.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            guard !Windows.hasVisibleWindow(pid: pid) else { return }
            Windows.requestNewWindow(pid: pid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                if let a = NSRunningApplication(processIdentifier: pid) {
                    Windows.activate(a)
                }
            }
        }
    }

    func hideAll() {
        for bundleID in Array(entries.keys) {
            NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .forEach { _ = $0.hide() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.sync()
        }
    }

    @objc private func appDeactivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              entries[bundleID] != nil,
              Settings.isAutoHideEnabled(for: bundleID) else { return }

        // Clicking our own menu bar icon deactivates the front app; don't treat
        // that as "user moved on".
        if Date().timeIntervalSince1970 - lastClickAt < 1.0 { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince1970 - self.lastClickAt < 1.0 { return }
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier == getpid() { return }
            if front?.bundleIdentifier == bundleID { return }
            _ = app.hide()
            self.sync()
        }
    }

    // MARK: Menu

    func buildMenu(for entry: TrayEntry) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false   // so our explicit isEnabled states stick

        if let app = entry.app {
            let name = app.localizedName ?? entry.bundleID
            let header = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let toggleItem = NSMenuItem(title: app.isHidden ? "Show" : "Tuck Away",
                                        action: #selector(menuToggle(_:)), keyEquivalent: "")
            toggleItem.target = self
            toggleItem.representedObject = entry.bundleID
            menu.addItem(toggleItem)
            menu.addItem(.separator())
        } else {
            let header = NSMenuItem(title: "No apps assigned to All Desktops",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let hint = NSMenuItem(title: "Right-click a Dock icon → Options → Assign To → All Desktops",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            menu.addItem(.separator())
        }

        let hideAllItem = NSMenuItem(title: "Tuck All Away  ⌘⇧H",
                                     action: #selector(menuHideAll(_:)), keyEquivalent: "")
        hideAllItem.target = self
        hideAllItem.isEnabled = !entries.isEmpty
        menu.addItem(hideAllItem)

        if !entry.bundleID.isEmpty {
            let autoItem = NSMenuItem(title: "Auto-tuck when app loses focus",
                                      action: #selector(menuToggleAutoHide(_:)), keyEquivalent: "")
            autoItem.target = self
            autoItem.representedObject = entry.bundleID
            autoItem.state = Settings.isAutoHideEnabled(for: entry.bundleID) ? .on : .off
            menu.addItem(autoItem)
        }

        let refreshItem = NSMenuItem(title: "Refresh",
                                     action: #selector(menuRefresh(_:)), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Tuck",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    @objc private func menuToggle(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        toggle(bundleID: bundleID)
    }

    @objc private func menuHideAll(_ sender: NSMenuItem) { hideAll() }

    @objc private func menuRefresh(_ sender: NSMenuItem) { sync() }

    @objc private func menuToggleAutoHide(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        Settings.toggleAutoHide(for: bundleID)
    }
}

// MARK: - main

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = Controller()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller.start()
    }
}
