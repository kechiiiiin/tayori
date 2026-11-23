import SwiftUI

/// ① 一覧: 上にタブ（未読／コメントあり／すべて）とカテゴリの並び、行は新しい順。
/// 行をタップ → アプリ内 Safari。戻ると下に「コメント」「既読にする」のバー（③）。
/// 左右にスワイプで隣のカテゴリへ。長押しで既読／未読に戻す・コメント
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

    /// feedId → アイコンの URL（アートワーク優先・毎行 O(n) 探索しないよう先に辞書化）
    private var favicons: [Int: URL] {
        model.feeds.reduce(into: [:]) { dict, f in dict[f.id] = f.iconURL }
    }

    @ViewBuilder
    private var list: some View {
        let favicons = self.favicons
        List {
            ForEach(model.items) { item in
                ItemRow(item: item, state: model.state, opened: model.lastOpened?.id == item.id, favicon: favicons[item.feedId])
                    .contentShape(Rectangle())
                    .onTapGesture { model.open(item) }
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(model.lastOpened?.id == item.id ? Theme.highlight : Color(uiColor: .systemBackground))
                    .contextMenu {
                        Button { startComment(item) } label: {
                            Label(item.comment == nil ? "コメント" : "コメントを直す", systemImage: "text.bubble")
                        }
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
        // 一覧を左右にスワイプ → 隣のカテゴリへ（左へで右隣・右へで左隣・端で止まる）。
        // 縦のスクロールを邪魔しないよう、横の動きが縦の倍以上・60pt 以上のときだけ
        .simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .local)
                .onEnded { v in
                    guard showCategoryBar, model.feedFilter == nil else { return }
                    let dx = v.translation.width, dy = v.translation.height
                    guard abs(dx) >= 60, abs(dx) > abs(dy) * 2 else { return }
                    model.shiftCategory(by: dx < 0 ? 1 : -1)
                }
        )
    }

    /// 一覧からコメントを書く。戻りのバー（lastOpened）は触らない
    private func startComment(_ item: Item) {
        model.commentDraft = nil
        model.commentTarget = item
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
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 0) {
                    tab("すべて", model.count(model.categories.total), .all)
                    ForEach(model.categories.categories) { c in
                        tab(c.name, model.count(c.counts), .category(c.id))
                    }
                    tab("未分類", model.count(model.categories.uncategorized), .none)
                }
                .padding(.horizontal, 6)
            }
            // スワイプで切り替えたとき、選んだタブが見えるところまで寄せる
            .onChange(of: model.category) { _, f in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(f, anchor: .center) }
            }
        }
    }

    /// 押せる範囲は文字より広く（左右 10pt・上 12pt・高さ 44pt 以上）。見た目の間隔は前と同じ 20pt ほど
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
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .frame(minHeight: 44, alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .id(f)
    }
}

/// 1行: ● 題名（未読は太字）／サイト · 時刻／コメント
struct ItemRow: View {
    let item: Item
    let state: ItemState
    let opened: Bool
    /// サイトのファビコン（model.feeds から feedId で引いたもの。取れないサイトは nil）
    let favicon: URL?

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
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    FaviconView(url: favicon, fallback: item.feedTitle.first.map(String.init) ?? "・", size: 14)
                        .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
                    Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let c = item.comment {
                    Label {
                        Text(c)
                    } icon: {
                        Image(systemName: "text.bubble")
                    }
                    .labelStyle(CommentLabelStyle())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 1)
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

/// コメント行: 吹き出しアイコン＋灰色の文字（2行まで）。アイコンは1行目の上端に揃える
private struct CommentLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title.multilineTextAlignment(.leading)
        }
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
