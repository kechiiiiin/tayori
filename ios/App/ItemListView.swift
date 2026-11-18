import SwiftUI

/// ① 一覧: 上にタブ（未読／コメントあり／すべて）とカテゴリの並び、行は新しい順。
/// 行をタップ → アプリ内 Safari。戻ると下に「既読にする」「コメント」のバー（③）。左へスワイプで既読
struct ItemListView: View {
    @Environment(AppModel.self) private var model
    /// iPhone はカテゴリの並びを上に出す（iPad はサイドバーにある）
    let showCategoryBar: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let item = model.lastOpened {
                ReturnBar(item: item)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.lastOpened?.id)
    }

    // MARK: - 上: タブとカテゴリ

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(ItemState.allCases) { s in
                    let on = model.state == s
                    Button { model.select(state: s) } label: {
                        Text(s.label)
                            .font(.footnote)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .foregroundStyle(on ? Color(uiColor: .systemBackground) : Color.primary)
                            .background(on ? Color.primary : Theme.chip, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)

            if showCategoryBar && model.feedFilter == nil {
                CategoryBar()
            }
            if let f = model.feedFilter {
                HStack(spacing: 6) {
                    Text("サイト: \(f.title)").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    Button { model.select(feed: nil) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("サイトの絞り込みを外す")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
            Divider()
        }
        .padding(.top, 2)
    }

    // MARK: - 行

    private var list: some View {
        List {
            ForEach(model.items) { item in
                ItemRow(item: item, state: model.state, opened: model.lastOpened?.id == item.id)
                    .contentShape(Rectangle())
                    .onTapGesture { model.open(item) }
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(model.lastOpened?.id == item.id ? Theme.highlight : Color(uiColor: .systemBackground))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if item.isRead {
                            Button { Task { await model.setRead(item, false) } } label: { Text("未読に戻す") }
                                .tint(.gray)
                        } else {
                            Button { Task { await model.setRead(item, true) } } label: { Text("既読") }
                                .tint(Theme.readGreen)
                        }
                    }
                    .contextMenu {
                        Button { model.commentTarget = item } label: { Label("コメント", systemImage: "square.and.pencil") }
                        if item.isRead {
                            Button { Task { await model.setRead(item, false) } } label: { Label("未読に戻す", systemImage: "circle") }
                        } else {
                            Button { Task { await model.setRead(item, true) } } label: { Label("既読にする", systemImage: "checkmark.circle") }
                        }
                        if let u = item.link {
                            ShareLink(item: u) { Label("共有", systemImage: "square.and.arrow.up") }
                        }
                    }
                    .onAppear {
                        if item.id == model.items.last?.id { Task { await model.loadMore() } }
                    }
            }
            if model.items.isEmpty && !model.isLoading {
                empty.listRowSeparator(.hidden)
            }
            if let e = model.errorMessage {
                Text(e).font(.footnote).foregroundStyle(Theme.error).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .refreshable { await model.reload() }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text(model.state == .unread ? "未読はありません" : model.state == .commented ? "コメントのある記事はありません" : "記事はありません")
                .font(.subheadline).foregroundStyle(.secondary)
            if model.feeds.isEmpty {
                Text("右上の ≡ からサイトを足せます").font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// カテゴリの並び（横にスクロール・選んだものに下線・数字はいまのタブの数）
struct CategoryBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                tab("すべて", model.count(model.categories.total), .all)
                ForEach(model.categories.categories) { c in
                    tab(c.name, model.count(c.counts), .category(c.id))
                }
                tab("未分類", model.count(model.categories.uncategorized), .none)
            }
            .padding(.horizontal, 16)
        }
    }

    private func tab(_ name: String, _ n: Int, _ f: CategoryFilter) -> some View {
        let on = model.category == f
        return Button { model.select(category: f) } label: {
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(name).font(.footnote.weight(on ? .bold : .regular))
                    if n > 0 { Text("\(n)").font(.caption2) }
                }
                .foregroundStyle(on ? Theme.accent : Color.secondary)
                Rectangle().fill(on ? Theme.accent : .clear).frame(height: 2)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 1行: ● 題名（未読は太字）／サイト · 時刻／コメント
struct ItemRow: View {
    let item: Item
    let state: ItemState
    let opened: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(item.isRead ? Color.clear : Theme.accent)
                .overlay(Circle().strokeBorder(item.isRead ? Color(uiColor: .systemGray3) : .clear, lineWidth: 1))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(item.isRead ? .regular : .semibold))
                    .foregroundStyle(item.isRead ? Color.secondary : Color.primary)
                    .lineSpacing(2)
                Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let c = item.comment {
                    Text(c)
                        .font(.caption)
                        .foregroundStyle(Theme.memoInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 6))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        var parts = [item.feedTitle]
        if state == .commented {
            parts.append(item.isRead ? "\(When.readLabel(item.readAt)) 既読" : "未読")
        } else {
            parts.append(When.relative(item.publishedAt ?? item.sortAt))
        }
        if opened { parts.append("さっき開いた") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// ③ 戻ってきたら出るバー（さっき開いた記事に対して）
struct ReturnBar: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("さっき開いた: \(item.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Button { model.lastOpened = nil } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("バーを閉じる")
            }
            HStack(spacing: 8) {
                Button {
                    Task { await model.setRead(item, true) }
                } label: {
                    Text(item.isRead ? "既読です" : "既読にする")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(Theme.accent.opacity(item.isRead ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(item.isRead)
                Button {
                    model.commentDraft = nil
                    model.commentTarget = item
                } label: {
                    Text("コメント")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.primary)
                        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
