#if DEMO_MODE
// DemoMode — Development builds only. Conversation screen with sample messages.
// Sending, replies and reactions change only this in-memory demo data.

import DesignSystem
import SwiftUI

struct DemoModeChatView: View {
    @Binding var chat: DemoModeChat
    @State private var draft = ""
    @State private var replyTo: DemoModeMessage?
    @FocusState private var inputFocused: Bool

    private enum Row: Identifiable {
        case day(String)
        case message(DemoModeMessage, first: Bool, last: Bool)

        var id: String {
            switch self {
            case .day(let title): "day-\(title)"
            case .message(let message, _, _): message.id.uuidString
            }
        }
    }

    /// Messages of one author within 5 minutes form a group (shared avatar, tighter corners).
    private static func sameGroup(_ a: DemoModeMessage, _ b: DemoModeMessage) -> Bool {
        a.author == b.author && b.date.timeIntervalSince(a.date) < 300 && Calendar.current.isDate(a.date, inSameDayAs: b.date)
    }

    private var rows: [Row] {
        var result: [Row] = []
        let messages = chat.messages
        for (index, message) in messages.enumerated() {
            let previous = index > 0 ? messages[index - 1] : nil
            let next = index + 1 < messages.count ? messages[index + 1] : nil
            if previous.map({ !Calendar.current.isDate($0.date, inSameDayAs: message.date) }) ?? true {
                result.append(.day(DemoModeFormat.dayHeader(message.date)))
            }
            result.append(.message(message,
                                   first: previous.map { !Self.sameGroup($0, message) } ?? true,
                                   last: next.map { !Self.sameGroup(message, $0) } ?? true))
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { row in
                        switch row {
                        case .day(let title):
                            Text(title)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(.vertical, 8)
                        case .message(let message, let first, let last):
                            DemoModeMessageRow(
                                message: message, isGroupChat: chat.isGroup, first: first, last: last,
                                onReact: { toggleReaction($0, on: message.id) },
                                onReply: { replyTo = message; inputFocused = true })
                            .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .background(DemoModeWallpaper())
            .safeAreaInset(edge: .bottom) { inputBar }
            .onChange(of: chat.messages.count) {
                guard let id = chat.messages.last?.id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(chat.title).font(.headline).lineLimit(1)
                    Text(chat.subtitle)
                        .font(.caption)
                        .foregroundStyle(chat.isOnline ? Brand.accent : Color.secondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                DemoModeAvatar(name: chat.title, size: 34)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear { chat.unread = 0 }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            if let replyTo {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left.fill").foregroundStyle(Brand.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(replyTo.author ?? "Вы").font(.caption.weight(.semibold)).foregroundStyle(Brand.accent)
                        Text(replyTo.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { self.replyTo = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Отменить ответ")
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Сообщение", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground)))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Brand.accent)
                }
                .disabled(trimmedDraft.isEmpty)
                .opacity(trimmedDraft.isEmpty ? 0.4 : 1)
                .accessibilityLabel("Отправить")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        let reply = replyTo.map { DemoModeMessage.Reply(author: $0.author ?? "Вы", text: $0.text) }
        let message = DemoModeMessage(id: UUID(), author: nil, text: text, date: .now, status: .sending,
                                      reply: reply, reactions: [])
        chat.messages.append(message)
        draft = ""
        replyTo = nil
        // Demo only: simulated delivery ticks, no network.
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            setStatus(.sent, for: message.id)
        }
    }

    private func setStatus(_ status: DemoModeMessage.Status, for id: UUID) {
        guard let index = chat.messages.firstIndex(where: { $0.id == id }) else { return }
        chat.messages[index].status = status
    }

    private func toggleReaction(_ emoji: String, on id: UUID) {
        guard let index = chat.messages.firstIndex(where: { $0.id == id }) else { return }
        var message = chat.messages[index]
        if let r = message.reactions.firstIndex(where: { $0.emoji == emoji }) {
            if message.reactions[r].mine {
                message.reactions[r].count -= 1
                message.reactions[r].mine = false
                if message.reactions[r].count <= 0 { message.reactions.remove(at: r) }
            } else {
                message.reactions[r].count += 1
                message.reactions[r].mine = true
            }
        } else {
            message.reactions.append(.init(emoji: emoji, count: 1, mine: true))
        }
        withAnimation(.snappy) { chat.messages[index] = message }
    }
}

struct DemoModeMessageRow: View {
    let message: DemoModeMessage
    let isGroupChat: Bool
    let first: Bool
    let last: Bool
    let onReact: (String) -> Void
    let onReply: () -> Void

    private static let quickReactions = ["❤️", "👍", "😂", "😮", "🙏"]
    private let large: CGFloat = 18
    private let small: CGFloat = 6

    private var radii: RectangleCornerRadii {
        if message.isMine {
            return RectangleCornerRadii(topLeading: large, bottomLeading: large,
                                        bottomTrailing: last ? large : small, topTrailing: first ? large : small)
        }
        return RectangleCornerRadii(topLeading: first ? large : small, bottomLeading: last ? large : small,
                                    bottomTrailing: large, topTrailing: large)
    }

    private var timeColor: Color { message.isMine ? Color.white.opacity(0.8) : Color.secondary }

    /// Invisible copy of the time label at the end of the text, so the real label never overlaps it.
    private var timePlaceholder: String {
        "\u{00A0}\u{00A0}" + DemoModeFormat.time(message.date) + (message.isMine ? "\u{00A0}\u{00A0}\u{00A0}\u{00A0}" : "")
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.isMine { Spacer(minLength: 56) }
            if !message.isMine && isGroupChat {
                if last {
                    DemoModeAvatar(name: message.author ?? "", size: 32)
                } else {
                    Color.clear.frame(width: 32, height: 1)
                }
            }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 3) {
                bubble
                if !message.reactions.isEmpty { reactions }
            }
            if !message.isMine { Spacer(minLength: 56) }
        }
        .padding(.top, first ? 6 : 0)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isGroupChat && !message.isMine && first, let author = message.author {
                Text(author)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DemoModeAvatar.color(for: author))
            }
            if let reply = message.reply {
                DemoModeReplyPreview(reply: reply, onAccent: message.isMine)
            }
            Text("\(message.text)\(Text(timePlaceholder).font(.caption2).foregroundStyle(Color.clear))")
                .foregroundStyle(message.isMine ? Color.white : Color.primary)
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 3) {
                        Text(DemoModeFormat.time(message.date)).font(.caption2)
                        if message.isMine { DemoModeStatusIcon(status: message.status, color: timeColor) }
                    }
                    .foregroundStyle(timeColor)
                    .offset(y: 2)
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(message.isMine ? Brand.accent : Color(uiColor: .secondarySystemGroupedBackground),
                    in: UnevenRoundedRectangle(cornerRadii: radii, style: .continuous))
        .contentShape(.contextMenuPreview, UnevenRoundedRectangle(cornerRadii: radii, style: .continuous))
        .onTapGesture(count: 2) { onReact("❤️") }
        .contextMenu {
            Section {
                ForEach(Self.quickReactions, id: \.self) { emoji in
                    Button(emoji) { onReact(emoji) }
                }
            }
            Button { onReply() } label: { Label("Ответить", systemImage: "arrowshape.turn.up.left") }
            Button { UIPasteboard.general.string = message.text } label: { Label("Копировать", systemImage: "doc.on.doc") }
        }
    }

    private var reactions: some View {
        HStack(spacing: 4) {
            ForEach(message.reactions) { reaction in
                Button { onReact(reaction.emoji) } label: {
                    HStack(spacing: 3) {
                        Text(reaction.emoji)
                        Text("\(reaction.count)").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(reaction.mine ? Brand.accent.opacity(0.22) : Color(uiColor: .tertiarySystemFill)))
                    .overlay(Capsule().stroke(reaction.mine ? Brand.accent : Color.clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(reaction.emoji) \(reaction.count)")
            }
        }
    }
}

struct DemoModeReplyPreview: View {
    let reply: DemoModeMessage.Reply
    let onAccent: Bool

    var body: some View {
        let tint = onAccent ? Color.white : Brand.accent
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(reply.author).font(.caption.weight(.semibold)).foregroundStyle(tint)
                Text(reply.text)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(onAccent ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.15)))
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct DemoModeWallpaper: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            LinearGradient(colors: [Brand.accent.opacity(0.08), Color.clear, Brand.accent.opacity(0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
    }
}
#endif
