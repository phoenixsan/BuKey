import AppKit
import Carbon
import ServiceManagement

enum LayoutRule: Equatable {
    case system
    case inputSource(id: String)

    static let systemStorageValue = "__system__"

    var storageValue: String {
        switch self {
        case .system: Self.systemStorageValue
        case .inputSource(let id): id
        }
    }
}

struct AppRule {
    let bundleID: String
    var name: String
    var rule: LayoutRule
}

struct InputSourceOption {
    let id: String
    let name: String
    let languages: [String]
}

enum InputSourceCatalog {
    static func enabled() -> [InputSourceOption] {
        let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
        guard let unmanaged = TISCreateInputSourceList(filter, false) else { return [] }
        let sources = unmanaged.takeRetainedValue() as NSArray

        return sources.compactMap { item in
            let source = item as! TISInputSource
            guard boolProperty(source, kTISPropertyInputSourceIsSelectCapable),
                  let id = property(source, kTISPropertyInputSourceID) as? String,
                  let name = property(source, kTISPropertyLocalizedName) as? String
            else { return nil }
            let languages = property(source, kTISPropertyInputSourceLanguages) as? [String] ?? []
            return InputSourceOption(id: id, name: name, languages: languages)
        }
    }

    @discardableResult
    static func select(id: String) -> Bool {
        let filter = [kTISPropertyInputSourceID: id] as CFDictionary
        guard let unmanaged = TISCreateInputSourceList(filter, false) else { return false }
        let sources = unmanaged.takeRetainedValue() as NSArray
        for case let source as TISInputSource in sources where boolProperty(source, kTISPropertyInputSourceIsSelectCapable) {
            return TISSelectInputSource(source) == noErr
        }
        return false
    }

    static func firstID(matchingLanguage prefix: String) -> String? {
        enabled().first { source in
            source.languages.contains { $0.lowercased().hasPrefix(prefix.lowercased()) }
        }?.id
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        (property(source, key) as? NSNumber)?.boolValue ?? false
    }
}

final class RuleStore {
    private let defaults = UserDefaults.standard
    private let rulesKey = "appRules"
    private let namesKey = "appNames"

    init() {
        if defaults.object(forKey: rulesKey) == nil,
           let previous = defaults.persistentDomain(forName: "local.layoutpilot.app") {
            if let rules = previous[rulesKey] { defaults.set(rules, forKey: rulesKey) }
            if let names = previous[namesKey] { defaults.set(names, forKey: namesKey) }
        }
        migrateLegacyRules()
    }

    func rule(for bundleID: String) -> LayoutRule {
        let raw = (defaults.dictionary(forKey: rulesKey) as? [String: String])?[bundleID]
        guard let raw, raw != LayoutRule.systemStorageValue, raw != "System" else { return .system }
        if raw == "Ru" { return InputSourceCatalog.firstID(matchingLanguage: "ru").map(LayoutRule.inputSource) ?? .system }
        if raw == "En" { return InputSourceCatalog.firstID(matchingLanguage: "en").map(LayoutRule.inputSource) ?? .system }
        return .inputSource(id: raw)
    }

    func set(_ rule: LayoutRule, for bundleID: String, name: String) {
        var rules = defaults.dictionary(forKey: rulesKey) as? [String: String] ?? [:]
        var names = defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        rules[bundleID] = rule.storageValue
        names[bundleID] = name
        defaults.set(rules, forKey: rulesKey)
        defaults.set(names, forKey: namesKey)
    }

    func all() -> [AppRule] {
        let rules = defaults.dictionary(forKey: rulesKey) as? [String: String] ?? [:]
        let names = defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        return rules.map { id, raw in
            AppRule(bundleID: id, name: names[id] ?? id,
                    rule: decodedRule(raw))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func decodedRule(_ raw: String) -> LayoutRule {
        if raw == LayoutRule.systemStorageValue || raw == "System" { return .system }
        if raw == "Ru" { return InputSourceCatalog.firstID(matchingLanguage: "ru").map(LayoutRule.inputSource) ?? .system }
        if raw == "En" { return InputSourceCatalog.firstID(matchingLanguage: "en").map(LayoutRule.inputSource) ?? .system }
        return .inputSource(id: raw)
    }

    private func migrateLegacyRules() {
        var rules = defaults.dictionary(forKey: rulesKey) as? [String: String] ?? [:]
        var changed = false
        for (bundleID, raw) in rules {
            let replacement: String?
            switch raw {
            case "Ru": replacement = InputSourceCatalog.firstID(matchingLanguage: "ru")
            case "En": replacement = InputSourceCatalog.firstID(matchingLanguage: "en")
            case "System": replacement = LayoutRule.systemStorageValue
            default: replacement = nil
            }
            if let replacement {
                rules[bundleID] = replacement
                changed = true
            }
        }
        if changed { defaults.set(rules, forKey: rulesKey) }
    }
}

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: RuleStore
    private let onChange: () -> Void
    private let table = NSTableView()
    private var rows: [AppRule] = []
    private var inputSources: [InputSourceOption] = []

    init(store: RuleStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "BuKey — App Rules"
        window.minSize = NSSize(width: 480, height: 280)
        window.center()
        super.init(window: window)
        buildUI()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.documentView = table

        let appColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        appColumn.title = "Application"
        appColumn.width = 350
        appColumn.minWidth = 220
        appColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        table.addTableColumn(appColumn)
        let ruleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rule"))
        ruleColumn.title = "Rule"
        ruleColumn.width = 150
        ruleColumn.minWidth = 130
        ruleColumn.maxWidth = 180
        ruleColumn.resizingMask = [.userResizingMask]
        table.addTableColumn(ruleColumn)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = NSTableHeaderView()
        table.rowHeight = 30
        table.delegate = self
        table.dataSource = self

        let add = NSButton(title: "Add Application…", target: self, action: #selector(addApplication))
        add.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        content.addSubview(add)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -12),
            add.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            add.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }

    func reload() {
        inputSources = InputSourceCatalog.enabled()
        rows = store.all()
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        if tableColumn?.identifier.rawValue == "app" {
            let label = NSTextField(labelWithString: item.name)
            label.toolTip = item.bundleID
            return label
        }
        let popup = NSPopUpButton()
        for source in inputSources {
            let menuItem = NSMenuItem(title: source.name, action: nil, keyEquivalent: "")
            menuItem.representedObject = source.id
            popup.menu?.addItem(menuItem)
        }
        let systemItem = NSMenuItem(title: "System", action: nil, keyEquivalent: "")
        systemItem.representedObject = LayoutRule.systemStorageValue
        popup.menu?.addItem(systemItem)

        let selectedValue = item.rule.storageValue
        if let selectedItem = popup.itemArray.first(where: { ($0.representedObject as? String) == selectedValue }) {
            popup.select(selectedItem)
        } else if case .inputSource(let missingID) = item.rule {
            let unavailable = NSMenuItem(title: "Unavailable Layout", action: nil, keyEquivalent: "")
            unavailable.representedObject = missingID
            popup.menu?.insertItem(unavailable, at: 0)
            popup.select(unavailable)
        } else {
            popup.select(systemItem)
        }
        popup.tag = row
        popup.target = self
        popup.action = #selector(ruleChanged(_:))
        popup.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()
        cell.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            popup.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            popup.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    @objc private func ruleChanged(_ sender: NSPopUpButton) {
        guard rows.indices.contains(sender.tag),
              let value = sender.selectedItem?.representedObject as? String else { return }
        let rule: LayoutRule = value == LayoutRule.systemStorageValue ? .system : .inputSource(id: value)
        let app = rows[sender.tag]
        store.set(rule, for: app.bundleID, name: app.name)
        rows[sender.tag].rule = rule
        onChange()
    }

    @objc private func addApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        store.set(.system, for: id, name: name)
        reload()
        onChange()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = RuleStore()
    private var statusItem: NSStatusItem!
    private var lastExternalApp: NSRunningApplication?
    private var settings: SettingsWindowController?
    private var observer: NSObjectProtocol?
    private var inputSourcesObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menuBarImage = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "BuKey")
        menuBarImage?.isTemplate = true
        statusItem.button?.image = menuBarImage
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "BuKey"
        if let current = NSWorkspace.shared.frontmostApplication, current.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApp = current
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.activated(app) }
        }
        inputSourcesObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.settings?.reload()
                self?.rebuildMenu()
            }
        }
        rebuildMenu()
    }

    private func activated(_ app: NSRunningApplication) {
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastExternalApp = app
        if let id = app.bundleIdentifier,
           case .inputSource(let sourceID) = store.rule(for: id) {
            InputSourceCatalog.select(id: sourceID)
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let appName = lastExternalApp?.localizedName ?? "No Active Application"
        let heading = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())

        let id = lastExternalApp?.bundleIdentifier
        let selected = id.map(store.rule(for:)) ?? .system
        for source in InputSourceCatalog.enabled() {
            let rule = LayoutRule.inputSource(id: source.id)
            let item = NSMenuItem(title: source.name, action: #selector(setRule(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = rule.storageValue
            item.state = rule == selected ? .on : .off
            item.isEnabled = id != nil
            menu.addItem(item)
        }
        let systemItem = NSMenuItem(title: "System", action: #selector(setRule(_:)), keyEquivalent: "")
        systemItem.target = self
        systemItem.representedObject = LayoutRule.systemStorageValue
        systemItem.state = selected == .system ? .on : .off
        systemItem.isEnabled = id != nil
        menu.addItem(systemItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Configure Applications…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let launchAtLogin = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchAtLogin.target = self
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLogin)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit BuKey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func setRule(_ sender: NSMenuItem) {
        guard let app = lastExternalApp, let id = app.bundleIdentifier,
              let value = sender.representedObject as? String else { return }
        let rule: LayoutRule = value == LayoutRule.systemStorageValue ? .system : .inputSource(id: value)
        store.set(rule, for: id, name: app.localizedName ?? id)
        if case .inputSource(let sourceID) = rule { InputSourceCatalog.select(id: sourceID) }
        settings?.reload()
        rebuildMenu()
    }

    @objc private func openSettings() {
        if settings == nil {
            settings = SettingsWindowController(store: store) { [weak self] in self?.rebuildMenu() }
        }
        settings?.reload()
        settings?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Unable to Change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
        rebuildMenu()
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
