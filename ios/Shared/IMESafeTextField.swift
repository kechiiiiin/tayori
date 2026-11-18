import SwiftUI
import UIKit

/// Return で送る1行の入力欄。**IME の変換中（マークドテキストがある間）の Return は確定だけにして送らない**。
/// SwiftUI の TextField.onSubmit はハードウェアキーボード（iPad・Mac）の変換確定でも呼ばれることがあるので、
/// UITextField の markedTextRange を見て確かめる。
struct IMESafeTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var keyboard: UIKeyboardType = .default
    var returnKey: UIReturnKeyType = .done
    var autocapitalization: UITextAutocapitalizationType = .none
    var font: UIFont = .preferredFont(forTextStyle: .subheadline)
    var onSubmit: () -> Void = {}

    func makeUIView(context: Context) -> UITextField {
        let f = UITextField()
        f.delegate = context.coordinator
        f.placeholder = placeholder
        f.keyboardType = keyboard
        f.returnKeyType = returnKey
        f.autocapitalizationType = autocapitalization
        f.autocorrectionType = .no
        f.clearButtonMode = .whileEditing
        f.font = font
        f.adjustsFontForContentSizeCategory = true
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        f.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return f
    }

    func updateUIView(_ f: UITextField, context: Context) {
        context.coordinator.parent = self
        // 変換中に外から書き戻すと変換が切れるので、マークドテキストが無いときだけ合わせる
        if f.markedTextRange == nil, f.text != text { f.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: IMESafeTextField
        init(_ p: IMESafeTextField) { parent = p }

        @objc func changed(_ f: UITextField) {
            parent.text = f.text ?? ""
        }

        func textFieldShouldReturn(_ f: UITextField) -> Bool {
            // 変換中の Return は確定。送らない
            guard f.markedTextRange == nil else { return true }
            parent.text = f.text ?? ""
            parent.onSubmit()
            return false
        }
    }
}

/// 色（モックの値。ダークモードでは同じ役目の暗い色）
enum Theme {
    static let accent = Color(red: 0xC2 / 255, green: 0x55 / 255, blue: 0x2D / 255)
    static let accentSoft = dynamic(light: (0xF6, 0xE4, 0xDC), dark: (0x4A, 0x2A, 0x1E))
    static let memoInk = dynamic(light: (0x7A, 0x34, 0x18), dark: (0xF2, 0xC4, 0xB0))
    static let highlight = dynamic(light: (0xFF, 0xF7, 0xF3), dark: (0x33, 0x24, 0x1E))
    static let readGreen = Color(red: 0x3A / 255, green: 0x7D / 255, blue: 0x5C / 255)
    static let chip = Color(uiColor: .secondarySystemFill)
    static let error = dynamic(light: (0xB3, 0x26, 0x1E), dark: (0xFF, 0x7B, 0x72))

    private static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        func ui(_ c: (Int, Int, Int)) -> UIColor {
            UIColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        }
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
}

/// カテゴリを選ぶ丸いチップの並び（サイト画面と共有拡張で使う）
struct CategoryPicker: View {
    let categories: [Category]
    @Binding var selection: Int?
    var onNew: (() -> Void)?

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(categories) { c in chip(c.name, selected: selection == c.id) { selection = c.id } }
            chip("未分類", selected: selection == nil) { selection = nil }
            if let onNew { chip("＋ 新しく", selected: false, action: onNew) }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? Color(uiColor: .systemBackground) : Color.primary)
                .background(selected ? Color.primary : Color(uiColor: .systemBackground), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.primary : Color(uiColor: .separator), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// 折り返して並べる（チップ用）
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let h = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let w = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + s.width > width {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width += (r.indices.isEmpty ? 0 : spacing) + s.width
            r.height = max(r.height, s.height)
            r.indices.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}
