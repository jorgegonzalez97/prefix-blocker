import SwiftUI

/// Every switch (extension) the app has, who uses it, and the tools to fix loading problems.
struct SwitchesView: View {
    @Environment(BlockerModel.self) private var model

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(0..<AppConstants.slotCount, id: \.self) { slot in
                            SwitchCell(slot: slot, state: model.slotStates[slot])
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) { legend }
                        VStack(alignment: .leading, spacing: 6) { legend }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } header: {
                Text(summary)
            } footer: {
                Text("iOS only accepts complete phone numbers, about a million per switch, so each prefix needs \(AppConstants.shardsPerPrefix). The numbers match the names in Settings: \"Prefix Blocker 01\" to \"Prefix Blocker \(AppConstants.slotLabel(AppConstants.slotCount - 1))\".")
            }

            if !model.config.prefixes.isEmpty {
                Section("Used by") {
                    ForEach(model.config.prefixes) { prefix in
                        LabeledContent {
                            Text(SlotFormatter.ranges(model.slots(of: prefix)))
                                .monospacedDigit()
                        } label: {
                            Text(prefix.digits).monospacedDigit().fontWeight(.semibold)
                            Text(model.isPaused(prefix) ? "\(prefix.regionName) · paused" : prefix.regionName)
                        }
                    }
                }
            }

            Section {
                Button("Open Settings", systemImage: "gear") {
                    Task { await LiveCallDirectoryService.openSettings() }
                }
            } footer: {
                Text("Switches are turned on in \(SettingsPath.text). If the button lands somewhere else, follow that path.")
            }

            Section {
                Button("Reload Everything", systemImage: "arrow.clockwise") {
                    model.forgetConfirmations()
                    model.syncSoon()
                }
                .disabled(model.isSyncing || model.config.prefixes.isEmpty)
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text(troubleshootingFooter)
            }
        }
        .navigationTitle("Switches")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var legend: some View {
        LegendItem(color: Theme.greenFill, text: "On")
        LegendItem(color: Theme.orangeFill, text: "Turn on")
        LegendItem(color: Theme.blueFill, text: "Loading")
        if model.slotStates.contains(where: { if case .failed = $0 { true } else { false } }) {
            LegendItem(color: Theme.redFill, text: "Failed")
        }
        LegendItem(color: Color(.systemFill), text: "Not in use")
    }

    private var summary: String {
        let needed = model.config.activeSlots.filter { $0 != nil }.count
        let on = model.slotStates.filter { $0 == .loaded }.count
        return "\(on) of \(needed) needed switches on"
    }

    private var troubleshootingFooter: String {
        var text = "Hands the full list to iOS again. Use it if a blocked prefix still rings."
        let times = model.loadSeconds.compactMap { $0 }
        if let slowest = times.max() {
            let average = times.reduce(0, +) / Double(times.count)
            text += " Last load: \(times.count) switches, \(average.formatted(.number.precision(.fractionLength(1)))) s on average, \(slowest.formatted(.number.precision(.fractionLength(1)))) s at most."
        }
        return text
    }
}
