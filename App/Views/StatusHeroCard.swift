import SwiftUI

/// The one thing the user should know right now, and what to do about it.
struct StatusHeroCard: View {
    @Environment(BlockerModel.self) private var model
    let onAdd: () -> Void

    private struct Look {
        var kind: HeroKind
        var symbol: String
        var title: String
        var subtitle: String?
    }

    /// The colour family of the card, also used for the glow behind the screen.
    static func kind(for model: BlockerModel) -> HeroKind {
        if model.storageError != nil { return .failed }
        switch model.overallStatus {
        case .empty, .paused, .pending: return .neutral
        case .needsSwitches: return .attention
        case .loading: return .working
        case .protected: return .protected
        case .failed: return .failed
        }
    }

    private var look: Look {
        let kind = Self.kind(for: model)
        if let error = model.storageError {
            return Look(kind: kind, symbol: "exclamationmark.triangle.fill", title: "Can't save settings", subtitle: error)
        }
        switch model.overallStatus {
        case .empty:
            return Look(kind: kind, symbol: "shield.slash.fill", title: "Nothing blocked yet",
                        subtitle: "Add a 3-digit prefix, like 844 or 877, to silence every call that starts with it.")
        case .paused:
            return Look(kind: kind, symbol: "pause.circle.fill", title: "Blocking is paused",
                        subtitle: "Every prefix is paused, so all calls ring.")
        case .needsSwitches(let slots):
            return Look(kind: kind, symbol: "switch.2",
                        title: slots.count == 1 ? "Turn on 1 switch" : "Turn on \(slots.count) switches",
                        subtitle: "iOS only blocks once the switches are on.")
        case .loading(let done, let total):
            return Look(kind: kind, symbol: "arrow.triangle.2.circlepath", title: "Loading numbers",
                        subtitle: total > 0 ? "\(done) of \(total) switches loaded. Keep the app open." : "Keep the app open.")
        case .protected:
            return Look(kind: kind, symbol: "checkmark.shield.fill", title: "Protection active",
                        subtitle: "Calls from \(prefixList) never ring.")
        case .failed:
            return Look(kind: kind, symbol: "exclamationmark.shield.fill", title: "Couldn't load everything", subtitle: nil)
        case .pending:
            return Look(kind: kind, symbol: "hourglass", title: "Getting ready", subtitle: nil)
        }
    }

    var body: some View {
        let look = look
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: look.symbol)
                    .font(.system(size: 27, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: look.kind == .working)
                    .frame(width: 58, height: 58)
                    .background(.white.opacity(0.18), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(look.title)
                        .font(.title2.bold())
                    if let subtitle = look.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .opacity(0.9)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if model.storageError == nil {
                details
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(look.kind.gradient)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .animation(.smooth, value: model.overallStatus)
    }

    @ViewBuilder
    private var details: some View {
        switch model.overallStatus {
        case .empty:
            Button("Add a Prefix", systemImage: "plus", action: onAdd)
                .buttonStyle(HeroButtonStyle(tint: HeroKind.neutral.tint))

        case .paused:
            Button("Resume All", systemImage: "play.fill") {
                for prefix in model.config.prefixes { model.setPaused(prefix, false) }
                model.syncSoon()
            }
            .buttonStyle(HeroButtonStyle(tint: HeroKind.neutral.tint))

        case .needsSwitches(let slots):
            VStack(alignment: .leading, spacing: 10) {
                HeroStep(number: 1) { Text("Open **\(SettingsPath.text)**") }
                HeroStep(number: 2) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Turn on these switches:")
                        ForEach(switchGroups(slots), id: \.label) { group in
                            Text("**Prefix Blocker \(group.ranges)**\(group.label.isEmpty ? "" : "  for \(group.label)")")
                        }
                    }
                }
                HeroStep(number: 3) { Text("Come back here. The numbers load by themselves.") }
            }
            .font(.subheadline)
            Button("Open Settings", systemImage: "gear") {
                Task { await LiveCallDirectoryService.openSettings() }
            }
            .buttonStyle(HeroButtonStyle(tint: HeroKind.attention.tint))
            if model.loadedNumberCount > 0 {
                HeroChip(text: "\(model.loadedNumberCount.formatted()) of \(model.totalNumberCount.formatted()) numbers blocked so far",
                         systemImage: "checkmark.shield")
            }

        case .loading(let done, let total):
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .tint(.white)
            } else {
                ProgressView()
                    .tint(.white)
            }

        case .protected:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { chips }
                VStack(alignment: .leading, spacing: 8) { chips }
            }

        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(failureGroups, id: \.message) { group in
                    Text("**Prefix Blocker \(group.ranges)**: \(group.message)")
                }
            }
            .font(.subheadline)
            Button("Try Again", systemImage: "arrow.clockwise") {
                model.syncSoon()
            }
            .buttonStyle(HeroButtonStyle(tint: HeroKind.failed.tint))

        case .pending:
            ProgressView()
                .tint(.white)
        }
    }

    @ViewBuilder
    private var chips: some View {
        HeroChip(text: "\(model.totalNumberCount.formatted()) numbers", systemImage: "phone.down.fill")
        let pausedCount = model.config.paused.count
        if pausedCount > 0 {
            HeroChip(text: "\(pausedCount) paused", systemImage: "pause.fill")
        } else {
            let count = model.config.prefixes.count
            HeroChip(text: count == 1 ? "1 prefix" : "\(count) prefixes", systemImage: "number")
        }
    }

    private var prefixList: String {
        model.activePrefixes.map(\.digits).formatted(.list(type: .and))
    }

    /// Switches to turn on, grouped by the prefix they belong to.
    private func switchGroups(_ slots: [Int]) -> [(label: String, ranges: String)] {
        var remaining = Set(slots)
        var groups: [(label: String, ranges: String)] = []
        for prefix in model.config.prefixes {
            let own = model.slots(of: prefix).filter(remaining.contains)
            guard !own.isEmpty else { continue }
            remaining.subtract(own)
            groups.append((prefix.digits, SlotFormatter.ranges(own)))
        }
        if !remaining.isEmpty {
            groups.append(("", SlotFormatter.ranges(Array(remaining))))
        }
        return groups
    }

    /// Failed switches, grouped by what went wrong.
    private var failureGroups: [(message: String, ranges: String)] {
        var order: [String] = []
        var slots: [String: [Int]] = [:]
        for failure in model.failures {
            if slots[failure.message] == nil { order.append(failure.message) }
            slots[failure.message, default: []].append(failure.slot)
        }
        return order.map { ($0, SlotFormatter.ranges(slots[$0] ?? [])) }
    }
}

private struct HeroStep<Content: View>: View {
    let number: Int
    @ViewBuilder let content: Content
    /// Grows with the text size, so the number always fits its circle.
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 22

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.footnote.weight(.bold).monospacedDigit())
                .frame(width: size, height: size)
                .background(.white.opacity(0.22), in: Circle())
            content
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HeroChip: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.white.opacity(0.17), in: Capsule())
    }
}

/// White capsule button for use on the coloured card.
private struct HeroButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(.white.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
    }
}
