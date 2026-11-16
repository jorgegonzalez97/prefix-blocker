import SwiftUI

/// Everything about one prefix: what it covers, its switches, and what can be done with it.
struct PrefixDetailView: View {
    @Environment(BlockerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Changes when the user edits the prefix from this sheet.
    @State var prefix: AreaCode
    @State private var editing = false
    @State private var confirmingRemoval = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    var body: some View {
        let status = model.status(of: prefix)
        let slots = model.slots(of: prefix)
        let paused = status == .paused

        NavigationStack {
            List {
                Section {
                    header(status)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(slots, id: \.self) { slot in
                            SwitchCell(slot: slot, state: paused ? .unused : model.slotStates[slot])
                        }
                    }
                    .padding(.vertical, 4)
                    if case .needsSwitches = status {
                        Button("Open Settings", systemImage: "gear") {
                            Task { await LiveCallDirectoryService.openSettings() }
                        }
                    }
                    if case .failed = status {
                        Button("Try Again", systemImage: "arrow.clockwise") { model.syncSoon() }
                    }
                } header: {
                    Text("Switches \(SlotFormatter.ranges(slots))")
                } footer: {
                    Text(switchFooter(status))
                }

                Section("Coverage") {
                    LabeledContent("Numbers", value: AreaCode.numbersPerAreaCode.formatted())
                    LabeledContent("First", value: NumberCheck.formatted(prefix.range.lower))
                    LabeledContent("Last", value: NumberCheck.formatted(prefix.range.upper))
                }
                .monospacedDigit()

                Section {
                    Button(paused ? "Resume Blocking" : "Pause Blocking", systemImage: paused ? "play.fill" : "pause.fill") {
                        withAnimation { model.setPaused(prefix, !paused) }
                        model.syncSoon()
                    }
                    Button("Change Prefix", systemImage: "pencil") { editing = true }
                    Button("Remove", systemImage: "trash", role: .destructive) { confirmingRemoval = true }
                } footer: {
                    Text(paused
                         ? "Paused: calls from \(prefix.digits) ring. Its switches stay reserved, so resuming needs nothing in Settings."
                         : "Pause to let calls from \(prefix.digits) ring for a while, for example when you expect a call back.")
                }
            }
            .navigationTitle("Prefix \(prefix.digits)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $editing) {
                PrefixEditorView(mode: .edit(prefix)) { prefix = $0 }
            }
            .confirmationDialog("Stop blocking \(prefix.digits)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button("Remove \(prefix.digits)", role: .destructive) {
                    model.removePrefix(prefix)
                    model.syncSoon()
                    dismiss()
                }
            } message: {
                Text("Calls from \(prefix.pattern) will ring again. Its switches can stay on for the next prefix you add.")
            }
        }
        .presentationDetents([.medium, .large])
        // Opaque, so the main screen doesn't show through the half-height sheet.
        .presentationBackground(Color(.systemGroupedBackground))
    }

    private func header(_ status: PrefixStatus) -> some View {
        let pill = status.pill(isSyncing: model.isSyncing)
        return HStack(spacing: 16) {
            DigitsBadge(digits: prefix.digits, dimmed: status == .paused, size: 76)
            VStack(alignment: .leading, spacing: 6) {
                Text(prefix.regionName)
                    .font(.title3.bold())
                Text(prefix.pattern)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                StatusPill(text: pill.text, systemImage: pill.systemImage, color: pill.color)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func switchFooter(_ status: PrefixStatus) -> String {
        switch status {
        case .active:
            return "All on. iOS is blocking every number of this prefix."
        case .paused:
            return "Reserved for this prefix while it is paused."
        case .needsSwitches(let slots):
            return "Turn on Prefix Blocker \(SlotFormatter.ranges(slots)) in \(SettingsPath.text), then come back."
        case .loading:
            return "iOS is loading the numbers. Keep the app open."
        case .failed(let message):
            return message
        }
    }
}
