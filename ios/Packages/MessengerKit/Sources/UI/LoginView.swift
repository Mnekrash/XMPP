import DesignSystem
import Domain
import SwiftUI

struct LoginView: View {
    let model: AppModel

    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var isSubmitting = false
    @State private var error: UserFacingError?
    @FocusState private var focus: Field?

    enum Field { case username, password }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !isSubmitting
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    AppLogo(size: 92)
                    Text(Brand.name)
                        .font(.largeTitle.weight(.bold))
                    Text("Войдите с логином и паролем,\nкоторые выдал администратор.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 48)

                VStack(spacing: 12) {
                    TextField("Логин", text: $username)
                        .textContentType(.username)
                        .noAutocapitalization()
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .username)
                        .onSubmit { focus = .password }
                        .modifier(FieldBackground())

                    HStack {
                        Group {
                            if showPassword {
                                TextField("Пароль", text: $password)
                            } else {
                                SecureField("Пароль", text: $password)
                            }
                        }
                        .textContentType(.password)
                        .noAutocapitalization()
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focus, equals: .password)
                        .onSubmit { Task { await submit() } }

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(showPassword ? "Скрыть пароль" : "Показать пароль")
                    }
                    .modifier(FieldBackground())
                }

                if let error {
                    ErrorBanner(error: error)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Button("Войти") { Task { await submit() } }
                    .buttonStyle(PrimaryButtonStyle(isLoading: isSubmitting))
                    .disabled(!canSubmit)
                    .opacity(canSubmit || isSubmitting ? 1 : 0.5)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColorCompatible: .systemBackground))
        .animation(.easeInOut(duration: 0.2), value: error)
        .onChange(of: username) { _, _ in error = nil }
        .onChange(of: password) { _, _ in error = nil }
    }

    private func submit() async {
        guard canSubmit else { return }
        focus = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await model.logIn(username: username, password: password)
        } catch {
            self.error = error
            if error == .invalidCredentials { password = "" }
        }
    }
}

struct ErrorBanner: View {
    let error: UserFacingError

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: error == .cannotConnect ? "wifi.exclamationmark" : "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            Text(error.message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// iOS-only modifier, no-op on the macOS test build.
    func noAutocapitalization() -> some View {
        #if os(iOS)
        return textInputAutocapitalization(.never)
        #else
        return self
        #endif
    }
}
