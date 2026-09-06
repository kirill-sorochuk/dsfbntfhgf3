import Foundation
import SwiftUI

// MARK: - Универсальная сущность: группа, преподаватель или аудитория
struct Group: Codable, Identifiable {
    let id: String
    let name: String
    let type: String?
    let description: String?
    
    var isLecturer: Bool { type == "lecturer" }
    var isAuditorium: Bool { type == "auditorium" }
    var typeLabel: String {
        if isLecturer { return "Преподаватель" }
        if isAuditorium { return "Аудитория" }
        return "Группа"
    }
    
    enum CodingKeys: String, CodingKey {
        case id, type, description
        case name = "label"
    }
    
    init(id: String, name: String, type: String?, description: String?) {
        self.id = id
        self.name = name
        self.type = type
        self.description = description
    }
    
    // id приходит и числом, и строкой — понимаем оба варианта
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let intId = try? c.decode(Int.self, forKey: .id) {
            id = String(intId)
        } else {
            id = (try? c.decode(String.self, forKey: .id)) ?? ""
        }
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        type = try? c.decode(String.self, forKey: .type)
        description = try? c.decode(String.self, forKey: .description)
    }
}

// MARK: - Занятие
struct Lesson: Codable, Identifiable {
    var id: String {
        if let oid = lessonOid { return String(oid) }
        return UUID().uuidString
    }
    
    let lessonOid: Int?
    let discipline: String?
    let kindOfWork: String?
    let auditorium: String?
    let building: String?
    let lecturer: String?          // «Гайдамака А.И.»
    let lecturerTitle: String?     // «Гайдамака Андрей Иванович» (полное ФИО)
    let lecturerEmail: String?     // корпоративная почта
    let lecturerOid: Int?
    let auditoriumOid: Int?
    let lessonNumberStart: Int?
    let stream: String?            // поток групп, например «ИТМ24-1-4 + ТЦБМ24-1-3»
    let streamOid: Int?
    let group: String?             // группа, у которой идёт пара (в расписании преподавателя)
    let groupOid: Int?
    let date: String?
    let beginLesson: String?
    let endLesson: String?
    
    enum CodingKeys: String, CodingKey {
        case lessonOid, discipline, kindOfWork, auditorium, building
        case lecturer, lecturerEmail, lecturerOid, auditoriumOid, lessonNumberStart
        case stream, streamOid, group, groupOid, date, beginLesson, endLesson
        case lecturerTitle = "lecturer_title"
    }
}

// MARK: - Сетка звонков (номер пары)
enum LessonSlot {
    static let slots: [(number: Int, start: String)] = [
        (1, "08:30"), (2, "10:10"), (3, "11:50"), (4, "14:00"),
        (5, "15:40"), (6, "17:20"), (7, "18:55"), (8, "20:30")
    ]
    
    // Определяем номер пары по времени начала (ближайший слот)
    static func number(for begin: String?) -> Int? {
        guard let begin, let b = minutes(begin) else { return nil }
        var best: (number: Int, diff: Int)? = nil
        for slot in slots {
            guard let s = minutes(slot.start) else { continue }
            let diff = abs(b - s)
            if best == nil || diff < best!.diff { best = (slot.number, diff) }
        }
        return best?.number
    }
    
    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}

// MARK: - Сгруппированное занятие (один предмет в одно время)
struct LessonGroup: Identifiable {
    let id: String
    let discipline: String?
    let kindOfWork: String?
    let beginLesson: String?
    let endLesson: String?
    let lessons: [Lesson]
    
    var lessonNumber: Int? {
        lessons.first?.lessonNumberStart ?? LessonSlot.number(for: beginLesson)
    }
    
    // Группы занятия (в расписании преподавателя): group, иначе stream
    var groupsLine: String? {
        var names: [String] = []
        var seen = Set<String>()
        for l in lessons {
            let n = (l.group ?? l.stream ?? "").trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty, seen.insert(n).inserted else { continue }
            names.append(n)
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }
    
    // Группы с ID для перехода к их расписанию
    var groupTargets: [(oid: Int, name: String)] {
        var seen = Set<String>()
        var result: [(Int, String)] = []
        for l in lessons {
            let name = (l.group ?? l.stream ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  let oid = l.groupOid ?? l.streamOid, oid != 0,
                  seen.insert(name).inserted else { continue }
            result.append((oid, name))
        }
        return result
    }
}

// MARK: - Сущность для списка расписаний в виджетах
struct SharedEntity: Codable {
    let key: String
    let name: String
    let type: String
}

// MARK: - API
class RuzAPI {
    static let shared = RuzAPI()
    
    // Поиск групп и преподавателей (преподаватель приоритетнее дубля-«группы»)
    func fetchGroups(query: String) async throws -> [Group] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://ruz.fa.ru/api/search?term=\(encodedQuery)"
        guard let url = URL(string: urlString) else { return [] }
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let results = try? JSONDecoder().decode([Group].self, from: data) else { return [] }
        
        // Если человек найден и как «группа», и как «lecturer» — оставляем только преподавателя
        let lecturerNames = Set(results.filter { $0.isLecturer }.map { $0.name.lowercased() })
        let cleaned = results.filter { entry in
            guard entry.type == "group" || entry.type == "lecturer" else { return false }
            if entry.type == "group" && lecturerNames.contains(entry.name.lowercased()) { return false }
            return true
        }
        
        var seen = Set<String>()
        return cleaned.filter { seen.insert("\($0.type ?? "?")|\($0.id)|\($0.name)").inserted }
    }
    
    // Кусок расписания: сущность + диапазон дат. Ошибок не бросает — возвращает [].
    // Сервер отдаёт максимум ~месяц за запрос, поэтому семестр качается кусками по 30 дней.
    func fetchChunk(entityId: String, type: String, start: Date, end: Date) async -> [Lesson] {
        let reqF = DateFormatter()
        reqF.dateFormat = "yyyy.MM.dd"   // формат запроса к серверу
        let resF = DateFormatter()
        resF.dateFormat = "yyyy-MM-dd"   // формат дат в ответе
        
        let pathCandidates: [String]
        switch type {
        case "lecturer": pathCandidates = ["lecturer", "person", "teacher"]
        case "auditorium": pathCandidates = ["auditorium", "auditoriums"]
        default: pathCandidates = ["group"]
        }
        
        let startStr = reqF.string(from: start)
        let endStr = reqF.string(from: end)
        let startKey = resF.string(from: start)
        let endKey = resF.string(from: end)
        
        for path in pathCandidates {
            // start/finish — рабочие параметры; start_date/finish_date — запасные
            let urlString = "https://ruz.fa.ru/api/schedule/\(path)/\(entityId)?start=\(startStr)&finish=\(endStr)&start_date=\(startStr)&finish_date=\(endStr)"
            guard let url = URL(string: urlString) else { continue }
            
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 30
            
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let lessons = try? JSONDecoder().decode([Lesson].self, from: data) else { continue }
            
            // Оставляем только запрошенный диапазон (сервер любит отдавать лишнее)
            let filtered = lessons.filter { lesson in
                guard let d = lesson.date else { return false }
                return d >= startKey && d <= endKey
            }
            print("📦 \(startStr)–\(endStr) [\(path)]: \(filtered.count) пар")
            return filtered
        }
        
        print("⚠️ \(startStr)–\(endStr): кусок не загрузился")
        return []
    }
}

// MARK: - Тип занятия (короткие названия, унифицировано с виджетом)
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

func typeColor(_ kind: String?) -> Color {
    let label = lessonTypeLabel(kind)
    switch label {
    case "Экзамен", "Пересдача экзамена": return .red
    case "Зачет", "Пересдача зачета":     return .orange
    case "Лекция":                        return .blue
    case "Семинар":                       return .green
    case "Консультация":                  return .indigo
    case "Вебинар":                       return .teal
    default:                              return .gray
    }
}
