import SwiftUI

/// "Would this call be blocked?" for one phone number.
struct NumberCheckView: View {
    @Environment(BlockerModel.self) private var model
    @State private var text = NumberCheckView.initialText
    @FocusState private var fieldFocused: Bool

    private static var initialText: String {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "demoNumber") ?? ""
        #else
        return ""
        #endif
    }

    private struct Answer {
        var title: String
        var detail: String
        var systemImage: String
        var color: Color
    }

    var body: some View {
        let parsed = NumberCheck.parse(text)
        List {
            Section {
                HStack(spacing: 10) {
                    TextField("(844) 555-0123", text: $text)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .font(.title3.monospacedDigit())
                        .focused($fieldFocused)
                    if !text.isEmpty {
                        Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.tertiary)
                            .buttonStyle(.borderless)
                    }
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { text = first }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                }
            } header: {
                Text("Phone number")
            } footer: {
                Text("US and Canada numbers. Type it or paste it in any format.")
            }

            if let answer = answer(for: parsed) {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: answer.systemImage)
                            .font(.system(size: 30))
                            .foregroundStyle(answer.color)
                            .frame(width: 38)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(answer.title)
                                .font(.headline)
                            Text(answer.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)

                    action(for: parsed)
                }
            }

            Section {
                Label("A number saved in Contacts, or one you have called, rings even if its prefix is blocked.",
                      systemImage: "person.crop.circle.badge.checkmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Check a Number")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy, value: parsed)
        .onAppear { fieldFocused = text.isEmpty }
    }

    private func answer(for parsed: NumberCheck.Parsed) -> Answer? {
        switch parsed {
        case .incomplete:
            return nil
        case .invalid(let reason):
            return Answer(title: "Not a valid number", detail: reason,
                          systemImage: "questionmark.circle.fill", color: Color(.secondaryLabel))
        case .number(let number):
            let shown = NumberCheck.formatted(number)
            switch model.verdict(for: number) {
            case .blocked(let prefix):
                return Answer(title: "Blocked", detail: "\(shown) won't ring. It starts with \(prefix.digits), which you block.",
                              systemImage: "checkmark.shield.fill", color: Theme.green)
            case .notLoadedYet(let prefix):
                return Answer(title: "Not blocked yet",
                              detail: "\(shown) starts with \(prefix.digits), but iOS hasn't loaded that part of the prefix. Check the status on the main screen.",
                              systemImage: "exclamationmark.shield.fill", color: Theme.orange)
            case .paused(let prefix):
                return Answer(title: "Rings while \(prefix.digits) is paused",
                              detail: "\(shown) starts with \(prefix.digits), which is paused right now.",
                              systemImage: "pause.circle.fill", color: Theme.orange)
            case .allowed:
                let region = NumberCheck.areaCode(of: number).flatMap(AreaCodeDirectory.region(for:))
                return Answer(title: "Not blocked",
                              detail: "\(shown) will ring." + (region.map { " Area code from: \($0)." } ?? ""),
                              systemImage: "phone.arrow.down.left.fill", color: Color(.secondaryLabel))
            }
        }
    }

    @ViewBuilder
    private func action(for parsed: NumberCheck.Parsed) -> some View {
        if case .number(let number) = parsed {
            switch model.verdict(for: number) {
            case .paused(let prefix):
                Button("Resume Blocking \(prefix.digits)", systemImage: "play.fill") {
                    model.setPaused(prefix, false)
                    model.syncSoon()
                }
            case .allowed:
                if let prefix = NumberCheck.areaCode(of: number), SlotTable.canAdd(to: model.config.prefixes) {
                    Button("Block Prefix \(prefix.digits)", systemImage: "plus.circle.fill") {
                        if model.addPrefix(prefix) == nil { model.syncSoon() }
                    }
                }
            case .blocked, .notLoadedYet:
                EmptyView()
            }
        }
    }
}
