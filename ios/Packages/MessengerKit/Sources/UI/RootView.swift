import Domain
import SwiftUI

/// Entry view. In the skeleton it shows the login screen only.
public struct RootView: View {
    private let authService: (any AuthService)?

    /// - Parameter authService: `nil` in the skeleton build (no implementation exists yet).
    public init(authService: (any AuthService)?) {
        self.authService = authService
    }

    public var body: some View {
        LoginView(authService: authService)
    }
}
