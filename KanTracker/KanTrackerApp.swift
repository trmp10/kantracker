import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import ApplicationServices


extension Notification.Name {
    static let focusQuickAdd = Notification.Name("kanTrackerFocusQuickAdd")
    static let toggleNewTask = Notification.Name("kanTrackerToggleNewTask")
    static let exportCSV     = Notification.Name("kanTrackerExportCSV")
}

struct JSONTask: Codable {
    let id: String
    let title: String
    let status: String
    let importance: String
    let sortOrder: Int
}

// MARK: - Panel Manager

class PanelManager: NSObject {
    static let shared = PanelManager()
    var mainPanel: NSPanel?
}

// MARK: - App

@main
struct KanTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    var globalClickMonitor: Any?
    var globalKeyMonitor: Any?
    var localKeyMonitor: Any?
    let store = KanbanStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "KanTracker")
            button.toolTip = "KanTracker (⌃⇧K)"
            button.action = #selector(handleStatusItemClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }

        setupPanel()
        requestAccessibilityIfNeeded()
    }

    private func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func setupPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1350, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "KanTracker"
        panel.minSize = NSSize(width: 800, height: 500)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .windowBackgroundColor
        panel.isOpaque = true
        panel.contentView = NSHostingView(rootView: ContentView(store: store))

        PanelManager.shared.mainPanel = panel

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] _ in
            guard let panel = panel, panel.isVisible else { return }
            self?.savePanelFrame()
            panel.orderOut(nil)
        }

        // Ctrl+Shift+K — fires when app is in background
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 40,
                  event.modifierFlags.intersection([.control, .shift]) == [.control, .shift]
            else { return }
            DispatchQueue.main.async { self?.togglePanel() }
        }

        // Ctrl+Shift+K / Cmd+N — fires when app is focused
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection([.control, .shift, .command, .option])
            if event.keyCode == 40, flags == [.control, .shift] {
                self?.togglePanel()
                return nil
            }
            if event.keyCode == 45, flags == [.command] {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .toggleNewTask, object: nil)
                }
                return nil
            }
            return event
        }
    }

    @objc func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    func showContextMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Export...", action: #selector(requestExport), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Import...", action: #selector(importFile), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Reset all data...", action: #selector(resetAllData), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit KanTracker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }

    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("Launch at login error: \(error)")
        }
    }

    @objc func resetAllData() {
        let alert = NSAlert()
        alert.messageText = "Reset all data?"
        alert.informativeText = "This will permanently delete all tasks and projects."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.tasks = []
        store.projects = []
    }

    @objc func requestExport() {
        NotificationCenter.default.post(name: .exportCSV, object: nil)
    }

    @objc func importFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText, UTType.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let items = try? JSONDecoder().decode([JSONTask].self, from: data)
            else { return }
            items.sorted { $0.sortOrder < $1.sortOrder }.compactMap { item -> Task? in
                guard !item.title.isEmpty else { return nil }
                let column: Column = {
                    switch item.status.lowercased() {
                    case "in progress": return .wip
                    case "done":        return .done
                    default:            return .todo
                    }
                }()
                let priority: Priority = {
                    switch item.importance.lowercased() {
                    case "high": return .high
                    case "low":  return .low
                    default:     return .medium
                    }
                }()
                var task = Task(title: item.title, priority: priority, column: column)
                if let uuid = UUID(uuidString: item.id) { task.id = uuid }
                return task
            }.forEach { store.addTask($0) }
        } else {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
            parseCSV(content).forEach { store.addTask($0) }
        }
    }

    private func parseCSV(_ content: String) -> [Task] {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        var lines = content.components(separatedBy: "\n")
        guard !lines.isEmpty else { return [] }
        lines.removeFirst() // skip header
        var tasks: [Task] = []
        for line in lines {
            let fields = parseCSVLine(line)
            guard fields.count >= 1 else { continue }
            let title = fields[0].trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            let priority = fields.count > 1 ? (Priority(rawValue: fields[1].lowercased()) ?? .low) : .low
            let column: Column = {
                guard fields.count > 2 else { return .todo }
                switch fields[2].lowercased() {
                case "in progress": return .wip
                case "done":        return .done
                default:            return .todo
                }
            }()
            var task = Task(title: title, priority: priority, column: column)
            if fields.count > 3 { task.project = fields[3].trimmingCharacters(in: .whitespaces) }
            if fields.count > 4 { task.projectColorHex = fields[4].trimmingCharacters(in: .whitespaces) }
            if fields.count > 5, let date = formatter.date(from: fields[5]) { task.dueDate = date }
            if fields.count > 6 { task.notes = fields[6] }
            if fields.count > 7 {
                task.subtasks = fields[7].split(separator: "|").compactMap { part in
                    let s = part.split(separator: ":", maxSplits: 1)
                    guard s.count == 2 else { return nil }
                    return Subtask(title: String(s[0]), completed: s[1] == "1")
                }
            }
            if fields.count > 8, let date = formatter.date(from: fields[8]) { task.completedAt = date }
            if fields.count > 9 { task.archived = fields[9].trimmingCharacters(in: .whitespaces) == "1" }
            tasks.append(task)
        }
        return tasks
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if inQuotes && i + 1 < chars.count && chars[i + 1] == "\"" {
                    current.append("\""); i += 2; continue
                }
                inQuotes.toggle()
            } else if c == "," && !inQuotes {
                fields.append(current); current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        fields.append(current)
        return fields
    }

    func savePanelFrame() {
        guard let panel = PanelManager.shared.mainPanel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "kanban_panel_frame")
    }

    @objc func togglePanel() {
        guard let panel = PanelManager.shared.mainPanel else { return }
        if panel.isVisible {
            savePanelFrame()
            panel.orderOut(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            if let saved = UserDefaults.standard.string(forKey: "kanban_panel_frame") {
                panel.setFrame(NSRectFromString(saved), display: false)
            } else {
                panel.center()
            }
            panel.makeKeyAndOrderFront(nil)
        }
    }
}
