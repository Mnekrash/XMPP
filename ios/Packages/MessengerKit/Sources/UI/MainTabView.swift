import DesignSystem
import Domain
import SwiftUI

struct MainTabView: View {
    let model: AppModel
    let account: AccountInfo

    var body: some View {
        TabView {
            ChatsView(model: model)
                .tabItem { Label("Чаты", systemImage: "bubble.left.and.bubble.right.fill") }
            SettingsView(model: model, account: account)
                .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
        }
    }
}

struct ChatsView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Нет чатов", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Здесь появятся ваши переписки.")
            }
            .navigationTitle(model.connection == .online ? "Чаты" : statusTitle)
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ConnectionTitle(state: model.connection)
                }
            }
        }
    }

    private var statusTitle: String { model.connection == .connecting ? "Подключение…" : "Ожидание сети…" }
}

/// "Чаты" when online; "Подключение…" with a spinner otherwise (Telegram-like status in the title).
struct ConnectionTitle: View {
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 6) {
            if state != .online { ProgressView().controlSize(.small) }
            Text(text).font(.headline)
        }
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        switch state {
        case .online: "Чаты"
        case .connecting, .updating: "Подключение…"
        case .offline: "Ожидание сети…"
        }
    }
}

extension View {
    func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        return navigationBarTitleDisplayMode(.inline)
        #else
        return self
        #endif
    }
}
