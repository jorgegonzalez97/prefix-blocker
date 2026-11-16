import SwiftUI

/// One blocked prefix in the main list.
struct PrefixRow: View {
    @Environment(BlockerModel.self) private var model
    let prefix: AreaCode

    var body: some View {
        let status = model.status(of: prefix)
        let slots = model.slots(of: prefix)
        let pill = status.pill(isSyncing: model.isSyncing)

        HStack(alignment: .center, spacing: 14) {
            DigitsBadge(digits: prefix.digits, dimmed: status == .paused)

            VStack(alignment: .leading, spacing: 6) {
                let title = Text(prefix.regionName).font(.headline)
                let statusPill = StatusPill(text: pill.text, systemImage: pill.systemImage, color: pill.color)
                let segments = SwitchSegments(states: slots.map { status == .paused ? .unused : model.slotStates[$0] })
                    .frame(width: 96)
                let switches = Text("Switches \(SlotFormatter.ranges(slots))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                // Side by side when there is room; stacked for long names and large text.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        title.lineLimit(1)
                        Spacer(minLength: 0)
                        statusPill
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        title
                        statusPill
                    }
                }
                Text(prefix.pattern)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        segments
                        switches.lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        segments
                        switches
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Prefix \(prefix.digits), \(prefix.regionName)")
        .accessibilityValue("\(status.spokenDescription). Switches \(SlotFormatter.ranges(slots)).")
        .accessibilityAddTraits(.isButton)
    }
}

/// "Blocked prefixes" with how much room is left.
struct PrefixListHeader: View {
    @Environment(BlockerModel.self) private var model

    var body: some View {
        let used = model.config.prefixes.count
        HStack(alignment: .firstTextBaseline) {
            Text("Blocked prefixes")
                .font(.title3.bold())
            Spacer()
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    ForEach(0..<AppConstants.maxPrefixes, id: \.self) { index in
                        Circle()
                            .fill(index < used ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.systemFill)))
                            .frame(width: 6, height: 6)
                    }
                }
                Text("\(used) of \(AppConstants.maxPrefixes)")
                    .font(.footnote.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(used) of \(AppConstants.maxPrefixes) prefixes used")
        }
    }
}
