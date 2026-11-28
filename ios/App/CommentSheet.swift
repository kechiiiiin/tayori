import SwiftUI

/// ④ コメント（自分だけのメモ）。「保存」と「保存して既読に」。
/// 複数行の欄なので Return は改行（送信に使わない）。IME の確定で送ってしまうことはない
struct CommentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: Item
    @State private var text: String
    @State private var saving = false
    @FocusState private var focused: Bool

    init(item: Item, initial: String) {
        self.item = item
        _text = State(initialValue: initial)
    }

    private var sendsToRururu: Bool {
        model.feeds.first { $0.id == item.feedId }?.sendsToRururu ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("コメント").font(.headline).padding(.bottom, 4)
            Text("\(item.title) · \(item.feedTitle)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.bottom, 10)
            TextEditor(text: $text)
                .font(.subheadline)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 110, maxHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(uiColor: .separator), lineWidth: 1))
            Text(sendsToRururu
                 ? "このサイトは rururu に送る設定です。既読にした記事は、送るときにこのコメントを paw のメモに載せます（rururu では公開）。"
                 : "自分だけのメモです。rururu には送りません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .padding(.bottom, 12)
            HStack(spacing: 8) {
                Button { save(andRead: false) } label: {
                    Text("保存")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.primary)
                        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12))
                }
                Button { save(andRead: true) } label: {
                    Text(item.isRead ? "保存（既読のまま）" : "保存して既読に")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .buttonStyle(.plain)
            .disabled(saving)
            if let e = model.errorMessage, !saving {
                Text(e).font(.caption).foregroundStyle(Theme.error).padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private func save(andRead: Bool) {
        saving = true
        Task {
            let ok = await model.saveComment(item, text: text, andRead: andRead && !item.isRead)
            saving = false
            if ok {
                model.commentDraft = nil
                dismiss()
            }
        }
    }
}
