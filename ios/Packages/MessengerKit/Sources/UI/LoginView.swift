import Domain
import SwiftUI

struct LoginView: View {
    let authService: (any AuthService)?

    @State private var username = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    usernameField
                    passwordField
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Log In")
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle("Welcome")
        }
    }

    @ViewBuilder
    private var usernameField: some View {
        #if os(iOS)
        TextField("Username", text: $username)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        TextField("Username", text: $username)
        #endif
    }

    @ViewBuilder
    private var passwordField: some View {
        #if os(iOS)
        SecureField("Password", text: $password)
            .textContentType(.password)
        #else
        SecureField("Password", text: $password)
        #endif
    }

    private func submit() async {
        guard let authService else {
            // SKELETON: no AuthService implementation exists yet (Phase 2).
            errorMessage = "Login is not available in this build yet."
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        errorMessage = nil
        do {
            try await authService.logIn(
                username: username.trimmingCharacters(in: .whitespaces).lowercased(),
                password: password
            )
        } catch {
            errorMessage = error.message
        }
    }
}
