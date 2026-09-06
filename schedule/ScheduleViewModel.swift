import Foundation
import SwiftUI
import BackgroundTasks
import Combine
import WidgetKit
import UserNotifications

// MARK: - Уведомления
final class NotificationManager {
    static let shared = NotificationManager()
    
    func request() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }
    
    func notify(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

@MainActor
class ScheduleViewModel: ObservableObject {
    @Published var searchQuery: String = ""
    @Published var searchResults: [Group] = []
    @Published var selectedGroup: Group? = nil
    
    @Published var allLessons: [Lesson] = []
    @Published var lessonGroups: [LessonGroup] = []
    @Published var isLoading = false
    @Published var lastUpdateTime: Date? = nil
    
    @Published var favorites: [Group] = []
    @Published var searchHistory: [Group] = []
    @Published var homeGroup: Group? = nil
    
    @Published var navigationStack: [Group] = []
    private var scheduleCache: [String: (group: Group, lessons: [Lesson])] = [:]
    
    @Published var selectedDate: Date = Date()
    @Published var weekStart: Date = Date().startOfWeek
    @Published var lastWeekDirection: Edge = .trailing
    
    private let userDefaults = UserDefaults.standard
    private let groupIdKey = "selectedGroupId"
    private let groupNameKey = "selectedGroupName"
    private let groupTypeKey = "selectedGroupType"
    private let lastUpdateKey = "lastUpdateKey"
    private let favoritesKey = "favorites"
    private let historyKey = "searchHistory"
    private let homeKey = "homeGroup"
    private let snapshotKey = "lessonSnapshot"
    
    private var loadGeneration = 0
    
    let backgroundTaskIdentifier = "com.fa.schedule.refresh"
    
    /// Защита от повторной регистрации фоновой задачи.
    /// ScheduleViewModel может создаваться несколько раз (главный + предзагрузка в splash),
    /// но фоновую задачу с одним identifier можно регистрировать только один раз за запуск приложения.
    private static var backgroundTaskRegistered = false
    
    init() {
        loadFavoritesAndHistory()
        loadHomeGroup()
        #if os(iOS)
        registerBackgroundTask()
        #endif
        updateSharedEntityList()
    }
    
    // MARK: - Обновление при входе в приложение (не чаще раза в 10 минут)
    func refreshOnForeground() {
        guard selectedGroup != nil else { return }
        if let last = lastUpdateTime, Date().timeIntervalSince(last) < 600 { return }
        fetchSchedule()
    }
    
    func refreshSchedule() {
        guard !isLoading else { return }
        fetchSchedule()
    }
    
    // MARK: - Загрузка
    func fetchSchedule() {
        guard let group = selectedGroup else { return }
        
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        
        let id = group.id
        let type = group.type ?? "group"
        let key = "\(type)_\(id)"
        
        Task {
            var fresh: [Lesson] = []
            
            // ЭТАП 1: текущая неделя (мгновенно)
            let wStart = Date().startOfWeek
            let wEnd = Calendar.current.date(byAdding: .day, value: 6, to: wStart)!
            let weekLessons = await RuzAPI.shared.fetchChunk(entityId: id, type: type, start: wStart, end: wEnd)
            guard gen == self.loadGeneration else { return }
            fresh += weekLessons
            self.mergeLessons(weekLessons)
            self.lastUpdateTime = Date()
            self.filterLessonsForSelectedDate()
            self.scheduleCache[key] = (group, self.allLessons)
            self.persistShared(group: group, lessons: self.allLessons)
            self.detectChanges(weekLessons)   // быстрая проверка изменений
            
            // ЭТАП 2: весь семестр кусками по 30 дней
            let (semStart, semEnd) = getSemesterDates()
            let cal = Calendar.current
            var cursor = semStart
            while cursor <= semEnd {
                let chunkEnd = min(cal.date(byAdding: .day, value: 29, to: cursor)!, semEnd)
                let chunk = await RuzAPI.shared.fetchChunk(entityId: id, type: type, start: cursor, end: chunkEnd)
                guard gen == self.loadGeneration else { return }
                fresh += chunk
                self.mergeLessons(chunk)
                self.filterLessonsForSelectedDate()
                cursor = cal.date(byAdding: .day, value: 30, to: cursor)!
            }
            
            if !fresh.isEmpty { self.allLessons = fresh }
            self.scheduleCache[key] = (group, self.allLessons)
            self.persistShared(group: group, lessons: self.allLessons)
            self.detectChanges(fresh)         // полная проверка после семестра
            
            self.isLoading = false
            self.lastUpdateTime = Date()
            userDefaults.set(Date(), forKey: lastUpdateKey)
            self.filterLessonsForSelectedDate()
            self.scheduleNextRefresh()        // умное планирование следующего обновления
        }
    }
    
    // MARK: - Умное расписание обновлений
    // 30 мин до начала пары, 15 мин до конца пары, 20 мин после начала (переход к следующей),
    // ночью (23–5) раз в 2 часа, днём раз в 30 мин
    private func smartRefreshDate() -> Date {
        let now = Date()
        var candidates: [Date] = []
        
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        
        for l in allLessons {
            if let d = l.date, let b = l.beginLesson, let s = f.date(from: "\(d) \(b)") {
                candidates.append(s.addingTimeInterval(-30 * 60))   // за 30 мин до начала
                candidates.append(s.addingTimeInterval(20 * 60))    // через 20 мин после начала (переход к следующей)
            }
            if let d = l.date, let e = l.endLesson, let en = f.date(from: "\(d) \(e)") {
                candidates.append(en.addingTimeInterval(-15 * 60))  // за 15 мин до конца
            }
        }
        
        let hour = Calendar.current.component(.hour, from: now)
        let slot: TimeInterval = (hour >= 5 && hour < 23) ? 30 * 60 : 2 * 3600
        candidates.append(now.addingTimeInterval(slot))
        
        return candidates.filter { $0 > now.addingTimeInterval(120) }.min() ?? now.addingTimeInterval(slot)
    }
    
    func scheduleNextRefresh() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = smartRefreshDate()
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }
    
    // MARK: - Обнаружение изменений + уведомления
    private func lessonKey(_ l: Lesson) -> String {
        "\(l.lessonOid ?? 0)|\(l.date ?? "")|\(l.beginLesson ?? "")"
    }
    
    private static func isSession(_ kind: String?) -> Bool {
        let k = (kind ?? "").lowercased()
        return k.contains("экзамен") || k.contains("зачет") || k.contains("зачёт")
            || k.contains("пересдач") || k.contains("повторн")
    }
    
    private func prettyDate(_ iso: String?) -> String {
        guard let iso else { return "" }
        let inF = DateFormatter()
        inF.dateFormat = "yyyy-MM-dd"
        guard let d = inF.date(from: iso) else { return iso }
        return d.format("d MMM")
    }
    
    private func detectChanges(_ fresh: [Lesson]) {
        let oldArray = userDefaults.stringArray(forKey: snapshotKey) ?? []
        let isFirstLaunch = oldArray.isEmpty
        let old = Set(oldArray)
        
        let newKeys = Set(fresh.map { lessonKey($0) })
        userDefaults.set(Array(newKeys), forKey: snapshotKey)
        
        // Первый запуск — просто запоминаем снимок, не спамим уведомлениями
        guard !isFirstLaunch else { return }
        
        let newLessons = fresh.filter { !old.contains(lessonKey($0)) }
        guard !newLessons.isEmpty else { return }
        
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        let plus2 = f.string(from: Calendar.current.date(byAdding: .day, value: 2, to: Date())!)
        
        let nearNew = newLessons.filter { ($0.date ?? "") >= today && ($0.date ?? "") <= plus2 }
        let sessionNew = newLessons.filter { Self.isSession($0.kindOfWork) }
        
        let stamp = Int(Date().timeIntervalSince1970)
        
        if !sessionNew.isEmpty {
            let list = sessionNew.prefix(3)
                .map { "\($0.discipline ?? "Занятие") — \(prettyDate($0.date)), \($0.beginLesson ?? "")" }
                .joined(separator: "\n")
            let extra = sessionNew.count > 3 ? "\nи ещё \(sessionNew.count - 3)…" : ""
            NotificationManager.shared.notify(
                title: "📅 Появилось расписание сессии",
                body: list + extra,
                id: "session-\(stamp)"
            )
        } else if !nearNew.isEmpty {
            let list = nearNew.prefix(3)
                .map { "\($0.discipline ?? "Занятие") — \(prettyDate($0.date)), \($0.beginLesson ?? ""), ауд. \($0.auditorium ?? "—")" }
                .joined(separator: "\n")
            let extra = nearNew.count > 3 ? "\nи ещё \(nearNew.count - 3)…" : ""
            NotificationManager.shared.notify(
                title: "✏️ Новые занятия",
                body: list + extra,
                id: "new-\(stamp)"
            )
        }
    }
    
    // MARK: - Семестр
    private func getSemesterDates() -> (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        let currentYear = cal.component(.year, from: now)
        
        let aug1 = formatter.date(from: "\(currentYear).08.01")!
        let feb4 = formatter.date(from: "\(currentYear+1).02.04")!
        let feb5 = formatter.date(from: "\(currentYear).02.05")!
        
        if now >= aug1 {
            return (aug1, feb4)
        } else if now < feb5 {
            let prevAug1 = formatter.date(from: "\(currentYear-1).08.01")!
            return (prevAug1, feb4)
        } else {
            return (feb5, aug1)
        }
    }
    
    private func mergeLessons(_ newLessons: [Lesson]) {
        let existingKeys = Set(allLessons.map { lessonKey($0) })
        var added = [Lesson]()
        for lesson in newLessons where !existingKeys.contains(lessonKey(lesson)) {
            added.append(lesson)
        }
        allLessons.append(contentsOf: added)
    }
    
    func filterLessonsForSelectedDate() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let s = formatter.string(from: selectedDate)
        
        let dayLessons = allLessons
            .filter { $0.date == s }
            .sorted { ($0.beginLesson ?? "") < ($1.beginLesson ?? "") }
        
        var dict: [String: [Lesson]] = [:]
        var order: [String] = []
        for l in dayLessons {
            let key = "\(l.discipline ?? "")|\(l.beginLesson ?? "")"
            if dict[key] == nil { order.append(key) }
            dict[key, default: []].append(l)
        }
        
        lessonGroups = order.map { key in
            var ls = dict[key]!
            var seen = Set<String>()
            var deduped: [Lesson] = []
            for l in ls {
                let k = "\((l.lecturer ?? "").trimmingCharacters(in: .whitespaces))|\((l.auditorium ?? "").trimmingCharacters(in: .whitespaces))"
                if seen.insert(k).inserted { deduped.append(l) }
            }
            ls = deduped
            return LessonGroup(
                id: key + "|" + s,
                discipline: ls.first?.discipline,
                kindOfWork: ls.first?.kindOfWork,
                beginLesson: ls.first?.beginLesson,
                endLesson: ls.first?.endLesson,
                lessons: ls
            )
        }
    }
    
    // MARK: - Виджеты
    private func persistShared(group: Group, lessons: [Lesson]) {
        guard let shared = UserDefaults(suiteName: "group.com.schedule.ruz") else { return }
        if let data = try? JSONEncoder().encode(lessons) {
            shared.set(data, forKey: "lessons_\(group.type ?? "group")_\(group.id)")
        }
        updateSharedEntityList()
    }
    
    private func updateSharedEntityList() {
        guard let shared = UserDefaults(suiteName: "group.com.schedule.ruz") else { return }
        var list: [SharedEntity] = []
        var seen = Set<String>()
        
        func add(_ g: Group?) {
            guard let g else { return }
            let key = "\(g.type ?? "group")_\(g.id)"
            guard !seen.contains(key) else { return }
            seen.insert(key)
            list.append(SharedEntity(key: key, name: g.name, type: g.type ?? "group"))
        }
        
        add(homeGroup)
        add(selectedGroup)
        favorites.forEach(add)
        searchHistory.forEach(add)
        scheduleCache.values.forEach { add($0.group) }
        
        if let data = try? JSONEncoder().encode(list) {
            shared.set(data, forKey: "widgetGroups")
        }
        if let home = homeGroup {
            shared.set("\(home.type ?? "group")_\(home.id)", forKey: "homeKey")
        } else {
            shared.removeObject(forKey: "homeKey")
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    // MARK: - Поиск
    func searchGroups() {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            searchResults = []
            return
        }
        Task {
            do {
                let results = try await RuzAPI.shared.fetchGroups(query: q)
                self.searchResults = results
            } catch {
                print("Ошибка поиска: \(error)")
            }
        }
    }
    
    // MARK: - Избранное
    func toggleFavorite(_ group: Group) {
        if let idx = favorites.firstIndex(where: { $0.id == group.id && $0.type == group.type }) {
            favorites.remove(at: idx)
        } else {
            favorites.insert(group, at: 0)
        }
        persistFavorites()
        updateSharedEntityList()
    }
    
    func isFavorite(_ group: Group) -> Bool {
        favorites.contains { $0.id == group.id && $0.type == group.type }
    }
    
    func removeFavorites(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        persistFavorites()
        updateSharedEntityList()
    }
    
    func clearFavorites() {
        favorites = []
        persistFavorites()
        updateSharedEntityList()
    }
    
    private func persistFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            userDefaults.set(data, forKey: favoritesKey)
        }
    }
    
    // MARK: - История
    func addToHistory(_ group: Group) {
        searchHistory.removeAll { $0.id == group.id && $0.type == group.type }
        searchHistory.insert(group, at: 0)
        if searchHistory.count > 10 { searchHistory = Array(searchHistory.prefix(10)) }
        if let data = try? JSONEncoder().encode(searchHistory) {
            userDefaults.set(data, forKey: historyKey)
        }
        updateSharedEntityList()
    }
    
    func clearHistory() {
        searchHistory = []
        userDefaults.removeObject(forKey: historyKey)
        updateSharedEntityList()
    }
    
    private func loadFavoritesAndHistory() {
        if let data = userDefaults.data(forKey: favoritesKey),
           let favs = try? JSONDecoder().decode([Group].self, from: data) {
            favorites = favs
        }
        if let data = userDefaults.data(forKey: historyKey),
           let hist = try? JSONDecoder().decode([Group].self, from: data) {
            searchHistory = hist
        }
    }
    
    // MARK: - Домашняя группа
    func setHome(_ group: Group?) {
        homeGroup = group
        if let g = group, let data = try? JSONEncoder().encode(g) {
            userDefaults.set(data, forKey: homeKey)
        } else {
            userDefaults.removeObject(forKey: homeKey)
        }
        updateSharedEntityList()
    }
    
    private func loadHomeGroup() {
        if let data = userDefaults.data(forKey: homeKey),
           let g = try? JSONDecoder().decode(Group.self, from: data) {
            homeGroup = g
            selectedGroup = g
            return
        }
        loadSavedGroup()
    }
    
    // MARK: - Навигация
    func selectGroup(_ group: Group) {
        navigationStack = []
        addToHistory(group)
        applySelection(group)
    }
    
    func navigateTo(_ group: Group) {
        if let current = selectedGroup, current.id != group.id || current.type != group.type {
            navigationStack.append(current)
        }
        applySelection(group)
    }
    
    func goBack() {
        guard !navigationStack.isEmpty else { return }
        let prev = navigationStack.removeLast()
        applySelection(prev)
    }
    
    private func applySelection(_ group: Group) {
        selectedGroup = group
        userDefaults.set(group.id, forKey: groupIdKey)
        userDefaults.set(group.name, forKey: groupNameKey)
        userDefaults.set(group.type ?? "group", forKey: groupTypeKey)
        
        let key = "\(group.type ?? "group")_\(group.id)"
        if let cached = scheduleCache[key] {
            allLessons = cached.lessons
        } else {
            allLessons = []
        }
        filterLessonsForSelectedDate()
        updateSharedEntityList()
        fetchSchedule()
    }
    
    // MARK: - Кэш
    func clearCache() {
        scheduleCache = [:]
        allLessons = []
        lessonGroups = []
        lastUpdateTime = nil
        if let shared = UserDefaults(suiteName: "group.com.schedule.ruz") {
            for k in shared.dictionaryRepresentation().keys where k.hasPrefix("lessons_") {
                shared.removeObject(forKey: k)
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
        updateSharedEntityList()
        if selectedGroup != nil { fetchSchedule() }
    }
    
    // MARK: - Календарь
    func changeWeekKeepingWeekday(by value: Int) {
        lastWeekDirection = value > 0 ? .trailing : .leading
        selectedDate = Calendar.current.date(byAdding: .day, value: value * 7, to: selectedDate) ?? selectedDate
        weekStart = selectedDate.startOfWeek
        filterLessonsForSelectedDate()
    }
    
    func changeDay(by value: Int) {
        selectedDate = Calendar.current.date(byAdding: .day, value: value, to: selectedDate) ?? selectedDate
        weekStart = selectedDate.startOfWeek
        filterLessonsForSelectedDate()
    }
    
    func jump(to date: Date) {
        lastWeekDirection = date > selectedDate ? .trailing : .leading
        selectedDate = date
        weekStart = date.startOfWeek
        filterLessonsForSelectedDate()
    }
    
    func selectDate(_ date: Date) {
        self.selectedDate = date
        filterLessonsForSelectedDate()
    }
    
    private func loadSavedGroup() {
        if let id = userDefaults.string(forKey: groupIdKey),
           let name = userDefaults.string(forKey: groupNameKey) {
            let type = userDefaults.string(forKey: groupTypeKey) ?? "group"
            self.selectedGroup = Group(id: id, name: name, type: type, description: nil)
        }
    }
    
    #if os(iOS)
    private func registerBackgroundTask() {
        // Защита от повторной регистрации — фоновая задача с одним identifier
        // может быть зарегистрирована только один раз за запуск приложения.
        // ScheduleViewModel может создаваться несколько раз (AppRootView + LKSplashView.preload).
        guard !Self.backgroundTaskRegistered else {
            print("[BGTask] Фоновая задача уже зарегистрирована — пропуск")
            return
        }
        Self.backgroundTaskRegistered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
    }
    
    private func handleAppRefresh(task: BGAppRefreshTask) {
        // Планируем следующую итерацию сразу (цепочка не прерывается)
        scheduleNextRefresh()
        fetchSchedule()
        task.setTaskCompleted(success: true)
    }
    
    // Совместимость со старым названием
    func scheduleAppRefresh() {
        scheduleNextRefresh()
    }
    #endif
}

extension Date {
    var startOfWeek: Date {
        let cal = Calendar.current
        let cmp = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: self)
        return cal.date(from: cmp) ?? self
    }
    
    func format(_ format: String) -> String {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "ru_RU")
        return f.string(from: self)
    }
    
    var isToday: Bool { Calendar.current.isDateInToday(self) }
    
    func isInSameDay(as date: Date) -> Bool {
        Calendar.current.isDate(self, inSameDayAs: date)
    }
}
