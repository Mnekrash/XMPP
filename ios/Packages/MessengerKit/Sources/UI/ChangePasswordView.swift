import DesignSystem
import Domain
import SwiftUI

/// First login with the administrator's temporary password: the user sets their own.
struct ChangePasswordView: View {
    let model: AppModel
    let account: AccountInfo

    @State private var newPassword = ""
    @State private var repeatPassword = ""
    @State private var isSubmitting = false
    @State private var error: String?

    private var canSubmit: Bool { !newPassword.isEmpty && !repeatPassword.isEmpty && !isSubmitting }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Brand.accent)
                    Text("Придумайте пароль")
                        .font(.title2.weight(.bold))
                    Text("Вы вошли с временным паролем. Задайте свой пароль — временный перестанет работать.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 48)

                VStack(spacing: 12) {
                    SecureField("Новый пароль", text: $newPassword)
                        .credentialField(.newPassword)
                        .modifier(FieldBackground())
                    SecureField("Повторите пароль", text: $repeatPassword)
                        .credentialField(.newPassword)
                        .modifier(FieldBackground())
                    Text("Не меньше 10 символов. Лучше использовать буквы, цифры и знаки.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let error {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                        Text(error).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Button("Сохранить пароль") { Task { await submit() } }
                    .buttonStyle(PrimaryButtonStyle(isLoading: isSubmitting))
                    .disabled(!canSubmit)
                    .opacity(canSubmit || isSubmitting ? 1 : 0.5)

                Button("Выйти", role: .destructive) { Task { await model.logOut() } }
                    .font(.callout)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColorCompatible: .systemBackground))
    }

    private func submit() async {
        guard newPassword == repeatPassword else {
            error = "Пароли не совпадают."
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await model.changePassword(newPassword)
        } catch {
            self.error = error.message
        }
    }
}
