#if DEMO_MODE
// DemoMode — Development builds only. Sample people and messages; none of them exist on any server.

import Foundation

struct DemoModeMessage: Identifiable, Equatable {
    enum Status: Equatable { case sending, sent, read }

    struct Reply: Equatable {
        let author: String
        let text: String
    }

    struct Reaction: Equatable, Identifiable {
        var id: String { emoji }
        let emoji: String
        var count: Int
        var mine: Bool
    }

    let id: UUID
    /// nil = the demo user.
    let author: String?
    let text: String
    let date: Date
    var status: Status
    var reply: Reply?
    var reactions: [Reaction]

    var isMine: Bool { author == nil }
}

struct DemoModeChat: Identifiable, Equatable {
    enum Kind: Equatable {
        case direct(online: Bool, lastSeen: String)
        case group(members: Int)
    }

    let id: UUID
    let title: String
    let kind: Kind
    var messages: [DemoModeMessage]
    var unread: Int
    var pinned: Bool
    var muted: Bool

    var isGroup: Bool {
        if case .group = kind { return true }
        return false
    }

    var isOnline: Bool {
        if case .direct(let online, _) = kind { return online }
        return false
    }

    var subtitle: String {
        switch kind {
        case .direct(let online, let lastSeen): online ? "в сети" : lastSeen
        case .group(let members): "\(members) \(DemoModeFormat.members(members))"
        }
    }

    var last: DemoModeMessage? { messages.last }
}

enum DemoModeSampleData {
    private static let day: Double = 24 * 60

    private static func msg(_ author: String?, _ text: String, _ minutesAgo: Double,
                            status: DemoModeMessage.Status = .read, reply: DemoModeMessage.Reply? = nil,
                            reactions: [DemoModeMessage.Reaction] = []) -> DemoModeMessage {
        DemoModeMessage(id: UUID(), author: author, text: text, date: Date(timeIntervalSinceNow: -minutesAgo * 60),
                        status: status, reply: reply, reactions: reactions)
    }

    private static func react(_ emoji: String, _ count: Int, mine: Bool = false) -> DemoModeMessage.Reaction {
        DemoModeMessage.Reaction(emoji: emoji, count: count, mine: mine)
    }

    static func chats() -> [DemoModeChat] {
        [
            DemoModeChat(
                id: UUID(), title: "Анна Смирнова", kind: .direct(online: true, lastSeen: ""),
                messages: [
                    msg("Анна Смирнова", "Привет! Ты завтра будешь в офисе?", day + 120),
                    msg(nil, "Привет! Да, с 10 утра.", day + 115),
                    msg("Анна Смирнова", "Отлично, тогда покажу новые эскизы 🙂", day + 110, reactions: [react("👍", 1, mine: true)]),
                    msg(nil, "Доброе утро! Я уже на месте.", 95),
                    msg("Анна Смирнова", "Супер, буду минут через 20 ☕️", 12,
                        reply: .init(author: "Вы", text: "Доброе утро! Я уже на месте.")),
                    msg("Анна Смирнова", "Захвати, пожалуйста, распечатку плана", 3),
                ],
                unread: 2, pinned: true, muted: false),
            DemoModeChat(
                id: UUID(), title: "Команда проекта", kind: .group(members: 6),
                messages: [
                    msg("Дмитрий Орлов", "Коллеги, обновил график работ на следующую неделю", 240),
                    msg("Мария Белова", "Спасибо! Посмотрю после обеда", 236),
                    msg(nil, "Я внёс правки в смету, проверьте, пожалуйста, раздел 3", 200,
                        reactions: [react("👍", 3), react("🔥", 1)]),
                    msg("Дмитрий Орлов", "Проверил, всё сходится. Согласовываем?", 40,
                        reply: .init(author: "Вы", text: "Я внёс правки в смету, проверьте, пожалуйста, раздел 3")),
                    msg("Мария Белова", "Да, я за 👍", 35),
                    msg("Алексей Ким", "Поставщик подтвердил доставку на четверг", 8, reactions: [react("🎉", 2)]),
                    msg("Алексей Ким", "Счёт пришлю отдельным сообщением", 7),
                ],
                unread: 3, pinned: false, muted: false),
            DemoModeChat(
                id: UUID(), title: "Игорь Петров", kind: .direct(online: false, lastSeen: "был в сети 15 минут назад"),
                messages: [
                    msg("Игорь Петров", "Скинь, пожалуйста, контакты мастера", 300),
                    msg(nil, "Конечно: Николай, звонить после 10:00", 290),
                    msg("Игорь Петров", "Спасибо!", 285, reactions: [react("❤️", 1, mine: true)]),
                    msg(nil, "Как всё прошло?", 60, status: .sent),
                ],
                unread: 0, pinned: false, muted: false),
            DemoModeChat(
                id: UUID(), title: "Семья", kind: .group(members: 4),
                messages: [
                    msg("Мама", "Не забудьте, в субботу обед у бабушки", 180),
                    msg("Папа", "Я заеду за всеми в 12", 170),
                    msg(nil, "Отлично, мы будем готовы", 160, reactions: [react("❤️", 2)]),
                    msg("Мама", "Купите по дороге хлеб 🙂", 30),
                ],
                unread: 12, pinned: false, muted: true),
            DemoModeChat(
                id: UUID(), title: "Ольга Кузнецова", kind: .direct(online: false, lastSeen: "была в сети вчера"),
                messages: [
                    msg(nil, "Ольга, добрый день! Пришлите, пожалуйста, финальный вариант", 2 * day + 100),
                    msg("Ольга Кузнецова", "Добрый! Отправлю вечером", 2 * day + 60),
                    msg("Ольга Кузнецова", "Готово, проверьте почту ✉️", 2 * day, reactions: [react("🙏", 1, mine: true)]),
                ],
                unread: 0, pinned: false, muted: false),
            DemoModeChat(
                id: UUID(), title: "Сергей Волков", kind: .direct(online: false, lastSeen: "был в сети недавно"),
                messages: [
                    msg("Сергей Волков", "В выходные на склон? 🏂", 6 * day + 30),
                    msg(nil, "Если будет снег — однозначно!", 6 * day),
                ],
                unread: 0, pinned: false, muted: false),
        ]
    }
}

enum DemoModeFormat {
    static let ru = Locale(identifier: "ru_RU")

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(ru))
    }

    /// Chat list: time today, "Вчера", weekday within a week, otherwise the date.
    static func listTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time(date) }
        if calendar.isDateInYesterday(date) { return "Вчера" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated).locale(ru))
        }
        return date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits).locale(ru))
    }

    static func dayHeader(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Сегодня" }
        if calendar.isDateInYesterday(date) { return "Вчера" }
        return date.formatted(.dateTime.day().month(.wide).locale(ru))
    }

    static func members(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "участник" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "участника" }
        return "участников"
    }
}
#endif
