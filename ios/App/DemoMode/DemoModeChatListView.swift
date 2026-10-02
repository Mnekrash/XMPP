#if DEMO_MODE
// DemoMode — Development builds only. Chat list with sample chats.

import DesignSystem
import SwiftUI

struct DemoModeChatListView: View {
    @Bindable var session: DemoModeSession
    @State private var search = ""

    private var visibleChats: [DemoModeChat] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return session.chats
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                return (a.last?.date ?? .distantPast) > (b.last?.date ?? .distantPast)
            }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(visibleChats) { chat in
                    NavigationLink(value: chat.id) {
                        DemoModeChatRow(chat: chat)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { update(chat.id) { $0.pinned.toggle() } } label: {
                            Label(chat.pinned ? "Открепить" : "Закрепить", systemImage: chat.pinned ? "pin.slash.fill" : "pin.fill")
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { update(chat.id) { $0.muted.toggle() } } label: {
                            Label(chat.muted ? "Вкл. звук" : "Без звука",
                                  systemImage: chat.muted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        }
                        .tint(.indigo)
                        Button { update(chat.id) { $0.unread = $0.unread > 0 ? 0 : 1 } } label: {
                            Label(chat.unread > 0 ? "Прочитано" : "Не прочитано",
                                  systemImage: chat.unread > 0 ? "envelope.open.fill" : "envelope.badge.fill")
                        }
                        .tint(Brand.accent)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Чаты")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { DemoModeBadge() }
            }
            .searchable(text: $search, prompt: "Поиск")
            .overlay {
                if visibleChats.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let index = session.chats.firstIndex(where: { $0.id == id }) {
                    DemoModeChatView(chat: $session.chats[index])
                }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout DemoModeChat) -> Void) {
        guard let index = session.chats.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy) { change(&session.chats[index]) }
    }
}

struct DemoModeChatRow: View {
    let chat: DemoModeChat

    private var preview: String {
        guard let last = chat.last else { return "" }
        if last.isMine { return "Вы: \(last.text)" }
        if chat.isGroup, let author = last.author { return "\(author.split(separator: " ").first ?? ""): \(last.text)" }
        return last.text
    }

    var body: some View {
        HStack(spacing: 12) {
            DemoModeAvatar(name: chat.title, size: 54, online: chat.isOnline)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(chat.title).font(.headline).lineLimit(1)
                    if chat.muted {
                        Image(systemName: "speaker.slash.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    if let last = chat.last {
                        if last.isMine { DemoModeStatusIcon(status: last.status) }
                        Text(DemoModeFormat.listTime(last.date))
                            .font(.subheadline)
                            .foregroundStyle(chat.unread > 0 && !chat.muted ? Brand.accent : Color.secondary)
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if chat.unread > 0 {
                        Text("\(chat.unread)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(Capsule().fill(chat.muted ? Color.gray : Brand.accent))
                    } else if chat.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .rotationEffect(.degrees(45))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
#endif
