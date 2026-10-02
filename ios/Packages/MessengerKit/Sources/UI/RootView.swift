import DesignSystem
import Domain
import SwiftUI

/// Entry view: launch → login → (temporary password change) → main screens.
public struct RootView: View {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: AppModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        Group {
            switch model.phase {
            case .launching:
                LaunchView()
            case .loggedOut:
                LoginView(model: model)
            case .mustChangePassword(let account):
                ChangePasswordView(model: model, account: account)
            case .loggedIn(let account):
                MainTabView(model: model, account: account)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.phase)
        .tint(Brand.accent)
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.appBecameActive() } }
        }
    }
}

/// Shown while a saved session is restored (continues the system launch screen visually).
struct LaunchView: View {
    var body: some View {
        VStack(spacing: 20) {
            AppLogo(size: 104)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColorCompatible: .systemBackground))
    }
}
