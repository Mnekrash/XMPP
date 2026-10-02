/// Errors as the user sees them. Technical detail goes to diagnostic logging only.
public enum UserFacingError: Error, Sendable, Equatable {
    case cannotConnect
    case invalidCredentials
    case accountDisabled
    case weakPassword
    case sendFailed
    case attachmentTooLarge
    case storageFull
    case unknown

    public var message: String {
        switch self {
        case .cannotConnect: "Нет соединения с сервером. Проверьте интернет и попробуйте ещё раз."
        case .invalidCredentials: "Неверный логин или пароль."
        case .accountDisabled: "Аккаунт отключён. Обратитесь к администратору."
        case .weakPassword: "Слишком простой пароль. Используйте не меньше 10 символов: буквы, цифры и знаки."
        case .sendFailed: "Сообщение не отправлено. Нажмите, чтобы повторить."
        case .attachmentTooLarge: "Файл слишком большой."
        case .storageFull: "На iPhone закончилось место."
        case .unknown: "Что-то пошло не так. Попробуйте ещё раз."
        }
    }
}
