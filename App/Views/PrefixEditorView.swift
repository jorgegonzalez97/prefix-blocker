import SwiftUI

/// What the prefix sheet is for.
enum PrefixEditor: Identifiable, Hashable {
    case add
    case edit(AreaCode)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let prefix): return "edit-\(prefix.digits)"
        }
    }
}

/// Adds a prefix, or changes an existing one to different digits.
struct PrefixEditorView: View {
    @Environment(BlockerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let mode: PrefixEditor
    /// Called with the new digits after an existing prefix was changed.
    var onChanged: (AreaCode) -> Void = { _ in }

    @State private var text: String
    @State private var failure: String?
    @FocusState private var fieldFocused: Bool

    init(mode: PrefixEditor, onChanged: @escaping (AreaCode) -> Void = { _ in }) {
        self.mode = mode
        self.onChanged = onChanged
        _text = State(initialValue: Self.original(of: mode)?.digits ?? "")
    }

    private static func original(of mode: PrefixEditor) -> AreaCode? {
        if case .edit(let prefix) = mode { return prefix }
        return nil
    }

    private var original: AreaCode? { Self.original(of: mode) }
    private var prefix: AreaCode? { AreaCode(text) }

    /// What's wrong with the three digits typed so far, if anything.
    private var problem: String? {
        if let failure { return failure }
        guard text.count == 3 else { return nil }
        guard let prefix else { return AreaCode.validationError(for: text) }
        if prefix != original, model.config.prefixes.contains(prefix) {
            return "\(prefix.digits) is already in your list."
        }
        return nil
    }

    private var canConfirm: Bool {
        prefix != nil && problem == nil && prefix != original
    }

    private var suggestions: [AreaCode] {
        AreaCode.tollFree.filter { !model.config.prefixes.contains($0) }
    }

    /// Toll-free prefixes can be added in one go while they all still fit.
    private var canAddAllTollFree: Bool {
        original == nil && suggestions.count > 1 && suggestions.count <= SlotTable.room(after: model.config.prefixes)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    digitField
                    feedback
                    Button(action: confirm) {
                        Text(confirmTitle)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(!canConfirm)

                    if !suggestions.isEmpty {
                        suggestionCard
                    }
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(original == nil ? "Block a Prefix" : "Change \(original?.digits ?? "")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { fieldFocused = true }
        }
    }

    // MARK: Pieces

    private var digitField: some View {
        HStack(spacing: 12) {
            Text("+1")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            ForEach(0..<3, id: \.self) { index in
                DigitBox(character: character(at: index),
                         isCurrent: fieldFocused && index == min(text.count, 2),
                         isInvalid: problem != nil)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .contentShape(Rectangle())
        .onTapGesture { fieldFocused = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Prefix, three digits")
        .accessibilityValue(text.isEmpty ? "empty" : text.map(String.init).joined(separator: " "))
        .accessibilityAddTraits(.isButton)
        .background {
            // The boxes only display; this field owns the keyboard.
            TextField("", text: $text)
                .keyboardType(.numberPad)
                .focused($fieldFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)
                .onChange(of: text) { _, new in
                    let digits = String(new.filter { $0.isASCII && $0.isNumber }.prefix(3))
                    if digits != new { text = digits }
                    failure = nil
                }
        }
    }

    @ViewBuilder
    private var feedback: some View {
        Group {
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(Theme.red)
            } else if let prefix {
                VStack(spacing: 4) {
                    Label(prefix.regionName, systemImage: prefix.isTollFree ? "phone.fill" : "mappin.and.ellipse")
                        .font(.headline)
                    Text("\(prefix.pattern) · \(AreaCode.numbersPerAreaCode.formatted()) numbers")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("The three digits after +1, as in (844) 555-0123.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 44)
        .animation(.snappy, value: text)
    }

    private var suggestionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Toll-free prefixes")
                .font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                ForEach(suggestions) { suggestion in
                    Button(suggestion.digits) {
                        text = suggestion.digits
                    }
                    .buttonStyle(ChipButtonStyle(selected: text == suggestion.digits))
                }
            }
            if canAddAllTollFree {
                Divider()
                Button("Block All \(suggestions.count) Toll-Free Prefixes", systemImage: "shield.lefthalf.filled") {
                    addAllTollFree()
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var confirmTitle: String {
        guard let prefix, problem == nil, prefix != original else { return original == nil ? "Block" : "Change" }
        return original == nil ? "Block \(prefix.digits)" : "Change to \(prefix.digits)"
    }

    private var note: String {
        if let original {
            return "The new prefix takes over the \(AppConstants.shardsPerPrefix) switches \(original.digits) is using, so there is nothing to turn on in Settings. \(original.digits) stops being blocked."
        }
        return "Each prefix uses \(AppConstants.shardsPerPrefix) switches, which you turn on once in Settings. The app tells you which ones."
    }

    private func character(at index: Int) -> Character? {
        index < text.count ? text[text.index(text.startIndex, offsetBy: index)] : nil
    }

    // MARK: Actions

    private func confirm() {
        guard let prefix else { return }
        let message: String?
        if let original {
            message = model.replacePrefix(original, with: prefix)
        } else {
            message = model.addPrefix(prefix)
        }
        if let message {
            failure = message
            return
        }
        if original != nil { onChanged(prefix) }
        model.syncSoon()
        dismiss()
    }

    private func addAllTollFree() {
        if let message = model.addPrefixes(suggestions) {
            failure = message
            return
        }
        model.syncSoon()
        dismiss()
    }
}

private struct DigitBox: View {
    let character: Character?
    let isCurrent: Bool
    let isInvalid: Bool

    var body: some View {
        let outline: Color = isInvalid ? Theme.red : (isCurrent ? Color.accentColor : Color(.separator))
        Text(character.map(String.init) ?? "•")
            .font(.system(size: 44, weight: .heavy, design: .rounded).monospacedDigit())
            .foregroundStyle(character == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.primary))
            .frame(width: 68, height: 84)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(outline, lineWidth: isCurrent || isInvalid ? 2 : 1)
            }
            .animation(.snappy(duration: 0.15), value: isCurrent)
    }
}

private struct ChipButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.monospacedDigit().weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.tertiarySystemFill)),
                        in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
