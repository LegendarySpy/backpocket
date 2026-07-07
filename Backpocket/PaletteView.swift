import SwiftUI

struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    @ObservedObject private var settings = AppSettings.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if model.growsUp {
                rowPills
                inputPill
            } else {
                inputPill
                rowPills
            }
        }
        .padding(34)
        .frame(
            maxWidth: .infinity, maxHeight: .infinity,
            alignment: model.growsUp ? .bottomLeading : .topLeading
        )
        .animation(.smooth(duration: 0.18), value: model.results)
        .animation(.smooth(duration: 0.15), value: model.selection)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
    }

    @ViewBuilder
    private var rowPills: some View {
        let rows = Array(model.results.enumerated())
        ForEach(model.growsUp ? rows.reversed() : rows, id: \.element.id) { _, result in
            let isSelected = result.id == model.selectedResult?.id
            RowPill(
                result: result,
                preview: preview(for: result, isSelected: isSelected),
                isSelected: isSelected
            )
                .onTapGesture { model.commit(result.fact) }
                .geometryGroup()
                .transition(.blurReplace)
        }
    }

    private func preview(for result: FuzzyResult, isSelected: Bool) -> String? {
        switch settings.palettePreview {
        case .always: model.preview(for: result.fact)
        case .selected: isSelected ? model.preview(for: result.fact) : nil
        case .never: nil
        }
    }

    private var inputPill: some View {
        HStack(spacing: 6) {
            TextField("Search", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .focused($focused)
                .onKeyPress(.return) { model.commit(); return .handled }
                .onKeyPress(.upArrow) { model.adjustSelection(by: model.growsUp ? 1 : -1); return .handled }
                .onKeyPress(.downArrow) { model.adjustSelection(by: model.growsUp ? -1 : 1); return .handled }
                .onKeyPress(.escape) { model.onDismiss?(); return .handled }
                .onKeyPress(.tab) { model.commit(); return .handled }

            if let hint = trailingHint {
                Text(hint)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .transition(.blurReplace)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 230, height: 29)
        .glassEffect(.regular, in: .capsule)
        .animation(.smooth(duration: 0.15), value: trailingHint)
    }

    private var trailingHint: String? {
        if model.results.isEmpty, !model.query.isEmpty { return "insert ↩" }
        if let tag = model.activeTag, model.selected != nil { return "+\(tag)" }
        return nil
    }
}

private struct RowPill: View {
    let result: FuzzyResult
    let preview: String?
    let isSelected: Bool
    @State private var hovering = false

    private var glass: Glass {
        if isSelected { return .regular.tint(.accentColor.opacity(0.45)) }
        if hovering { return .regular.tint(.primary.opacity(0.12)) }
        return .regular
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(highlightedName)
                .lineLimit(1)
                .layoutPriority(1)
            if let preview {
                Text(preview)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if result.fact.isSensitive {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .frame(maxWidth: 230, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .glassEffect(glass, in: .capsule)
        .contentShape(.capsule)
        .onHover { hovering = $0 }
    }

    private var highlightedName: AttributedString {
        var text = AttributedString()
        for (index, character) in result.fact.name.enumerated() {
            var piece = AttributedString(String(character))
            if result.matchedIndices.contains(index) {
                piece.font = .system(size: 11.5, weight: .bold)
                piece.foregroundColor = .primary
            } else {
                piece.font = .system(size: 11.5)
                piece.foregroundColor = .secondary
            }
            text += piece
        }
        return text
    }
}
