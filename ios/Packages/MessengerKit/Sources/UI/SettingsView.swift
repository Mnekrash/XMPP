import DesignSystem
import Domain
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    let account: AccountInfo

    @State private var versionTaps = 0
    @State private var showDiagnostics = false
    @State private var confirmLogout = false

    private var name: String { account.displayName ?? account.username }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Avatar(name: name, size: 60)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name).font(.title3.weight(.semibold))
                            Text("@\(account.username)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    Button("Выйти", role: .destructive) { confirmLogout = true }
                }

                Section {
                    HStack {
                        Text("Версия")
                        Spacer()
                        Text(Bundle.main.versionString).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Hidden developer diagnostics: tap the version row 5 times.
                        versionTaps += 1
                        if versionTaps >= 5 {
                            versionTaps = 0
                            showDiagnostics = true
                        }
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationDestination(isPresented: $showDiagnostics) { DiagnosticsView(model: model) }
            .confirmationDialog("Выйти из аккаунта на этом iPhone?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) { Task { await model.logOut() } }
            }
        }
    }
}

struct Avatar: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Brand.gradient, in: Circle())
            .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
}

/// Developer-only screen. Reached only through the hidden gesture; never linked from normal UI.
struct DiagnosticsView: View {
    let model: AppModel
    @State private var entries: [DiagnosticsEntry] = []

    var body: some View {
        List(entries) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.key).font(.caption).foregroundStyle(.secondary)
                Text(entry.value).font(.callout.monospaced()).textSelection(.enabled)
            }
        }
        .navigationTitle("Diagnostics")
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        var list = await model.diagnostics()
        list.insert(DiagnosticsEntry("Connection (UI)", "\(model.connection)"), at: 0)
        entries = list
    }
}

extension Bundle {
    var versionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
