import SwiftUI
import MemoirKit

/// The memory browser: everything Memoir believes about your work, and where it got it.
///
/// This screen is the trust artifact of the whole product. If a user cannot see what
/// was remembered, correct it when it is wrong, and delete it when it does not belong,
/// then "it builds a memory of your day" is a thing done *to* them rather than for them.
@MainActor
final class MemoryBrowserModel: ObservableObject {
    @Published var entities: [Entity] = []
    @Published var selected: Entity?
    /// Evidence for ``selected``, each row already resolved against its capture. A capture
    /// that retention has rolled off resolves to "source expired" rather than to nothing.
    @Published var evidence: [ProvenanceRecord] = []
    @Published var search: String = ""
    @Published var kindFilter: EntityKind?
    @Published var isLoading = false

    private let store: Store

    init(store: Store) {
        self.store = store
    }

    var filtered: [Entity] {
        entities
            .filter { kindFilter == nil || $0.kind == kindFilter }
            .filter {
                search.isEmpty
                || $0.title.localizedCaseInsensitiveContains(search)
                || ($0.detail?.localizedCaseInsensitiveContains(search) ?? false)
            }
            .sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                return $0.updatedAt > $1.updatedAt
            }
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            entities = try await store.entities(kind: nil, includeDeleted: false)
        } catch {
            Log.shared.error("memory browser reload failed: \(error)")
        }
    }

    func select(_ entity: Entity) async {
        selected = entity
        evidence = []
        do {
            evidence = try await store.evidence(entityID: entity.id)
        } catch {
            Log.shared.error("provenance load failed: \(error)")
        }
    }

    /// Saves a user edit. Sets `corrected`, which permanently protects these fields
    /// from being overwritten by any later extraction pass.
    func saveEdit(_ entity: Entity, title: String, detail: String) async {
        var updated = entity
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.detail = detail.isEmpty ? nil : detail
        updated.corrected = true
        updated.updatedAt = Date()
        do {
            try await store.upsert(entity: updated)
            selected = updated
            await reload()
        } catch {
            Log.shared.error("saving correction failed: \(error)")
        }
    }

    func togglePin(_ entity: Entity) async {
        var updated = entity
        updated.pinned.toggle()
        updated.updatedAt = Date()
        try? await store.upsert(entity: updated)
        selected = updated
        await reload()
    }

    /// Retires a row because the user said so.
    ///
    /// `corrected: true` for the same reason as `PortraitModel.dismiss`: a person's judgement
    /// and a sweep's must not write the same row. Only the two user-initiated paths pass it;
    /// the three consolidation sweeps in `MemoryService` deliberately do not.
    func delete(_ entity: Entity) async {
        try? await store.deleteEntity(id: entity.id, corrected: true)
        selected = nil
        await reload()
    }
}

struct MemoryBrowserView: View {
    @ObservedObject var model: MemoryBrowserModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $model.kindFilter) {
                    Text("All").tag(EntityKind?.none)
                    ForEach(EntityKind.allCases, id: \.self) { k in
                        Text(k.displayName).tag(EntityKind?.some(k))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .padding(8)

                List(model.filtered, selection: Binding(
                    get: { model.selected?.id },
                    set: { id in
                        if let e = model.filtered.first(where: { $0.id == id }) {
                            Task { await model.select(e) }
                        }
                    }
                )) { entity in
                    EntityRow(entity: entity).tag(entity.id)
                }
                .listStyle(.sidebar)
            }
            .searchable(text: $model.search, placement: .sidebar, prompt: "Search memory")
            .frame(minWidth: 280)
        } detail: {
            if let selected = model.selected {
                EntityDetailView(model: model, entity: selected)
            } else {
                ContentUnavailableView(
                    "Nothing selected",
                    systemImage: "brain",
                    description: Text(model.entities.isEmpty
                        ? "Memoir hasn't learned anything yet. Give it a while with capture running."
                        : "Pick something on the left to see where it came from.")
                )
            }
        }
        .navigationTitle("Memory")
        .task { await model.reload() }
    }
}

private struct EntityRow: View {
    let entity: Entity

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.title).lineLimit(1)
                if let due = entity.dueAt {
                    Text(due, style: .date)
                        .font(.caption2)
                        .foregroundStyle(due < Date() ? .red : .secondary)
                }
            }
            Spacer()
            if entity.source == .authored {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(.green)
                    .help("You wrote this: a vault note or an accepted proposal. Nothing inferred can overwrite it.")
            }
            if entity.corrected {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.blue)
                    .help("You corrected this. Memoir will never overwrite it.")
            }
            if entity.pinned {
                Image(systemName: "pin.fill").foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch entity.kind {
        case .person: return "person"
        case .project: return "folder"
        case .thread: return "bubble.left.and.bubble.right"
        case .decision: return "checkmark.seal"
        case .commitment: return "flag"
        case .note: return "note.text"
        case .place: return "mappin.and.ellipse"
        }
    }
}

private struct EntityDetailView: View {
    @ObservedObject var model: MemoryBrowserModel
    let entity: Entity

    @State private var editTitle: String = ""
    @State private var editDetail: String = ""
    @State private var editing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if editing {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Title", text: $editTitle)
                        TextField("Detail", text: $editDetail, axis: .vertical)
                            .lineLimit(3...6)
                        HStack {
                            Button("Save") {
                                Task {
                                    await model.saveEdit(entity, title: editTitle, detail: editDetail)
                                    editing = false
                                }
                            }
                            .keyboardShortcut(.defaultAction)
                            Button("Cancel") { editing = false }
                        }
                        Text("Saving marks this as corrected. Memoir will never overwrite it again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .textFieldStyle(.roundedBorder)
                } else if let detail = entity.detail {
                    Text(detail).font(.system(size: 13))
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Where this came from")
                        .font(.headline)
                    if model.evidence.isEmpty {
                        Text("No provenance recorded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.evidence) { record in
                            ProvenanceRow(record: record)
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            editTitle = entity.title
            editDetail = entity.detail ?? ""
        }
        .onChange(of: entity.id) { _, _ in
            editTitle = entity.title
            editDetail = entity.detail ?? ""
            editing = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entity.title).font(.title2).bold()
            HStack(spacing: 10) {
                Label(entity.kind.displayName, systemImage: "tag")
                Label(String(format: "%.0f%% confident", entity.confidence * 100), systemImage: "gauge")
                if let due = entity.dueAt {
                    Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                        .foregroundStyle(due < Date() ? .red : .primary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button(editing ? "Editing…" : "Correct") { editing = true }
                    .disabled(editing)
                Button(entity.pinned ? "Unpin" : "Pin") {
                    Task { await model.togglePin(entity) }
                }
                Button("Forget", role: .destructive) {
                    Task { await model.delete(entity) }
                }
            }
            .controlSize(.small)
        }
    }
}

/// One piece of evidence: the snippet, which app it came from, and when.
///
/// Captures roll off after sixty days while the memory they produced stays. When the source
/// is gone the snippet is still shown and the source line says so, which is the honest
/// degradation: never a blank, never an identifier that no longer resolves.
private struct ProvenanceRow: View {
    let record: ProvenanceRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\"\(record.snippet)\"")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                if let capture = record.capture {
                    Text(capture.appName).bold()
                    if let title = capture.windowTitle, !title.isEmpty {
                        Text("·"); Text(title).lineLimit(1)
                    }
                } else {
                    Text(ProvenanceRecord.expiredSourceLabel)
                        .italic()
                        .help("The screen this came from has rolled off. The quote is kept.")
                }
                Text("·")
                Text(record.ts.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(record.field)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
    }
}
