// Clean Up: a smart mass-delete tool. It reads a whole folder, groups the mail by sender, and lets you
// narrow it down (older than…, newsletters only, read only) before clearing out whole senders at once.

import SwiftUI
import AppKit

@MainActor
final class CleanupModel: ObservableObject, Identifiable {
    struct SenderGroup: Identifiable {
        var id: String             // lower-cased email address
        var address: MailAddress
        var uids: [UInt32]
        var unread: Int
        var size: Int
        var newest: Date
        var isNewsletter: Bool

        var count: Int { uids.count }
    }

    enum Age: Int, CaseIterable, Identifiable {
        case any = 0, week = 7, month = 30, threeMonths = 91, year = 365

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .any: return "Any age"
            case .week: return "Older than a week"
            case .month: return "Older than a month"
            case .threeMonths: return "Older than 3 months"
            case .year: return "Older than a year"
            }
        }
    }

    let id = UUID()
    let store: MailStore

    @Published private(set) var folder: MailFolder
    @Published private(set) var items: [CleanupItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published var age: Age = .any
    @Published var onlyNewsletters = false
    @Published var onlyRead = false
    @Published var filterText = ""
    @Published var selectedSenders: Set<String> = []
    @Published var confirming = false
    @Published var error: String?
    @Published var lastResult: String?

    init(store: MailStore, folder: MailFolder) {
        self.store = store
        self.folder = folder
    }

    /// True when removing deletes for good (the folder is Trash, or there is no Trash).
    var deletesPermanently: Bool { folder.role == .trash || store.trashFolder == nil }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            items = try await store.cleanupItems(folder: folder)
        } catch {
            items = []
            self.error = error.localizedDescription
        }
    }

    func changeFolder(_ newFolder: MailFolder) {
        guard newFolder.path != folder.path else { return }
        folder = newFolder
        items = []
        selectedSenders = []
        lastResult = nil
        Task { await load() }
    }

    private var filteredItems: [CleanupItem] {
        let cutoff: Date? = age == .any ? nil : Calendar.current.date(byAdding: .day, value: -age.rawValue, to: Date())
        return items.filter { item in
            if onlyNewsletters && !item.isNewsletter { return false }
            if onlyRead && !item.seen { return false }
            if let cutoff = cutoff, item.date > cutoff { return false }
            return true
        }
    }

    /// Senders matching the filters, biggest first. Counts only include matching emails.
    var groups: [SenderGroup] {
        var bySender: [String: SenderGroup] = [:]
        for item in filteredItems {
            let address = item.from ?? MailAddress(name: "Unknown sender", email: "")
            let key = address.email.lowercased()
            if var group = bySender[key] {
                group.uids.append(item.uid)
                group.size += item.size
                if !item.seen { group.unread += 1 }
                if item.date > group.newest { group.newest = item.date }
                if item.isNewsletter { group.isNewsletter = true }
                if group.address.name.isEmpty && !address.name.isEmpty { group.address = address }
                bySender[key] = group
            } else {
                bySender[key] = SenderGroup(id: key, address: address, uids: [item.uid], unread: item.seen ? 0 : 1,
                                            size: item.size, newest: item.date, isNewsletter: item.isNewsletter)
            }
        }
        var list = Array(bySender.values)
        let q = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { $0.address.display.lowercased().contains(q) || $0.id.contains(q) }
        }
        list.sort { a, b in
            if a.count != b.count { return a.count > b.count }
            return a.address.display.localizedCaseInsensitiveCompare(b.address.display) == .orderedAscending
        }
        return list
    }

    func removeSelected() async {
        let targets = groups.filter { selectedSenders.contains($0.id) }
        let uids = targets.flatMap { $0.uids }
        guard !uids.isEmpty else { return }
        isWorking = true
        error = nil
        lastResult = nil
        defer { isWorking = false }
        let permanent = deletesPermanently
        do {
            try await store.cleanupRemove(folder: folder, uids: uids)
            let removed = Set(uids)
            items.removeAll { removed.contains($0.uid) }
            selectedSenders.subtract(targets.map { $0.id })
            let noun = uids.count == 1 ? "1 email" : "\(uids.count) emails"
            lastResult = permanent ? "Deleted \(noun)." : "Moved \(noun) to Trash."
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - View

struct CleanupView: View {
    @ObservedObject var model: CleanupModel
    @ObservedObject var store: MailStore
    let close: () -> Void
    @AppStorage("mailTextSize") private var textSize = 0
    private func size(_ base: CGFloat) -> CGFloat { MailType.size(base, textSize) }

    private func isSelected(_ group: CleanupModel.SenderGroup) -> Binding<Bool> {
        Binding(
            get: { model.selectedSenders.contains(group.id) },
            set: { on in
                if on { model.selectedSenders.insert(group.id) } else { model.selectedSenders.remove(group.id) }
            })
    }

    private var folderChoice: Binding<String> {
        Binding(
            get: { model.folder.path },
            set: { path in if let f = store.folder(path: path) { model.changeFolder(f) } })
    }

    var body: some View {
        let groups = model.groups
        let selected = groups.filter { model.selectedSenders.contains($0.id) }
        let selectedCount = selected.reduce(0) { $0 + $1.count }
        let selectedSize = selected.reduce(0) { $0 + $1.size }
        let noun = selectedCount == 1 ? "1 email" : "\(selectedCount.formatted()) emails"
        let most = groups.map { $0.count }.max() ?? 1

        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Clean Up \(model.folder.name)")
                        .font(.system(size: size(22), weight: .semibold))
                    Text(model.deletesPermanently
                         ? "Tick the senders you want gone. Their emails are deleted permanently."
                         : "Tick the senders you want gone. Emails go to Trash, so you can still get them back.")
                        .font(.system(size: size(13)))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Picker("Mailbox:", selection: folderChoice) {
                    ForEach(store.folders) { f in
                        Text(f.name).tag(f.path)
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            HStack(spacing: 16) {
                Picker("Age", selection: $model.age) {
                    ForEach(CleanupModel.Age.allCases) { a in
                        Text(a.title).tag(a)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                Toggle("Newsletters only", isOn: $model.onlyNewsletters)
                    .toggleStyle(.checkbox)
                Toggle("Read only", isOn: $model.onlyRead)
                    .toggleStyle(.checkbox)
                Spacer()
                SearchField(text: $model.filterText, placeholder: "Filter senders")
                    .frame(width: 200)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Divider()

            ZStack {
                List {
                    ForEach(groups) { group in
                        CleanupRow(group: group, isSelected: isSelected(group), share: Double(group.count) / Double(most),
                                   showNewsletter: !model.onlyNewsletters, textSize: textSize)
                    }
                }
                .listStyle(.inset)

                if model.isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Reading \(model.folder.name)…")
                            .foregroundColor(.secondary)
                    }
                } else if groups.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 34, weight: .light))
                            .foregroundColor(.secondary)
                        Text(model.items.isEmpty ? "All Clear" : "No Matches")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(model.items.isEmpty ? "\(model.folder.name) is empty." : "Nothing matches these filters.")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button("Select All") { model.selectedSenders.formUnion(groups.map { $0.id }) }
                    .disabled(groups.isEmpty)
                Button("Select None") { model.selectedSenders.removeAll() }
                    .disabled(model.selectedSenders.isEmpty)

                if let error = model.error {
                    Text(error)
                        .font(.system(size: size(13)))
                        .foregroundColor(.red)
                        .lineLimit(2)
                } else if let result = model.lastResult {
                    Label { Text(result).foregroundColor(.secondary) } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
                    }
                    .font(.system(size: size(13)))
                }

                Spacer()

                if model.isWorking { ProgressView().controlSize(.small) }
                if selectedCount > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(selectedSize), countStyle: .file))
                        .font(.system(size: size(13)))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Button(role: .destructive) { model.confirming = true } label: {
                    Text(selectedCount == 0 ? (model.deletesPermanently ? "Delete Permanently" : "Move to Trash")
                         : model.deletesPermanently ? "Delete \(noun) Permanently" : "Move \(noun) to Trash")
                        .monospacedDigit()
                }
                .buttonStyle(.borderedProminent)
                .tint(selectedCount == 0 ? nil : .red)
                .disabled(selectedCount == 0 || model.isWorking || model.isLoading)
                Button("Done", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 820, height: 640)
        .confirmationDialog(
            model.deletesPermanently ? "Delete \(noun) permanently?" : "Move \(noun) to Trash?",
            isPresented: $model.confirming,
            titleVisibility: .visible
        ) {
            Button(model.deletesPermanently ? "Delete Permanently" : "Move to Trash", role: .destructive) {
                Task { await model.removeSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(selected.count == 1
                 ? "Everything shown from \(selected[0].address.display)."
                 : "Everything shown from \(selected.count) senders.")
        }
    }
}

/// One line of the sender ledger: who, how many, and a bar showing their share of the pile.
struct CleanupRow: View {
    let group: CleanupModel.SenderGroup
    @Binding var isSelected: Bool
    var share: Double = 1
    var showNewsletter = true
    var textSize = 0

    private func size(_ base: CGFloat) -> CGFloat { MailType.size(base, textSize) }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Clean up mail from \(group.address.display)")
            AvatarView(address: group.address, size: (32 * MailType.scale(textSize)).rounded())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(group.address.display)
                        .font(.system(size: size(14), weight: .medium))
                        .lineLimit(1)
                    if group.isNewsletter && showNewsletter {
                        Image(systemName: "newspaper")
                            .font(.system(size: size(12)))
                            .foregroundColor(.secondary)
                            .help("Newsletter")
                            .accessibilityLabel("Newsletter")
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule()
                            .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
                            .frame(width: max(4, geo.size.width * share))
                    }
                }
                .frame(height: 4)
                .animation(.easeOut(duration: 0.18), value: isSelected)
                Text(group.address.email.isEmpty ? "No address" : group.address.email)
                    .font(.system(size: size(12)))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                Text(group.count.formatted())
                    .font(.system(size: size(17), weight: .semibold))
                    .monospacedDigit()
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(group.size), countStyle: .file)) · latest \(MailDate.listString(group.newest))")
                    .font(.system(size: size(12)))
                    .foregroundColor(.secondary)
            }
            .frame(minWidth: 130, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { isSelected.toggle() }
    }
}
