#if DEMO_MODE
// DemoMode — Development builds only. Shows the demo screens while a demo session is active;
// otherwise the normal app (RootView) is shown unchanged.

import DesignSystem
import Domain
import SwiftUI
import UI

struct DemoModeRoot: View {
    let model: AppModel
    @State private var session = DemoModeSession.shared

    var body: some View {
        if session.isActive, case .loggedIn(let account) = model.phase {
            DemoModeMainView(model: model, account: account, session: session)
        } else {
            RootView(model: model)
        }
    }
}

struct DemoModeMainView: View {
    let model: AppModel
    let account: AccountInfo
    @Bindable var session: DemoModeSession

    var body: some View {
        TabView {
            DemoModeChatListView(session: session)
                .tabItem { Label("Чаты", systemImage: "bubble.left.and.bubble.right.fill") }
                .badge(session.totalUnread)
            DemoModeSettingsView(model: model, account: account, session: session)
                .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
        }
        .tint(Brand.accent)
        .preferredColorScheme(session.appearance.colorScheme)
    }
}

/// Small "Демо" label so a demo screen is never mistaken for real data.
struct DemoModeBadge: View {
    var body: some View {
        Text("Демо")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange))
            .accessibilityLabel("Демо-режим")
    }
}

struct DemoModeAvatar: View {
    let name: String
    var size: CGFloat = 52
    var online = false

    private static let palette: [Color] = [
        Color(red: 0.95, green: 0.42, blue: 0.36), Color(red: 0.98, green: 0.62, blue: 0.24),
        Color(red: 0.58, green: 0.45, blue: 0.93), Color(red: 0.30, green: 0.73, blue: 0.42),
        Color(red: 0.22, green: 0.68, blue: 0.80), Color(red: 0.25, green: 0.55, blue: 0.96),
        Color(red: 0.93, green: 0.40, blue: 0.62),
    ]

    /// Stable per name (String.hashValue changes between launches).
    static func color(for name: String) -> Color {
        var hash: UInt = 0
        for scalar in name.unicodeScalars { hash = hash &* 31 &+ UInt(scalar.value) }
        return palette[Int(hash % UInt(palette.count))]
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var body: some View {
        let color = Self.color(for: name)
        Circle()
            .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .overlay(alignment: .bottomTrailing) {
                if online {
                    Circle()
                        .fill(Color.green)
                        .frame(width: size * 0.26, height: size * 0.26)
                        .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                }
            }
            .accessibilityHidden(true)
    }
}

struct DemoModeStatusIcon: View {
    let status: DemoModeMessage.Status
    var color: Color = Brand.accent

    var body: some View {
        Group {
            switch status {
            case .sending:
                Image(systemName: "clock")
            case .sent:
                Image(systemName: "checkmark")
            case .read:
                HStack(spacing: -6) {
                    Image(systemName: "checkmark")
                    Image(systemName: "checkmark")
                }
            }
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(color)
        .accessibilityLabel(status == .read ? "Прочитано" : status == .sent ? "Доставлено" : "Отправляется")
    }
}
#endif
