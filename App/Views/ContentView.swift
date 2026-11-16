import SwiftUI

/// Screens reached from the Tools section.
enum Tool: Hashable {
    case checkNumber, switches
}

struct ContentView: View {
    @Environment(BlockerModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var editor: PrefixEditor?
    @State private var detail: AreaCode?
    @State private var pendingRemoval: AreaCode?
    @State private var path: [Tool] = []

    private var canAddPrefix: Bool {
        SlotTable.canAdd(to: model.config.prefixes) && model.storageError == nil
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    StatusHeroCard(onAdd: { editor = .add })
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                // With nothing blocked, the status card already offers the only thing to do.
                if !model.config.prefixes.isEmpty {
                    Section {
                        PrefixListHeader()
                            .listRowInsets(EdgeInsets(top: 10, leading: 4, bottom: 4, trailing: 4))
                            .listRowBackground(Color.clear)
                    }

                    ForEach(model.config.prefixes) { prefix in
                        Section {
                            prefixRow(prefix)
                        }
                    }

                    Section {
                        Button {
                            editor = .add
                        } label: {
                            Label("Add Prefix", systemImage: "plus.circle.fill")
                                .font(.body.weight(.semibold))
                        }
                        .disabled(!canAddPrefix)
                    } footer: {
                        Text(prefixFooter)
                    }
                }

                Section("Tools") {
                    NavigationLink(value: Tool.checkNumber) {
                        ToolLabel(title: "Check a Number", detail: "Would this call be blocked?",
                                  systemImage: "magnifyingglass", color: Theme.blueFill)
                    }
                    NavigationLink(value: Tool.switches) {
                        ToolLabel(title: "Switches", detail: switchSummary,
                                  systemImage: "switch.2", color: Theme.greenFill)
                    }
                }

                Section("Good to know") {
                    FactRow(systemImage: "person.crop.circle.badge.checkmark",
                            text: "Your contacts and numbers you've called always ring, even from a blocked prefix. To let one number through, save it to Contacts.")
                    FactRow(systemImage: "phone.down.fill",
                            text: "Blocked calls never ring. Depending on your carrier, the caller may still reach voicemail.")
                    FactRow(systemImage: "lock.shield.fill",
                            text: "Everything happens on your iPhone. The app never sees your calls.")
                }

                Section {
                    Text("Prefix Blocker \(AppInfo.version)")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(12)
            .scrollContentBackground(.hidden)
            .background(ScreenBackground(tint: StatusHeroCard.kind(for: model).tint))
            .navigationTitle("Prefix Blocker")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Prefix", systemImage: "plus") { editor = .add }
                        .disabled(!canAddPrefix)
                }
            }
            .navigationDestination(for: Tool.self) { tool in
                switch tool {
                case .checkNumber: NumberCheckView()
                case .switches: SwitchesView()
                }
            }
            .sheet(item: $editor) { mode in
                PrefixEditorView(mode: mode)
            }
            .sheet(item: $detail) { prefix in
                PrefixDetailView(prefix: prefix)
            }
            .confirmationDialog(
                pendingRemoval.map { "Stop blocking \($0.digits)?" } ?? "",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible,
                presenting: pendingRemoval
            ) { prefix in
                Button("Remove \(prefix.digits)", role: .destructive) {
                    withAnimation { model.removePrefix(prefix) }
                    model.syncSoon()
                }
            } message: { prefix in
                Text("Calls from \(prefix.pattern) will ring again. Its switches can stay on for the next prefix you add.")
            }
            .task { await AppEnvironment.sync(model) }
            .onChange(of: scenePhase) { _, phase in
                // Coming back from Settings: pick up the switches that were just turned on.
                if phase == .active { model.syncSoon() }
            }
            .sensoryFeedback(trigger: model.overallStatus) { _, new in
                switch new {
                case .protected: return .success
                case .failed: return .error
                default: return nil
                }
            }
            .sensoryFeedback(.selection, trigger: model.config)
            .onAppear(perform: openDemoScreen)
        }
    }

    private func prefixRow(_ prefix: AreaCode) -> some View {
        let paused = model.isPaused(prefix)
        return Button {
            detail = prefix
        } label: {
            PrefixRow(prefix: prefix)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Remove", systemImage: "trash") { pendingRemoval = prefix }
                .tint(.red)
            Button("Change", systemImage: "pencil") { editor = .edit(prefix) }
                .tint(.indigo)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") {
                togglePause(prefix)
            }
            .tint(paused ? .green : .orange)
        }
        .contextMenu {
            Button(paused ? "Resume Blocking" : "Pause Blocking", systemImage: paused ? "play" : "pause") {
                togglePause(prefix)
            }
            Button("Change Prefix", systemImage: "pencil") { editor = .edit(prefix) }
            Button("Remove", systemImage: "trash", role: .destructive) { pendingRemoval = prefix }
        }
    }

    private func togglePause(_ prefix: AreaCode) {
        withAnimation { model.setPaused(prefix, !model.isPaused(prefix)) }
        model.syncSoon()
    }

    private var prefixFooter: String {
        if !SlotTable.canAdd(to: model.config.prefixes) {
            return "That's the most the app can block at once. Remove or change a prefix to block another."
        }
        return "Tap a prefix for details. Swipe left to change or remove it, right to pause it."
    }

    private var switchSummary: String {
        let needed = model.config.activeSlots.filter { $0 != nil }.count
        let on = model.slotStates.filter { $0 == .loaded }.count
        return needed == 0 ? "None in use" : "\(on) of \(needed) on"
    }

    private func openDemoScreen() {
        #if DEBUG
        guard editor == nil, detail == nil, path.isEmpty else { return }
        switch AppEnvironment.demoScreen {
        case "add": editor = .add
        case "edit": if let first = model.config.prefixes.first { editor = .edit(first) }
        case "detail": detail = model.config.prefixes.last
        case "check": path = [.checkNumber]
        case "switches": path = [.switches]
        default: break
        }
        #endif
    }
}

enum AppInfo {
    /// "1.1 (2)"
    static let version: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "\(short) (\(build))"
    }()
}

private struct ToolLabel: View {
    let title: String
    let detail: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct FactRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
