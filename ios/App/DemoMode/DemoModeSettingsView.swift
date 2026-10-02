#if DEMO_MODE
// DemoMode — Development builds only. Settings for the demo session: profile, theme, logout.

import DesignSystem
import Domain
import SwiftUI
import UI

struct DemoModeSettingsView: View {
    let model: AppModel
    let account: AccountInfo
    @Bindable var session: DemoModeSession
    @State private var confirmLogout = false

    private var name: String { account.displayName ?? account.username }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        DemoModeAvatar(name: name, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name).font(.title3.weight(.semibold))
                            Text("@\(account.username)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("Оформление") {
                    Picker("Тема", selection: $session.appearance) {
                        ForEach(DemoModeAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Демо-режим").font(.headline)
                            Text("Чаты и сообщения ненастоящие. Сервер, Keychain и уведомления не используются, ничего не сохраняется.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "theatermasks.fill").foregroundStyle(.orange)
                    }
                }

                Section {
                    Button("Выйти", role: .destructive) { confirmLogout = true }
                }

                Section {
                    HStack {
                        Text("Версия")
                        Spacer()
                        Text(version).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Настройки")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { DemoModeBadge() }
            }
            .confirmationDialog("Выйти из аккаунта на этом iPhone?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) { Task { await model.logOut() } }
            }
        }
    }
}
#endif
