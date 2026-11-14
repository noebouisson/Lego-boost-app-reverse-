import BlockEngine
import SwiftUI

/// Paramètre d'un bloc : pastille éditable ou bloc emboîté.
struct InputView: View {
    let block: Block
    let key: String
    let isTemplate: Bool

    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        let spec = BlockCatalog.spec(for: block.opcode).input(key)
        let value = block.inputs[key]
        let slot = SlotRef(parent: block.id, key: key)

        switch (spec?.kind, value) {
        case (.number?, .reporter(let child)?), (.boolean?, .reporter(let child)?):
            BlockView(block: child, isTemplate: isTemplate)
                .reportFrame(enabled: !isTemplate) { layout, frame in layout.slots[slot] = frame }

        case (.number(let defaultValue, let minimum, let maximum)?, _):
            NumberChip(value: numberValue(value) ?? defaultValue, minimum: minimum, maximum: maximum,
                       isTemplate: isTemplate) { newValue in
                editor.setInput(block.id, key, .number(newValue))
            }
            .reportFrame(enabled: !isTemplate) { layout, frame in layout.slots[slot] = frame }

        case (.boolean?, _):
            PointedShape()
                .fill(Color.black.opacity(0.3))
                .frame(width: 46, height: 28)
                .reportFrame(enabled: !isTemplate) { layout, frame in layout.slots[slot] = frame }

        case (.option(let options, let defaultID)?, _):
            OptionChip(options: options, selectedID: block.option(key) ?? defaultID, isTemplate: isTemplate) { id in
                editor.setInput(block.id, key, .option(id))
            }

        case (.variable?, _):
            VariableChip(name: block.variableName(key) ?? "?", variables: editor.project.variables,
                         isTemplate: isTemplate) { name in
                editor.setInput(block.id, key, .variable(name))
            } onNew: {
                editor.variablePrompt = EditorViewModel.VariablePrompt(blockID: block.id, key: key)
            }

        default:
            EmptyView()
        }
    }

    private func numberValue(_ value: Value?) -> Double? {
        if case .number(let number)? = value { return number }
        return nil
    }
}

/// Fond commun des pastilles de paramètre.
private struct ChipStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.85))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(minWidth: 36, minHeight: 30)
            .background(Capsule().fill(Color.white.opacity(0.95)))
    }
}

/// Nombre éditable au tap, avec un pavé numérique.
struct NumberChip: View {
    let value: Double
    let minimum: Double?
    let maximum: Double?
    let isTemplate: Bool
    let onChange: (Double) -> Void

    @State private var isEditing = false

    var body: some View {
        Text(Theme.format(value))
            .modifier(ChipStyle())
            .contentShape(Capsule())
            .onTapGesture {
                if !isTemplate { isEditing = true }
            }
            .popover(isPresented: $isEditing) {
                NumberPad(initial: value, minimum: minimum, maximum: maximum) { newValue in
                    onChange(newValue)
                    isEditing = false
                }
            }
    }
}

/// Pavé numérique affiché dans une bulle.
struct NumberPad: View {
    let initial: Double
    let minimum: Double?
    let maximum: Double?
    let onCommit: (Double) -> Void

    @State private var text = ""

    private let rows = [["7", "8", "9"], ["4", "5", "6"], ["1", "2", "3"], ["±", "0", ","]]

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(text.isEmpty ? Theme.format(initial) : text)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Button {
                    if !text.isEmpty { text.removeLast() }
                } label: {
                    Image(systemName: "delete.left.fill").font(.title2)
                }
                .disabled(text.isEmpty)
            }
            .padding(.horizontal, 6)

            if let minimum, let maximum {
                Text("de \(Theme.format(minimum)) à \(Theme.format(maximum))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(rows, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { key in
                        Button {
                            press(key)
                        } label: {
                            Text(key)
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                                .frame(width: 64, height: 52)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.25)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                onCommit(result)
            } label: {
                Text("OK")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 244)
    }

    private func press(_ key: String) {
        switch key {
        case "±":
            if text.hasPrefix("-") {
                text.removeFirst()
            } else {
                text = "-" + text
            }
        case ",":
            if !text.contains(",") {
                text += (text.isEmpty || text == "-") ? "0," : ","
            }
        default:
            if text.count < 9 { text += key }
        }
    }

    /// Valeur saisie, bornée ; la valeur d'origine si rien n'a été saisi.
    private var result: Double {
        var value = Double(text.replacingOccurrences(of: ",", with: ".")) ?? initial
        if let minimum { value = max(minimum, value) }
        if let maximum { value = min(maximum, value) }
        return value
    }
}

/// Choix dans une liste, présenté en menu.
struct OptionChip: View {
    let options: [BlockOption]
    let selectedID: String
    let isTemplate: Bool
    let onSelect: (String) -> Void

    var body: some View {
        if isTemplate {
            chip
        } else {
            Menu {
                ForEach(options, id: \.id) { option in
                    Button {
                        onSelect(option.id)
                    } label: {
                        if option.id == selectedID {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                chip
            }
        }
    }

    private var chip: some View {
        HStack(spacing: 5) {
            if isColorList, let swatch = Theme.swatch(for: selectedID) {
                Circle()
                    .fill(swatch)
                    .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                    .frame(width: 16, height: 16)
            }
            Text(options.first { $0.id == selectedID }?.label ?? selectedID)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
        }
        .modifier(ChipStyle())
    }

    /// Vrai si tous les choix sont des couleurs.
    private var isColorList: Bool {
        options.allSatisfy { Theme.swatch(for: $0.id) != nil }
    }
}

/// Choix d'une variable du projet.
struct VariableChip: View {
    let name: String
    let variables: [String]
    let isTemplate: Bool
    let onSelect: (String) -> Void
    let onNew: () -> Void

    var body: some View {
        if isTemplate {
            chip
        } else {
            Menu {
                ForEach(variables, id: \.self) { variable in
                    Button(variable) { onSelect(variable) }
                }
                Divider()
                Button {
                    onNew()
                } label: {
                    Label("Nouvelle variable…", systemImage: "plus")
                }
            } label: {
                chip
            }
        }
    }

    private var chip: some View {
        HStack(spacing: 5) {
            Text(name)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
        }
        .modifier(ChipStyle())
    }
}
