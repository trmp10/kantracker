import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Pointer Cursor

extension View {
    func pointerCursor() -> some View {
        self.onHover { hovering in
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Color Hex

extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let val = UInt64(h, radix: 16) else { return nil }
        self.init(
            red: Double((val >> 16) & 0xFF) / 255,
            green: Double((val >> 8) & 0xFF) / 255,
            blue: Double(val & 0xFF) / 255
        )
    }

    static func isLightHex(_ hex: String) -> Bool {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let val = UInt64(h, radix: 16) else { return false }
        let r = Double((val >> 16) & 0xFF) / 255
        let g = Double((val >> 8) & 0xFF) / 255
        let b = Double(val & 0xFF) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b > 0.6
    }
}

// MARK: - Project

struct Project: Identifiable, Codable {
    var id = UUID()
    var name: String
    var colorHex: String

    var color: Color { Color(hex: colorHex) ?? .blue }

    static let presetColors = [
        "#FF4D4D", "#FF8C42", "#FFD166", "#52C41A",
        "#13C2C2", "#4361EE", "#9B5DE5", "#FF6B9D"
    ]
}

// MARK: - Priority

enum Priority: String, Codable, CaseIterable {
    case low, medium, high

    var color: Color {
        switch self {
        case .low:    return Color.yellow
        case .medium: return Color.orange
        case .high:   return Color.red
        }
    }

    var label: String {
        switch self {
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }

    func next() -> Priority {
        switch self {
        case .low:    return .medium
        case .medium: return .high
        case .high:   return .low
        }
    }

    var sortOrder: Int {
        switch self {
        case .high:   return 0
        case .medium: return 1
        case .low:    return 2
        }
    }
}

// MARK: - Column

enum Column: String, Codable, CaseIterable {
    case todo    = "To do"
    case wip     = "In progress"
    case waiting = "Waiting"
    case done    = "Done"

    var label: String {
        switch self {
        case .todo:    return "TO DO"
        case .waiting: return "WAITING"
        case .wip:     return "IN PROGRESS"
        case .done:    return "DONE"
        }
    }

    var pickerColor: Color {
        switch self {
        case .todo:    return Color.primary.opacity(0.45)
        case .waiting: return Color(hex: "#118AB2") ?? .blue
        case .wip:     return Color.yellow
        case .done:    return Color(hex: "#52C41A") ?? .green
        }
    }

    var pickerTextColor: Color {
        switch self {
        case .todo:    return .white
        case .waiting: return .white
        case .wip:     return .black.opacity(0.7)
        case .done:    return .white
        }
    }

}

// MARK: - Subtask

struct Subtask: Identifiable, Codable {
    var id = UUID()
    var title: String
    var completed: Bool = false
}

// MARK: - Task

struct Task: Identifiable, Codable {
    var id = UUID()
    var title: String
    var priority: Priority = .low
    var column: Column
    var project: String = ""
    var projectColorHex: String = ""
    var dueDate: Date? = nil
    var notes: String = ""
    var subtasks: [Subtask] = []
    var completedAt: Date? = nil
    var archived: Bool = false
    var createdAt: Date = Date()
}

// MARK: - Store

class KanbanStore: ObservableObject {
    @Published var tasks: [Task] = [] {
        didSet { saveTasks() }
    }
    @Published var projects: [Project] = [] {
        didSet { saveProjects() }
    }

    init() {
        loadTasks()
        loadProjects()
        archiveStale()
    }

    private var undoHistory: [[Task]] = []

    func tasks(in column: Column) -> [Task] { tasks.filter { $0.column == column && !$0.archived } }

    func archiveStale() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -45, to: Date()) ?? Date()
        var updated = tasks
        var changed = false
        for i in updated.indices where updated[i].column == .done && !updated[i].archived {
            if let completedAt = updated[i].completedAt, completedAt < cutoff {
                updated[i].archived = true
                changed = true
            }
        }
        if changed { tasks = updated }
    }

    func addTask(_ task: Task) { saveForUndo(); tasks.append(task) }
    func delete(_ task: Task) { saveForUndo(); tasks.removeAll { $0.id == task.id } }

    func undo() {
        guard let previous = undoHistory.popLast() else { return }
        tasks = previous
    }

    private func saveForUndo() {
        undoHistory.append(tasks)
        if undoHistory.count > 20 { undoHistory.removeFirst() }
    }

    func cyclePriority(_ task: Task) { update(task) { $0.priority = $0.priority.next() } }

    func toggleSubtask(_ subtaskId: UUID, in task: Task) {
        update(task) { t in
            guard let i = t.subtasks.firstIndex(where: { $0.id == subtaskId }) else { return }
            t.subtasks[i].completed.toggle()
        }
    }
    func updateTask(_ task: Task) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        var updated = task
        if updated.column == .done && tasks[i].completedAt == nil {
            updated.completedAt = Date()
        } else if updated.column != .done {
            updated.completedAt = nil
        }
        tasks[i] = updated
    }

    func move(taskId: UUID, to column: Column) {
        saveForUndo()
        guard let i = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[i].column = column
        if column == .done && tasks[i].completedAt == nil {
            tasks[i].completedAt = Date()
        } else if column != .done {
            tasks[i].completedAt = nil
        }
    }



    func addProject(_ project: Project) { projects.append(project) }
    func deleteProject(_ project: Project) { projects.removeAll { $0.id == project.id } }

    private func update(_ task: Task, mutation: (inout Task) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        mutation(&tasks[i])
    }

    private func saveTasks() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: "kanban_tasks")
        }
    }

    private func loadTasks() {
        guard let data = UserDefaults.standard.data(forKey: "kanban_tasks"),
              let saved = try? JSONDecoder().decode([Task].self, from: data)
        else { return }
        tasks = saved
    }

    private func saveProjects() {
        if let data = try? JSONEncoder().encode(projects) {
            UserDefaults.standard.set(data, forKey: "kanban_projects")
        }
    }

    private func loadProjects() {
        guard let data = UserDefaults.standard.data(forKey: "kanban_projects"),
              let saved = try? JSONDecoder().decode([Project].self, from: data)
        else { return }
        projects = saved
    }

    func buildCSV() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        var lines = ["Title,Priority,Status,Project,Project Color,Due Date,Notes,Subtasks,Completed At,Archived"]
        for task in tasks {
            let title       = "\"\(task.title.replacingOccurrences(of: "\"", with: "\"\""))\""
            let project     = "\"\(task.project.replacingOccurrences(of: "\"", with: "\"\""))\""
            let due         = task.dueDate.map { formatter.string(from: $0) } ?? ""
            let notes       = "\"\(task.notes.replacingOccurrences(of: "\"", with: "\"\""))\""
            let subtasks    = "\"\(task.subtasks.map { "\($0.title):\($0.completed ? "1" : "0")" }.joined(separator: "|"))\""
            let completedAt = task.completedAt.map { formatter.string(from: $0) } ?? ""
            let archived    = task.archived ? "1" : "0"
            lines.append("\(title),\(task.priority.label),\(task.column.rawValue),\(project),\(task.projectColorHex),\(due),\(notes),\(subtasks),\(completedAt),\(archived)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Content View

struct ContentView: View {
    @ObservedObject var store: KanbanStore
    @State private var searchText = ""
    @State private var quickAddText = ""
    @State private var addTaskColumn: Column? = nil
    @State private var editingTask: Task? = nil
    @State private var priorityFilters: Set<Priority> = []
    @State private var projectFilters: Set<String> = []
    @FocusState private var searchFocused: Bool
    @FocusState private var quickAddFocused: Bool

    private var showingModal: Bool { addTaskColumn != nil || editingTask != nil }
    private var hasActiveFilters: Bool { !priorityFilters.isEmpty || !projectFilters.isEmpty }

    private func dismissModal() {
        addTaskColumn = nil
        editingTask = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { quickAddFocused = true }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    // Quick add
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .foregroundColor(.secondary)
                            .font(.system(size: 14))
                        TextField("Add task", text: $quickAddText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16))
                            .focused($quickAddFocused)
                            .onSubmit {
                                let trimmed = quickAddText.trimmingCharacters(in: .whitespaces)
                                guard !trimmed.isEmpty else { return }
                                store.addTask(Task(title: trimmed, column: .todo))
                                quickAddText = ""
                            }
                            .onExitCommand {
                                if quickAddText.isEmpty { PanelManager.shared.mainPanel?.orderOut(nil) }
                                else { quickAddText = "" }
                            }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .frame(maxWidth: .infinity)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(8)

                    // Search
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.system(size: 14))
                        TextField("Search...", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16))
                            .focused($searchFocused)
                            .onExitCommand { searchText = "" }
                            .onSubmit { searchFocused = false }
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .frame(width: 180)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(8)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

                filterRow
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 14)

                HStack(alignment: .top, spacing: 10) {
                    ForEach(Column.allCases, id: \.self) { column in
                        ColumnView(
                            column: column,
                            store: store,
                            searchText: searchText,
                            priorityFilters: priorityFilters,
                            projectFilters: projectFilters,
                            onAddTask: { addTaskColumn = column },
                            onEditTask: { editingTask = $0 }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color(NSColor.windowBackgroundColor))

            if showingModal {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { dismissModal() }

                if let col = addTaskColumn {
                    AddTaskModalView(column: col, store: store, onSave: { task in
                        store.addTask(task)
                        dismissModal()
                    }, onDismiss: { dismissModal() })
                } else if let task = editingTask {
                    AddTaskModalView(column: task.column, store: store, existingTask: task, onSave: { updated in
                        store.updateTask(updated)
                        dismissModal()
                    }, onDismiss: { dismissModal() })
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showingModal)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            guard !showingModal else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { quickAddFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleNewTask)) { _ in
            if addTaskColumn != nil || editingTask != nil {
                addTaskColumn = nil
                editingTask = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { quickAddFocused = true }
            } else {
                addTaskColumn = .todo
            }
        }
        // Cmd+Z: undo
        .background(
            Button("") { store.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .opacity(0)
        )
        .onExitCommand {
            if showingModal {
                dismissModal()
            } else {
                PanelManager.shared.mainPanel?.orderOut(nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportCSV)) { _ in
            let csv = store.buildCSV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType.commaSeparatedText]
                panel.nameFieldStringValue = "kantracker-export.csv"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try? csv.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    @ViewBuilder
    private var filterRow: some View {
        let hasProjects = !store.projects.isEmpty
        if !Priority.allCases.isEmpty || hasProjects {
            HStack(spacing: 6) {
                ForEach(Priority.allCases, id: \.self) { p in
                    FilterPriorityPill(priority: p, isActive: priorityFilters.contains(p)) {
                        if priorityFilters.contains(p) { priorityFilters.remove(p) }
                        else { priorityFilters.insert(p) }
                    }
                }

                if hasProjects {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 2)

                    ProjectFilterDropdown(
                        projects: store.projects,
                        activeFilters: $projectFilters
                    )
                }

                if hasActiveFilters {
                    ClearFiltersButton {
                        priorityFilters.removeAll()
                        projectFilters.removeAll()
                    }
                }

                Spacer()
            }
        }
    }
}

// MARK: - Filter Pills

struct ClearFiltersButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("Clear")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isHovered ? .primary : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

struct FilterPriorityPill: View {
    let priority: Priority
    let isActive: Bool
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Text(priority.label)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(isActive ? (priority == .low ? .black.opacity(0.7) : .white) : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isActive ? priority.color : (isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.05)))
            .cornerRadius(6)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .onTapGesture { onTap() }
    }
}

struct ProjectFilterDropdown: View {
    let projects: [Project]
    @Binding var activeFilters: Set<String>
    @State private var showPopover = false
    @State private var isHovered = false

    private var activeCount: Int { activeFilters.count }

    var body: some View {
        Button(action: { showPopover.toggle() }) {
            HStack(spacing: 4) {
                Text("Project")
                    .font(.system(size: 13, weight: .medium))
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(activeCount > 0 ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isHovered || showPopover ? Color.primary.opacity(0.08) : Color.primary.opacity(0.05))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(projects) { project in
                    ProjectFilterRow(
                        project: project,
                        isSelected: activeFilters.contains(project.name)
                    ) {
                        if activeFilters.contains(project.name) { activeFilters.remove(project.name) }
                        else { activeFilters.insert(project.name) }
                    }
                }
            }
            .padding(6)
            .frame(minWidth: 160)
            .presentationCornerRadius(8)
        }
    }
}

struct ProjectFilterRow: View {
    let project: Project
    let isSelected: Bool
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(project.color)
                .frame(width: 8, height: 8)
            Text(project.name)
                .font(.system(size: 13))
                .foregroundColor(.primary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .onTapGesture { onTap() }
    }
}

// MARK: - Column View

struct ColumnView: View {
    let column: Column
    @ObservedObject var store: KanbanStore
    let searchText: String
    let priorityFilters: Set<Priority>
    let projectFilters: Set<String>
    let onAddTask: () -> Void
    let onEditTask: (Task) -> Void
    @State private var isDropTargeted = false
    @State private var addTaskHovered = false

    var tasks: [Task] {
        var all = store.tasks(in: column)
        if !searchText.isEmpty {
            all = all.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        if !priorityFilters.isEmpty {
            all = all.filter { priorityFilters.contains($0.priority) }
        }
        if !projectFilters.isEmpty {
            all = all.filter { projectFilters.contains($0.project) }
        }
        return all.sorted { a, b in
            switch (a.dueDate, b.dueDate) {
            case (let da?, let db?):
                if da != db { return da < db }
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): break
            }
            return a.priority.sortOrder < b.priority.sortOrder
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader
                .padding(.bottom, 8)
            if tasks.isEmpty {
                Text("No tasks")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(tasks) { task in
                            TaskCardView(task: task, store: store, onEdit: { onEditTask(task) })
                        }
                    }
                }
            }
            addButton
                .padding(.top, 4)
        }
        .padding(8)
        .background(isDropTargeted ? Color.primary.opacity(0.08) : Color.primary.opacity(0.03))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .cornerRadius(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDrop(of: [UTType.plainText], isTargeted: $isDropTargeted) { providers in
            providers.first?.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let idString = String(data: data, encoding: .utf8),
                      let uuid = UUID(uuidString: idString)
                else { return }
                DispatchQueue.main.async { store.move(taskId: uuid, to: column) }
            }
            return true
        }
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }

    private var columnHeader: some View {
        HStack {
            Text(column.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.8)
            Spacer()
            Text("\(tasks.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08))
                .clipShape(Capsule())
        }
    }

    private var addButton: some View {
        Button(action: { onAddTask() }) {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                Text("Add task").font(.system(size: 14))
            }
            .foregroundColor(addTaskHovered ? .primary : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(addTaskHovered ? Color.primary.opacity(0.06) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            addTaskHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

// MARK: - Task Card

struct TaskCardView: View {
    let task: Task
    @ObservedObject var store: KanbanStore
    let onEdit: () -> Void
    @State private var isHovered = false

    private var dueDateInfo: (text: String, color: Color)? {
        guard let date = task.dueDate else { return nil }
        if task.column == .done {
            let f = DateFormatter(); f.dateStyle = .short
            return (f.string(from: date), .secondary)
        }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<(-1): return ("\(abs(days))d overdue", .red)
        case -1:      return ("1d overdue", .red)
        case 0:       return ("Today", .orange)
        case 1:       return ("Tomorrow", Color(hex: "#FFD166") ?? .yellow)
        default:
            let f = DateFormatter(); f.dateFormat = "MMM d"
            return (f.string(from: date), .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Circle()
                    .fill(task.priority.color)
                    .frame(width: 12, height: 12)
                    .onTapGesture { store.cyclePriority(task) }
                    .pointerCursor()
                Spacer()
                if let info = dueDateInfo {
                    Text(info.text)
                        .font(.system(size: 14))
                        .foregroundColor(info.color)
                }
            }

            Text(task.title.isEmpty ? "New task" : task.title)
                .font(.system(size: 16))
                .foregroundColor(task.title.isEmpty ? .secondary : .primary)
                .strikethrough(task.column == .done, color: .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if !task.project.isEmpty {
                    Text(task.project)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.isLightHex(task.projectColorHex) ? .black.opacity(0.7) : .white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(hex: task.projectColorHex) ?? Color.accentColor)
                        .cornerRadius(3)
                }
                if !task.notes.isEmpty {
                    Image(systemName: "note.text")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                if !task.subtasks.isEmpty {
                    let done = task.subtasks.filter(\.completed).count
                    Text("\(done)/\(task.subtasks.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(3)
                }
            }

            if !task.subtasks.isEmpty {
                VStack(spacing: 4) {
                    ForEach(task.subtasks) { subtask in
                        HStack(spacing: 6) {
                            Image(systemName: subtask.completed ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 13))
                                .foregroundColor(subtask.completed ? .accentColor : .secondary)
                                .onTapGesture { store.toggleSubtask(subtask.id, in: task) }
                                .pointerCursor()
                            Text(subtask.title)
                                .font(.system(size: 13))
                                .foregroundColor(subtask.completed ? .secondary : .primary)
                                .strikethrough(subtask.completed, color: .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(isHovered ? Color(NSColor.controlBackgroundColor).opacity(0.8) : Color(NSColor.controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.2), lineWidth: 1))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .onTapGesture { onEdit() }
        .onDrag({
            NSItemProvider(item: task.id.uuidString.data(using: .utf8)! as NSData, typeIdentifier: UTType.plainText.identifier)
        }, preview: {
            VStack(alignment: .leading, spacing: 6) {
                Circle()
                    .fill(task.priority.color)
                    .frame(width: 12, height: 12)
                Text(task.title)
                    .font(.system(size: 16))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(width: 200)
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.2), lineWidth: 1))
            .cornerRadius(6)
        })
    }
}

// MARK: - Project Pill

struct ProjectPill: View {
    let project: Project
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false
    @State private var showingDeleteConfirm = false

    var body: some View {
        HStack(spacing: 5) {
            Text(project.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isSelected ? (Color.isLightHex(project.colorHex) ? .black.opacity(0.7) : .white) : .secondary)
            if isHovered {
                Button(action: { showingDeleteConfirm = true }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(isSelected ? project.color : (isHovered ? Color.primary.opacity(0.10) : Color.primary.opacity(0.06)))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .simultaneousGesture(TapGesture().onEnded { onTap() })
        .alert("Delete \"\(project.name)\"?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tasks using this project will keep the label but the project won't be available to select.")
        }
    }
}

// MARK: - Project Picker

struct ProjectPickerView: View {
    @ObservedObject var store: KanbanStore
    @Binding var selectedProject: Project?

    @State private var showingNew = false
    @State private var newName = ""
    @State private var newColorHex: String = Project.presetColors[5]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 6) {
                ForEach(store.projects) { project in
                    projectPill(project)
                }
                if !showingNew {
                    Button(action: { showingNew = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                            Text("New project").font(.system(size: 13))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 28)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }

            if showingNew {
                newProjectForm
            }
        }
    }

    private func projectPill(_ project: Project) -> some View {
        ProjectPill(
            project: project,
            isSelected: selectedProject?.id == project.id,
            onTap: { selectedProject = selectedProject?.id == project.id ? nil : project },
            onDelete: {
                if selectedProject?.id == project.id { selectedProject = nil }
                store.deleteProject(project)
            }
        )
    }

    private var newProjectForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Project.presetColors, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex) ?? .blue)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().stroke(Color.primary.opacity(newColorHex == hex ? 0.6 : 0), lineWidth: 2)
                        )
                        .onTapGesture { newColorHex = hex }
                        .pointerCursor()
                }
            }
            HStack(spacing: 8) {
                TextField("Project name", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(minHeight: 28)
                    .padding(.horizontal, 8)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(6)
                    .onSubmit { saveNewProject() }

                Button("Add") { saveNewProject() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(newName.isEmpty ? .secondary : .primary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 28)
                    .background(Color.primary.opacity(0.08))
                    .cornerRadius(6)
                    .disabled(newName.isEmpty)
                    .pointerCursor()

                Button("Cancel") {
                    showingNew = false
                    newName = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .pointerCursor()
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }

    private func saveNewProject() {
        guard !newName.isEmpty else { return }
        let project = Project(name: newName, colorHex: newColorHex)
        store.addProject(project)
        selectedProject = project
        showingNew = false
        newName = ""
    }
}

// MARK: - Custom Date Picker

struct CustomDatePicker: View {
    @Binding var date: Date?
    @State private var isExpanded = false
    @State private var displayedMonth: Date

    private let cal = Calendar.current
    private let dayLabels = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    init(date: Binding<Date?>) {
        self._date = date
        let ref = date.wrappedValue ?? Date()
        let start = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: ref)) ?? ref
        self._displayedMonth = State(initialValue: start)
    }

    var body: some View {
        VStack(spacing: 6) {
            trigger
            if isExpanded {
                grid
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }

    private var trigger: some View {
        HStack(spacing: 6) {
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    if let d = date {
                        Text(formatted(d))
                            .font(.system(size: 14))
                            .foregroundColor(.primary)
                    } else {
                        Text("Add due date")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary.opacity(0.4))
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if date != nil {
                Button(action: { date = nil; isExpanded = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    private var grid: some View {
        VStack(spacing: 4) {
            HStack {
                Button(action: { displayedMonth = cal.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth }) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                Spacer()
                Text(monthYearString).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: { displayedMonth = cal.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth }) {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .foregroundColor(.primary)

            HStack(spacing: 0) {
                ForEach(dayLabels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 12)

            let days = generateDays()
            let rows = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(rows[r].indices, id: \.self) { c in
                        if let day = rows[r][c] {
                            DayCell(day: day, selectedDate: date, displayedMonth: displayedMonth) {
                                date = day
                                isExpanded = false
                            }
                        } else {
                            Color.clear.frame(maxWidth: .infinity, minHeight: 26)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 20)
        .frame(width: 280, height: 260)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private func formatted(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; return f.string(from: d)
    }

    private var monthYearString: String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f.string(from: displayedMonth)
    }

    private func generateDays() -> [Date?] {
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: displayedMonth)),
              let range = cal.range(of: .day, in: .month, for: monthStart)
        else { return [] }
        let offset = cal.component(.weekday, from: monthStart) - 1
        var days: [Date?] = Array(repeating: nil, count: offset)
        for d in range { days.append(cal.date(byAdding: .day, value: d - 1, to: monthStart)) }
        while days.count < 42 { days.append(nil) }
        return days
    }
}

struct DayCell: View {
    let day: Date
    let selectedDate: Date?
    let displayedMonth: Date
    let onTap: () -> Void
    @State private var isHovered = false
    private let cal = Calendar.current

    private var isSelected: Bool {
        guard let s = selectedDate else { return false }
        return cal.isDate(day, inSameDayAs: s)
    }
    private var isToday: Bool { cal.isDateInToday(day) }
    private var isCurrentMonth: Bool { cal.isDate(day, equalTo: displayedMonth, toGranularity: .month) }

    var body: some View {
        ZStack {
            if isSelected {
                Circle().fill(Color.accentColor).frame(width: 24, height: 24)
            } else if isHovered && isCurrentMonth {
                Circle().fill(Color.primary.opacity(0.08)).frame(width: 24, height: 24)
            }
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(
                        isSelected ? .white :
                        !isCurrentMonth ? Color.primary.opacity(0.25) : .primary
                    )
                if isToday && !isSelected {
                    Circle().fill(Color.accentColor).frame(width: 3, height: 3)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 26)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { if isCurrentMonth { onTap() } }
    }
}

// MARK: - Column Picker Pill

struct ColumnPickerPill: View {
    let col: Column
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(col.rawValue)
                .font(.system(size: 14))
                .foregroundColor(isSelected ? col.pickerTextColor : (isHovered ? .primary : .secondary))
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .background(isSelected ? col.pickerColor : (isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04)))
                .cornerRadius(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

// MARK: - Modal Priority Pill

struct ModalPriorityPill: View {
    let p: Priority
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(p.label)
                .font(.system(size: 14))
                .foregroundColor(isSelected ? (p == .low ? .black.opacity(0.7) : .white) : (isHovered ? .primary : .secondary))
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(isSelected ? p.color : (isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04)))
                .cornerRadius(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

// MARK: - Subtask Row

struct SubtaskRow: View {
    let subtask: Subtask
    let onToggle: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: subtask.completed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundColor(subtask.completed ? .accentColor : .secondary)
            Text(subtask.title)
                .font(.system(size: 14))
                .foregroundColor(subtask.completed ? .secondary : .primary)
                .strikethrough(subtask.completed, color: .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 36)
        .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .simultaneousGesture(TapGesture().onEnded { onToggle() })
    }
}

// MARK: - Add Task Modal

struct AddTaskModalView: View {
    let onSave: (Task) -> Void
    let onDismiss: () -> Void
    let existingTask: Task?

    @ObservedObject var store: KanbanStore
    @State private var title = ""
    @State private var notes = ""
    @State private var subtasks: [Subtask] = []
    @State private var newSubtaskTitle = ""
    @State private var dueDate: Date? = nil
    @State private var priority: Priority = .low
    @State private var selectedColumn: Column
    @State private var selectedProject: Project?
    @FocusState private var titleFocused: Bool
    @State private var deleteHovered = false
    @State private var cancelHovered = false
    @State private var showingDeleteConfirm = false

    private var isEditing: Bool { existingTask != nil }

    private var createdAtFormatted: String {
        guard let date = existingTask?.createdAt else { return "" }
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }

    init(column: Column, store: KanbanStore, existingTask: Task? = nil, onSave: @escaping (Task) -> Void, onDismiss: @escaping () -> Void) {
        self.existingTask = existingTask
        self._selectedColumn = State(initialValue: existingTask?.column ?? column)
        self._title = State(initialValue: existingTask?.title ?? "")
        self._notes = State(initialValue: existingTask?.notes ?? "")
        self._subtasks = State(initialValue: existingTask?.subtasks ?? [])
        self._priority = State(initialValue: existingTask?.priority ?? .low)
        self._dueDate = State(initialValue: existingTask?.dueDate)
        let project = existingTask.flatMap { task in
            store.projects.first { $0.name == task.project }
        }
        self._selectedProject = State(initialValue: project)
        self.store = store
        self.onSave = onSave
        self.onDismiss = onDismiss
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(isEditing ? "Edit task" : "New task")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.primary)
                Spacer()
                if isEditing {
                    Text("Added \(createdAtFormatted)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }

            columnPicker

            ZStack(alignment: .leading) {
                if title.isEmpty {
                    Text("Task")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary.opacity(0.4))
                        .padding(.horizontal, 10)
                        .allowsHitTesting(false)
                }
                TextField("", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .frame(minHeight: 36)
                    .padding(.horizontal, 10)
                    .focused($titleFocused)
                    .onAppear { titleFocused = true }
                    .onSubmit { if !title.isEmpty { save() } }
            }
            .background(Color.primary.opacity(0.06))
            .cornerRadius(8)

            ProjectPickerView(store: store, selectedProject: $selectedProject)

            CustomDatePicker(date: $dueDate)

            priorityPills

            // Notes
            ZStack(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("Add notes...")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary.opacity(0.4))
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
                TextField("", text: $notes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(3...6)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
            }
            .background(Color.primary.opacity(0.06))
            .cornerRadius(8)

            // Subtasks
            VStack(alignment: .leading, spacing: 4) {
                if !subtasks.isEmpty {
                    ForEach(subtasks) { subtask in
                        SubtaskRow(subtask: subtask,
                            onToggle: {
                                guard let i = subtasks.firstIndex(where: { $0.id == subtask.id }) else { return }
                                subtasks[i].completed.toggle()
                            },
                            onDelete: { subtasks.removeAll { $0.id == subtask.id } }
                        )
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.4))
                    ZStack(alignment: .leading) {
                        if newSubtaskTitle.isEmpty {
                            Text("Add subtask...")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary.opacity(0.4))
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $newSubtaskTitle)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .onSubmit {
                                guard !newSubtaskTitle.isEmpty else { return }
                                subtasks.append(Subtask(title: newSubtaskTitle))
                                newSubtaskTitle = ""
                            }
                    }
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(8)
                .pointerCursor()
            }

            Divider()

            HStack {
                if isEditing, let task = existingTask {
                    Button(action: { deleteHovered = false; showingDeleteConfirm = true }) {
                        Text("Delete task")
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(deleteHovered ? Color.primary.opacity(0.06) : Color.clear)
                            .cornerRadius(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        deleteHovered = hovering
                        if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                    .alert("Delete \"\(task.title)\"?", isPresented: $showingDeleteConfirm) {
                        Button("Delete", role: .destructive) { store.delete(task); onDismiss() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This action cannot be undone.")
                    }
                }
                Spacer()
                Button(action: { onDismiss() }) {
                    Text("Cancel")
                        .font(.system(size: 14))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(cancelHovered ? Color.primary.opacity(0.06) : Color.clear)
                        .cornerRadius(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    cancelHovered = hovering
                    if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }

                Button(isEditing ? "Save" : "Add task") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(title.isEmpty ? .secondary : .white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(title.isEmpty ? Color.primary.opacity(0.08) : Color.accentColor)
                    .cornerRadius(8)
                    .contentShape(Rectangle())
                    .disabled(title.isEmpty)
                    .pointerCursor()
            }
        }
        .padding(24)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
    }

    private var priorityPills: some View {
        HStack(spacing: 8) {
            ForEach(Priority.allCases, id: \.self) { p in
                ModalPriorityPill(p: p, isSelected: priority == p) { priority = p }
            }
            Spacer()
        }
    }

    private var columnPicker: some View {
        HStack(spacing: 8) {
            ForEach(Column.allCases, id: \.self) { col in
                ColumnPickerPill(col: col, isSelected: selectedColumn == col) {
                    selectedColumn = col
                }
            }
            Spacer()
        }
    }

    private func save() {
        var task = existingTask ?? Task(title: title, priority: priority, column: selectedColumn)
        task.title = title
        task.priority = priority
        task.column = selectedColumn
        task.project = selectedProject?.name ?? ""
        task.projectColorHex = selectedProject?.colorHex ?? ""
        task.dueDate = dueDate
        task.notes = notes
        task.subtasks = subtasks
        onSave(task)
        onDismiss()
    }
}
