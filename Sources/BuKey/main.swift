import AppKit
import Carbon
import ServiceManagement

enum LayoutRule: String, CaseIterable {
    case ru = "Ru"
    case en = "En"
    case system = "System"
}

struct AppRule {
    let bundleID: String
    var name: String
    var rule: LayoutRule
}

final class RuleStore {
    private let defaults = UserDefaults.standard
    private let rulesKey = "appRules"
    private let namesKey = "appNames"

    init() {
        guard defaults.object(forKey: rulesKey) == nil,
              let previous = defaults.persistentDomain(forName: "local.layoutpilot.app") else { return }
        if let rules = previous[rulesKey] { defaults.set(rules, forKey: rulesKey) }
        if let names = previous[namesKey] { defaults.set(names, forKey: namesKey) }
    }

    func rule(for bundleID: String) -> LayoutRule {
        let raw = (defaults.dictionary(forKey: rulesKey) as? [String: String])?[bundleID]
        return LayoutRule(rawValue: raw ?? "") ?? .system
    }

    func set(_ rule: LayoutRule, for bundleID: String, name: String) {
        var rules = defaults.dictionary(forKey: rulesKey) as? [String: String] ?? [:]
        var names = defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        rules[bundleID] = rule.rawValue
        names[bundleID] = name
        defaults.set(rules, forKey: rulesKey)
        defaults.set(names, forKey: namesKey)
    }

    func all() -> [AppRule] {
        let rules = defaults.dictionary(forKey: rulesKey) as? [String: String] ?? [:]
        let names = defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        return rules.map { id, raw in
            AppRule(bundleID: id, name: names[id] ?? id,
                    rule: LayoutRule(rawValue: raw) ?? .system)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

enum InputSourceSwitcher {
    static func select(_ rule: LayoutRule) {
        guard rule != .system else { return }
        let desiredLanguage = rule == .ru ? "ru" : "en"
        let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
        guard let unmanaged = TISCreateInputSourceList(filter, false) else { return }
        let sources = unmanaged.takeRetainedValue() as NSArray

        for case let source as TISInputSource in sources {
            guard boolProperty(source, kTISPropertyInputSourceIsSelectCapable),
                  let languages = property(source, kTISPropertyInputSourceLanguages) as? [String],
                  languages.contains(where: { $0.lowercased().hasPrefix(desiredLanguage) })
            else { continue }
            TISSelectInputSource(source)
            return
        }
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        (property(source, key) as? NSNumber)?.boolValue ?? false
    }
}

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: RuleStore
    private let onChange: () -> Void
    private let table = NSTableView()
    private var rows: [AppRule] = []

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
        popup.addItems(withTitles: LayoutRule.allCases.map(\.rawValue))
        popup.selectItem(withTitle: item.rule.rawValue)
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
              let title = sender.selectedItem?.title,
              let rule = LayoutRule(rawValue: title) else { return }
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
        rebuildMenu()
    }

    private func activated(_ app: NSRunningApplication) {
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastExternalApp = app
        if let id = app.bundleIdentifier { InputSourceSwitcher.select(store.rule(for: id)) }
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
        for rule in LayoutRule.allCases {
            let item = NSMenuItem(title: rule.rawValue, action: #selector(setRule(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = rule.rawValue
            item.state = rule == selected ? .on : .off
            item.isEnabled = id != nil
            menu.addItem(item)
        }
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
              let raw = sender.representedObject as? String, let rule = LayoutRule(rawValue: raw) else { return }
        store.set(rule, for: id, name: app.localizedName ?? id)
        InputSourceSwitcher.select(rule)
        settings?.reload()
        rebuildMenu()
    }

    @objc private func openSettings() {
        if settings == nil {
            settings = SettingsWindowController(store: store) { [weak self] in self?.rebuildMenu() }
        }
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
