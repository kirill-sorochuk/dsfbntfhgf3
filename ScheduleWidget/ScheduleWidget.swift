import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Модели
struct WidgetLesson: Codable {
    let discipline: String?
    let kindOfWork: String?
    let auditorium: String?
    let building: String?
    let lecturer: String?
    let lecturerTitle: String?
    let date: String?
    let beginLesson: String?
    let endLesson: String?
}

struct SharedEntry: Codable {
    let key: String
    let name: String
    let type: String
}

// MARK: - Тип занятия (короткие названия)
func lessonTypeLabel(_ kind: String?) -> String {
    let k = (kind ?? "").lowercased()

    // Пересдачи — первыми
    if k.contains("повторн") || k.contains("пересдач") {
        if k.contains("экзамен") { return "Пересдача экзамена" }
        if k.contains("зачет") || k.contains("зачёт") { return "Пересдача зачета" }
    }
    if k.contains("консульт") { return "Консультация" }
    if k.contains("экзамен") { return "Экзамен" }
    // "Семинар+зачет" или "зачет" → Зачет
    if k.contains("зачет") || k.contains("зачёт") { return "Зачет" }
    if k.contains("вебинар") { return "Вебинар" }
    if k.contains("лекц") { return "Лекция" }
    // Практические (семинарские) занятия → Семинар
    if k.contains("практ") || k.contains("семин") { return "Семинар" }
    return kind ?? "Другое"
}

// Цвета: пары «экзамен/пересдача» и «зачет/пересдача» — одинаковые
func typeColor(_ kind: String?) -> Color {
    switch lessonTypeLabel(kind) {
    case "Экзамен", "Пересдача экзамена": return .red
    case "Зачет", "Пересдача зачета":     return .orange
    case "Лекция":                        return .blue
    case "Семинар":                       return .green
    case "Консультация":                  return .indigo
    case "Вебинар":                       return .teal
    default:                              return .gray
    }
}

extension Int {
    func pluralForm(one: String, few: String, many: String) -> String {
        let n = abs(self) % 100, n1 = abs(self) % 10
        if n >= 11 && n <= 14 { return many }
        if n1 == 1 { return one }
        if n1 >= 2 && n1 <= 4 { return few }
        return many
    }
}

// MARK: - Хранилище
enum WidgetStore {
    static let suite = UserDefaults(suiteName: "group.com.schedule.ruz")
    
    static func entities() -> [SharedEntry] {
        guard let data = suite?.data(forKey: "widgetGroups"),
              let list = try? JSONDecoder().decode([SharedEntry].self, from: data) else { return [] }
        return list
    }
    
    static func lessons(key: String) -> [WidgetLesson] {
        guard let data = suite?.data(forKey: "lessons_\(key)") else { return [] }
        return (try? JSONDecoder().decode([WidgetLesson].self, from: data)) ?? []
    }
    
    static func resolve(_ config: ScheduleSelectionIntent) -> SharedEntry? {
        if let e = config.schedule { return SharedEntry(key: e.key, name: e.name, type: e.type) }
        let list = entities()
        if let homeKey = suite?.string(forKey: "homeKey"),
           let home = list.first(where: { $0.key == homeKey }) {
            return home
        }
        return list.first
    }
    
    static func date(_ day: String?, _ time: String?) -> Date? {
        guard let day, let time else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone.current
        return f.date(from: "\(day) \(time)")
    }
    
    static func minutes(_ hhmm: String?) -> Int? {
        guard let hhmm else { return nil }
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
    
    static func ru(_ d: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "ru_RU")
        return f.string(from: d)
    }
    
    // Умное обновление: за 30 мин до начала, за 15 мин до конца,
    // через 20 мин после начала (переход к следующей паре),
    // днём каждые 30 мин, ночью (23–5) раз в 2 часа
    static func smartRefresh(lessons: [WidgetLesson], after now: Date) -> Date {
        var candidates: [Date] = []
        for l in lessons {
            if let s = date(l.date, l.beginLesson) {
                candidates.append(s.addingTimeInterval(-30 * 60))   // за 30 мин до начала
                candidates.append(s.addingTimeInterval(20 * 60))    // через 20 мин после начала
            }
            if let e = date(l.date, l.endLesson) {
                candidates.append(e.addingTimeInterval(-15 * 60))  // за 15 мин до конца
            }
        }
        let hour = Calendar.current.component(.hour, from: now)
        let slot: TimeInterval = (hour >= 5 && hour < 23) ? 30 * 60 : 2 * 3600
        candidates.append(now.addingTimeInterval(slot))
        return candidates.filter { $0 > now.addingTimeInterval(120) }.min() ?? now.addingTimeInterval(slot)
    }
    
    /// Порог «показа следующей»: если пара идёт дольше 20 минут —
    /// она уже не считается «текущей/ближайшей», переходим к следующей.
    static let nextLessonThresholdMinutes: TimeInterval = 20 * 60

    /// Активный день: сегодня (если есть пары, которые ещё показываются), иначе ближайший с парами
    /// Пара считается «показанной», пока не прошло 20 минут после её начала.
    static func activeDay(lessons: [WidgetLesson], now: Date) -> (date: Date, label: String) {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        
        let todayKey = f.string(from: now)
        // Есть ли сегодня пары, которые ещё «показываются» (не прошли порог 20 мин)?
        let hasUpcomingToday = lessons.contains { l in
            guard l.date == todayKey,
                  let start = date(l.date, l.beginLesson) else { return false }
            // Пара ещё показывается, если:
            // - она ещё не началась, ИЛИ
            // - она идёт, но прошло меньше 20 минут с начала
            // После истечения 20 минут — переходим к следующей
            return start > now || now < start.addingTimeInterval(nextLessonThresholdMinutes)
        }
        if hasUpcomingToday { return (now, "Сегодня · \(ru(now, "EE"))") }
        
        for offset in 1...14 {
            guard let d = cal.date(byAdding: .day, value: offset, to: now) else { break }
            let key = f.string(from: d)
            if lessons.contains(where: { $0.date == key }) {
                return (d, dayWord(d, now: now))
            }
        }
        return (now, "Сегодня · \(ru(now, "EE"))")
    }
    
    static func dayWord(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Сегодня · \(ru(d, "EE"))" }
        if cal.isDateInTomorrow(d) { return "Завтра · \(ru(d, "EE"))" }
        if let after = cal.date(byAdding: .day, value: 2, to: now), cal.isDate(d, inSameDayAs: after) {
            return "Послезавтра · \(ru(d, "EE"))"
        }
        return "\(ru(d, "d MMM")) · \(ru(d, "EE"))"
    }
    
    static func relativeLabel(for lesson: WidgetLesson, now: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        guard let ds = lesson.date, let d = f.date(from: ds) else { return "" }
        return dayWord(d, now: now)
    }
    
    static func entityIcon(_ type: String) -> String {
        switch type {
        case "lecturer": return "person.fill"
        case "auditorium": return "door.left.hand.open"
        default: return "graduationcap.fill"
        }
    }
    
    static func entitySubtitle(_ type: String) -> String {
        switch type {
        case "lecturer": return "Преподаватель"
        case "auditorium": return "Аудитория"
        default: return "Группа"
        }
    }
    
    // "Ф24/ауд.1402(кк)" → prefix "Ф24/", number "1402"
    static func shortAudParts(_ a: String?) -> (prefix: String, number: String)? {
        guard let a, !a.isEmpty else { return nil }
        var s = a.trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) {
            s = String(s[s.startIndex..<r.lowerBound])
        }
        s = s.replacingOccurrences(of: "ауд.", with: "")
        s = s.trimmingCharacters(in: .whitespaces)
        
        if let slash = s.firstIndex(of: "/") {
            let prefix = String(s[...slash]) // включает «/»
            let number = String(s[s.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
            if !number.isEmpty { return (prefix, number) }
        }
        return ("", s)
    }
}

// MARK: - Выбор расписания (настройка виджета)
struct ScheduleEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "Расписание")
    static let defaultQuery = ScheduleEntityQuery()
    
    let key: String
    let name: String
    let type: String
    
    var id: String { key }
    
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(WidgetStore.entitySubtitle(type))")
    }
}

struct ScheduleEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ScheduleEntity] {
        WidgetStore.entities()
            .filter { identifiers.contains($0.key) }
            .map { ScheduleEntity(key: $0.key, name: $0.name, type: $0.type) }
    }
    
    func suggestedEntities() async throws -> [ScheduleEntity] {
        WidgetStore.entities().map { ScheduleEntity(key: $0.key, name: $0.name, type: $0.type) }
    }
    
    func defaultResult() async throws -> ScheduleEntity? {
        WidgetStore.entities().first.map { ScheduleEntity(key: $0.key, name: $0.name, type: $0.type) }
    }
}

struct ScheduleSelectionIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Расписание"
    static var description = IntentDescription("Группа, преподаватель или аудитория")
    
    @Parameter(title: "Расписание")
    var schedule: ScheduleEntity?
    
    init() {}
    init(schedule: ScheduleEntity?) {
        self.schedule = schedule
    }
}

// MARK: - Листание страниц (интерактивность большого виджета)
struct PageTurnIntent: AppIntent {
    static var title: LocalizedStringResource = "Листать"
    
    @Parameter(title: "Delta", default: 0)
    var delta: Int
    
    @Parameter(title: "Key", default: "")
    var storageKey: String
    
    init() {}
    init(delta: Int, storageKey: String) {
        self.delta = delta
        self.storageKey = storageKey
    }
    
    func perform() async throws -> some IntentResult {
        if let shared = UserDefaults(suiteName: "group.com.schedule.ruz") {
            let current = shared.integer(forKey: storageKey)
            shared.set(max(0, current + delta), forKey: storageKey)
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

extension Date {
    func formatHM() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: self)
    }
}

// MARK: - 1. Виджет «Ближайшая пара»
struct NearestEntry: TimelineEntry {
    let date: Date
    let entity: SharedEntry
    let lesson: WidgetLesson?
    let lecturer: String?
    let minutesToStart: Int?
}

struct NearestProvider: AppIntentTimelineProvider {
    
    static func empty(_ at: Date) -> NearestEntry {
        NearestEntry(date: at,
                     entity: SharedEntry(key: "", name: "Выберите расписание", type: "group"),
                     lesson: nil,
                     lecturer: nil,
                     minutesToStart: nil)
    }
    
    func placeholder(in context: Context) -> NearestEntry {
        NearestEntry(date: Date(),
                     entity: SharedEntry(key: "group_0", name: "Группа", type: "group"),
                     lesson: WidgetLesson(discipline: "Математический анализ",
                                          kindOfWork: "Лекция",
                                          auditorium: "Ф24/ауд.1402(кк)",
                                          building: nil,
                                          lecturer: "Иванов И.И.",
                                          lecturerTitle: "Иванов Иван Иванович",
                                          date: nil,
                                          beginLesson: "10:10",
                                          endLesson: "11:40"),
                     lecturer: "Иванов И.И.",
                     minutesToStart: 25)
    }
    
    func snapshot(for configuration: ScheduleSelectionIntent, in context: Context) async -> NearestEntry {
        make(configuration, at: Date())
    }
    
    func timeline(for configuration: ScheduleSelectionIntent, in context: Context) async -> Timeline<NearestEntry> {
        let now = Date()
        guard let entity = WidgetStore.resolve(configuration) else {
            return Timeline(entries: [Self.empty(now)], policy: .after(now.addingTimeInterval(3600)))
        }
        let lessons = WidgetStore.lessons(key: entity.key)

        // Границы для обновления виджета:
        // - начало каждой пары (показать новую пару)
        // - начало + 20 минут (переключиться на следующую)
        // - конец каждой пары
        // - сейчас
        var boundaries: Set<Date> = [now]
        for l in lessons {
            if let s = WidgetStore.date(l.date, l.beginLesson), s > now {
                boundaries.insert(s)
                // Через 20 минут после начала — переход к следующей паре
                boundaries.insert(s.addingTimeInterval(WidgetStore.nextLessonThresholdMinutes))
            }
            if let e = WidgetStore.date(l.date, l.endLesson), e > now { boundaries.insert(e) }
        }
        let entries = boundaries.sorted().prefix(12).map { make(configuration, at: $0) }
        let refresh = WidgetStore.smartRefresh(lessons: lessons, after: now)
        return Timeline(entries: Array(entries), policy: .after(refresh))
    }
    
    private func make(_ config: ScheduleSelectionIntent, at date: Date) -> NearestEntry {
        guard let entity = WidgetStore.resolve(config) else { return Self.empty(date) }
        let lessons = WidgetStore.lessons(key: entity.key)
        
        // Применяем порог 20 минут: пара, идущая дольше 20 минут, уже не показывается.
        // Виджет переходит к следующей паре.
        let candidates = lessons
            .compactMap { l -> (start: Date, lesson: WidgetLesson)? in
                guard let s = WidgetStore.date(l.date, l.beginLesson) else { return nil }
                return (s, l)
            }
            .filter { pair in
                // Пара «актуальна» для показа, если:
                // 1. Она ещё не началась (старт в будущем), ИЛИ
                // 2. Она идёт, но прошло меньше 20 минут с начала
                // После 20 минут — пара «скрыта», показываем следующую
                if pair.start > date { return true } // будущая пара
                let threshold = pair.start.addingTimeInterval(WidgetStore.nextLessonThresholdMinutes)
                if date < threshold { return true } // идёт, но меньше 20 минут
                return false
            }
            .sorted { $0.start < $1.start }
        
        guard let next = candidates.first else {
            return NearestEntry(date: date,
                                entity: entity,
                                lesson: nil,
                                lecturer: nil,
                                minutesToStart: nil)
        }
        
        let mins = Int(next.start.timeIntervalSince(date) / 60)
        // mins < 0 — пара идёт сейчас
        // 0...240 — «через N мин»
        // > 240 — далеко (завтра и позже), не показываем минуты
        let minutesToStart: Int? = mins < 0 ? 0 : (mins <= 240 ? mins : nil)
        return NearestEntry(date: date,
                            entity: entity,
                            lesson: next.lesson,
                            lecturer: next.lesson.lecturer,
                            minutesToStart: minutesToStart)
    }
}

struct NearestWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NearestEntry
    
    var body: some View {
        Group {
            if family == .systemMedium {
                NearestMediumView(entry: entry)
            } else {
                NearestSmallView(entry: entry)
            }
        }
        .widgetBackground()
    }
}

// Маленький виджет: ближайшая пара
// Чёткая структура: время крупно, дисциплина, аудитория
struct NearestSmallView: View {
    let entry: NearestEntry

    private var typeLabel: String {
        guard let l = entry.lesson else { return "" }
        return lessonTypeLabel(l.kindOfWork)
    }

    private var typeCol: Color {
        guard let l = entry.lesson else { return .gray }
        return typeColor(l.kindOfWork)
    }

    private var dayLabel: String {
        guard let l = entry.lesson, let ds = l.date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        guard let d = f.date(from: ds) else { return "" }
        return WidgetStore.dayWord(d, now: entry.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Шапка: группа + бейдж
            HStack(spacing: 4) {
                Image(systemName: WidgetStore.entityIcon(entry.entity.type))
                    .font(.system(size: 9, weight: .bold))
                Text(entry.entity.name)
                    .font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .foregroundColor(.blue)

            if let l = entry.lesson {
                // Бейдж: день + время до начала
                HStack(spacing: 4) {
                    Text(dayLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    if let m = entry.minutesToStart {
                        Text(m == 0 ? "· идёт" : "· через \(m)м")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundColor(typeCol)
                    }
                }
                .lineLimit(1)
                .padding(.top, 2)

                Spacer(minLength: 4)

                // Время — КРУПНО, всегда видно
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(l.beginLesson ?? "—")
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                    Text("–")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.secondary)
                    Text(l.endLesson ?? "")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .minimumScaleFactor(0.6)

                // Тип + цветная точка
                HStack(spacing: 4) {
                    Circle().fill(typeCol).frame(width: 6, height: 6)
                    Text(typeLabel)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(typeCol)
                }
                .padding(.top, 2)

                // Дисциплина
                Text(l.discipline ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 4)

                Spacer(minLength: 0)

                // Аудитория — с иконкой, читаемо
                if let aud = l.auditorium, !aud.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "mappin")
                            .font(.system(size: 10))
                        Text(aud)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .foregroundColor(.secondary)
                }
            } else {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2)
                    Text("Пар нет")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.secondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// Средний виджет: ближайшая пара — больше деталей
struct NearestMediumView: View {
    let entry: NearestEntry

    private var typeLabel: String {
        guard let l = entry.lesson else { return "" }
        return lessonTypeLabel(l.kindOfWork)
    }

    private var typeCol: Color {
        guard let l = entry.lesson else { return .gray }
        return typeColor(l.kindOfWork)
    }

    private var dayLabel: String {
        guard let l = entry.lesson, let ds = l.date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        guard let d = f.date(from: ds) else { return "" }
        return WidgetStore.dayWord(d, now: entry.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Шапка: группа + день
            HStack(spacing: 4) {
                Image(systemName: WidgetStore.entityIcon(entry.entity.type))
                    .font(.system(size: 11, weight: .bold))
                Text(entry.entity.name)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Text(dayLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .foregroundColor(.blue)

            if let l = entry.lesson {
                // Цветная полоска
                RoundedRectangle(cornerRadius: 2)
                    .fill(typeCol)
                    .frame(height: 3)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                // Время — КРУПНО
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(l.beginLesson ?? "—")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                    Text("–")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.secondary)
                    Text(l.endLesson ?? "")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundColor(.secondary)
                    Spacer()
                    if let m = entry.minutesToStart {
                        Text(m == 0 ? "идёт" : "через \(m) мин")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(typeCol, in: Capsule())
                    }
                }
                .minimumScaleFactor(0.7)

                // Дисциплина
                Text(l.discipline ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .padding(.top, 4)

                // Тип + преподаватель
                HStack(spacing: 6) {
                    Text(typeLabel)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(typeCol)
                    if let full = l.lecturerTitle ?? l.lecturer, !full.isEmpty {
                        Text("· \(full)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 2)

                Spacer(minLength: 0)

                // Аудитория — с иконкой, полная строка
                if let aud = l.auditorium, !aud.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(typeCol)
                        Text(aud)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Spacer()
                    }
                }
            } else {
                Spacer()
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                    Text("Ближайших пар нет").foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - 2. Виджет «День целиком» (большой, интерактивный)
struct DayEntry: TimelineEntry {
    let date: Date
    let entity: SharedEntry
    let dayDate: Date
    let dayLabel: String
    let lessons: [WidgetLesson]
    let pageLessons: [WidgetLesson]
    let page: Int
    let totalPages: Int
    let pageKey: String
}

struct DayProvider: AppIntentTimelineProvider {
    static let pageSize = 6
    
    static func empty(_ at: Date) -> DayEntry {
        DayEntry(date: at,
                 entity: SharedEntry(key: "", name: "Выберите расписание", type: "group"),
                 dayDate: at,
                 dayLabel: "",
                 lessons: [],
                 pageLessons: [],
                 page: 0,
                 totalPages: 1,
                 pageKey: "")
    }
    
    func placeholder(in context: Context) -> DayEntry {
        DayEntry(date: Date(),
                 entity: SharedEntry(key: "group_0", name: "Группа", type: "group"),
                 dayDate: Date(),
                 dayLabel: "Сегодня · Чт",
                 lessons: [],
                 pageLessons: [],
                 page: 0,
                 totalPages: 1,
                 pageKey: "placeholder")
    }
    
    func snapshot(for configuration: ScheduleSelectionIntent, in context: Context) async -> DayEntry {
        make(configuration, at: Date())
    }
    
    func timeline(for configuration: ScheduleSelectionIntent, in context: Context) async -> Timeline<DayEntry> {
        let now = Date()
        guard let entity = WidgetStore.resolve(configuration) else {
            return Timeline(entries: [Self.empty(now)], policy: .after(now.addingTimeInterval(3600)))
        }
        let lessons = WidgetStore.lessons(key: entity.key)

        // Границы обновления: начало, +20 мин, конец каждой пары
        var boundaries: Set<Date> = [now]
        for l in lessons {
            if let s = WidgetStore.date(l.date, l.beginLesson), s > now {
                boundaries.insert(s)
                boundaries.insert(s.addingTimeInterval(WidgetStore.nextLessonThresholdMinutes))
            }
            if let e = WidgetStore.date(l.date, l.endLesson), e > now { boundaries.insert(e) }
        }
        let entries = boundaries.sorted().prefix(12).map { make(configuration, at: $0) }
        let refresh = WidgetStore.smartRefresh(lessons: lessons, after: now)
        return Timeline(entries: Array(entries), policy: .after(refresh))
    }
    
    private func make(_ config: ScheduleSelectionIntent, at date: Date) -> DayEntry {
        guard let entity = WidgetStore.resolve(config) else { return Self.empty(date) }
        let lessons = WidgetStore.lessons(key: entity.key)
        let (day, label) = WidgetStore.activeDay(lessons: lessons, now: date)
        
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        let dayKey = f.string(from: day)
        let dayLessons = lessons
            .filter { $0.date == dayKey }
            .sorted { ($0.beginLesson ?? "") < ($1.beginLesson ?? "") }
        
        let totalPages = max(1, Int(ceil(Double(dayLessons.count) / Double(DayProvider.pageSize))))
        let pageKey = "page_day_\(entity.key)_\(dayKey)"
        let stored = UserDefaults(suiteName: "group.com.schedule.ruz")?.integer(forKey: pageKey) ?? 0
        let page = min(max(0, stored), totalPages - 1)
        
        let startIdx = page * DayProvider.pageSize
        let slice = Array(dayLessons.dropFirst(startIdx).prefix(DayProvider.pageSize))
        
        return DayEntry(date: date,
                        entity: entity,
                        dayDate: day,
                        dayLabel: label,
                        lessons: dayLessons,
                        pageLessons: slice,
                        page: page,
                        totalPages: totalPages,
                        pageKey: pageKey)
    }
}

struct DayWidgetView: View {
    let entry: DayEntry

    private func isCurrent(_ l: WidgetLesson) -> Bool {
        guard let beginDate = WidgetStore.date(l.date, l.beginLesson) else { return false }
        let now = entry.date
        return now >= beginDate && now < beginDate.addingTimeInterval(WidgetStore.nextLessonThresholdMinutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Шапка: группа + день
            HStack(spacing: 4) {
                Image(systemName: WidgetStore.entityIcon(entry.entity.type))
                    .font(.system(size: 11, weight: .bold))
                Text(entry.entity.name)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Text(entry.dayLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .foregroundColor(.blue)

            if entry.lessons.isEmpty {
                Spacer()
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                    Text("Пар нет").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(Array(entry.pageLessons.enumerated()), id: \.offset) { _, l in
                    dayRow(l)
                }

                Spacer(minLength: 0)

                if entry.totalPages > 1 {
                    HStack {
                        Spacer()
                        Text("\(entry.lessons.count) \(entry.lessons.count.pluralForm(one: "пара", few: "пары", many: "пар"))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(intent: PageTurnIntent(delta: -1, storageKey: entry.pageKey)) {
                            Image(systemName: "chevron.up.circle.fill")
                                .font(.system(size: 22))
                        }
                        .buttonStyle(.borderless)
                        Text("\(entry.page + 1)/\(entry.totalPages)")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                        Button(intent: PageTurnIntent(delta: 1, storageKey: entry.pageKey)) {
                            Image(systemName: "chevron.down.circle.fill")
                                .font(.system(size: 22))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetBackground()
    }

    private func dayRow(_ l: WidgetLesson) -> some View {
        let current = isCurrent(l)
        let typeCol = typeColor(l.kindOfWork)
        return HStack(spacing: 8) {
            // Цветная полоска
            RoundedRectangle(cornerRadius: 2)
                .fill(typeCol)
                .frame(width: 3)

            // Время — чётко, моноширинно
            VStack(alignment: .leading, spacing: 1) {
                Text(l.beginLesson ?? "—")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(l.endLesson ?? "")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            .frame(width: 42, alignment: .leading)

            // Дисциплина + тип + аудитория
            VStack(alignment: .leading, spacing: 2) {
                Text(l.discipline ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(lessonTypeLabel(l.kindOfWork))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(typeCol)
                    if let aud = l.auditorium, !aud.isEmpty {
                        Text("· \(aud)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(current ? typeCol.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(current ? typeCol.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - 3. Виджет «Время занятий»
struct TimesEntry: TimelineEntry {
    let date: Date
    let entity: SharedEntry
    let dayLabel: String
    let firstBegin: String?
    let lastEnd: String?
    let count: Int
    let lessons: [WidgetLesson]
}

struct TimesProvider: AppIntentTimelineProvider {
    
    static func empty(_ at: Date) -> TimesEntry {
        TimesEntry(date: at,
                   entity: SharedEntry(key: "", name: "Выберите расписание", type: "group"),
                   dayLabel: "",
                   firstBegin: nil,
                   lastEnd: nil,
                   count: 0,
                   lessons: [])
    }
    
    func placeholder(in context: Context) -> TimesEntry {
        TimesEntry(date: Date(),
                   entity: SharedEntry(key: "group_0", name: "Группа", type: "group"),
                   dayLabel: "Сегодня · Чт",
                   firstBegin: "10:10",
                   lastEnd: "18:55",
                   count: 4,
                   lessons: [])
    }
    
    func snapshot(for configuration: ScheduleSelectionIntent, in context: Context) async -> TimesEntry {
        make(configuration, at: Date())
    }
    
    func timeline(for configuration: ScheduleSelectionIntent, in context: Context) async -> Timeline<TimesEntry> {
        let now = Date()
        guard let entity = WidgetStore.resolve(configuration) else {
            return Timeline(entries: [Self.empty(now)], policy: .after(now.addingTimeInterval(3600)))
        }
        let lessons = WidgetStore.lessons(key: entity.key)

        // Границы обновления: начало, +20 мин, конец каждой пары
        var boundaries: Set<Date> = [now]
        for l in lessons {
            if let s = WidgetStore.date(l.date, l.beginLesson), s > now {
                boundaries.insert(s)
                boundaries.insert(s.addingTimeInterval(WidgetStore.nextLessonThresholdMinutes))
            }
            if let e = WidgetStore.date(l.date, l.endLesson), e > now { boundaries.insert(e) }
        }
        let entries = boundaries.sorted().prefix(12).map { make(configuration, at: $0) }
        let refresh = WidgetStore.smartRefresh(lessons: lessons, after: now)
        return Timeline(entries: Array(entries), policy: .after(refresh))
    }
    
    private func make(_ config: ScheduleSelectionIntent, at date: Date) -> TimesEntry {
        guard let entity = WidgetStore.resolve(config) else { return Self.empty(date) }
        let lessons = WidgetStore.lessons(key: entity.key)
        let (day, label) = WidgetStore.activeDay(lessons: lessons, now: date)
        
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        let dayKey = f.string(from: day)
        let dayLessons = lessons
            .filter { $0.date == dayKey }
            .sorted { ($0.beginLesson ?? "") < ($1.beginLesson ?? "") }
        
        return TimesEntry(date: date,
                          entity: entity,
                          dayLabel: label,
                          firstBegin: dayLessons.first?.beginLesson,
                          lastEnd: dayLessons.last?.endLesson,
                          count: dayLessons.count,
                          lessons: dayLessons)
    }
}

struct TimesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TimesEntry
    
    private var maxRows: Int { family == .systemMedium ? 3 : 8 }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Шапка: сущность + день
            HStack(spacing: 4) {
                Image(systemName: WidgetStore.entityIcon(entry.entity.type))
                    .font(.system(size: 11, weight: .bold))
                Text(entry.entity.name)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Text(entry.dayLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .foregroundColor(.blue)

            if entry.lessons.isEmpty {
                Spacer()
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                    Text("Пар нет").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                // Сводка: время + количество
                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.blue)
                    Text("\(entry.firstBegin ?? "") – \(entry.lastEnd ?? "")")
                        .font(.system(size: family == .systemMedium ? 17 : 19, weight: .heavy, design: .rounded))
                    Text("· \(entry.count) \(entry.count.pluralForm(one: "пара", few: "пары", many: "пар"))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .minimumScaleFactor(0.75)

                Divider()

                // Список занятий с цветными полосками
                ForEach(Array(entry.lessons.prefix(maxRows).enumerated()), id: \.offset) { _, l in
                    HStack(spacing: 6) {
                        // Цветная точка типа занятия
                        Circle()
                            .fill(typeColor(l.kindOfWork))
                            .frame(width: 6, height: 6)

                        Text(l.beginLesson ?? "")
                            .font(.system(size: 13, weight: .bold))
                            .monospacedDigit()
                            .frame(width: 38, alignment: .leading)

                        Text(l.discipline ?? "")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Text(lessonTypeLabel(l.kindOfWork))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(typeColor(l.kindOfWork))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }

                if entry.lessons.count > maxRows {
                    Text("…и ещё \(entry.lessons.count - maxRows)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetBackground()
    }
}

// MARK: - Регистрация виджетов
struct ScheduleWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ScheduleWidget", intent: ScheduleSelectionIntent.self, provider: NearestProvider()) { entry in
            NearestWidgetView(entry: entry)
        }
        .configurationDisplayName("Ближайшая пара")
        .description("Ближайшее занятие выбранной группы, преподавателя или аудитории.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DayScheduleWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DayScheduleWidget", intent: ScheduleSelectionIntent.self, provider: DayProvider()) { entry in
            DayWidgetView(entry: entry)
        }
        .configurationDisplayName("День целиком")
        .description("Все пары на сегодня (или завтра). Текущая пара выделена, список листается.")
        .supportedFamilies([.systemLarge])
    }
}

struct TimesWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TimesWidget", intent: ScheduleSelectionIntent.self, provider: TimesProvider()) { entry in
            TimesWidgetView(entry: entry)
        }
        .configurationDisplayName("Время занятий")
        .description("Первая и последняя пара дня + список предметов и типов занятий.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Фон виджета
extension View {
    @ViewBuilder
    func widgetBackground() -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.containerBackground(.fill.tertiary, for: .widget)
        } else {
            self.padding()
        }
    }
}
