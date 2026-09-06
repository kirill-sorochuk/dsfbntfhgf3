import Foundation
import SwiftUI
import WebKit
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Модели

struct FlexibleValue: Codable {
    let intValue: Int?
    let stringValue: String?

    init(intValue: Int? = nil, stringValue: String? = nil) {
        self.intValue = intValue
        self.stringValue = stringValue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            intValue = i; stringValue = nil
        } else if let s = try? c.decode(String.self) {
            intValue = nil; stringValue = s
        } else {
            intValue = nil; stringValue = nil
        }
    }

    var text: String? {
        if let i = intValue { return String(i) }
        return stringValue
    }

    var numericGrade: Int? {
        if let i = intValue, (2...5).contains(i) { return i }
        guard let s = stringValue?.lowercased() else { return nil }
        if s.contains("отлич") { return 5 }
        if s.contains("хорош") { return 4 }
        if s.contains("удовл") { return 3 }
        if s.contains("неудовл") { return 2 }
        if s.contains("зачт") { return 5 }
        if s.contains("не зачт") { return 2 }
        return intValue
    }
}

struct GradebookYear: Codable, Identifiable {
    let year: Int
    let semesters: [GradebookSemester]
    var id: Int { year }
}

struct GradebookSemester: Codable, Identifiable {
    let semester: Int
    let data: [GradebookRow]
    var id: String { String(semester) }
}

struct GradebookRow: Codable, Identifiable {
    var id: String { "\(subject ?? "")-\(date ?? "")-\(control_type ?? "")" }

    let semester: Int?
    let date: String?
    let year: Int?
    let hours: String?
    let control_type: String?
    let mark: FlexibleValue?
    let mark_title: String?
    let scale: FlexibleValue?
    let subject: String?
    let subject_type: String?
    let zet: String?
    let lecturers: String?
    let p1: FlexibleValue?
    let p2: FlexibleValue?
    let t1: FlexibleValue?
    let t2: FlexibleValue?
    let t3: FlexibleValue?
    let t4: FlexibleValue?
    let uo: FlexibleValue?
    let itog: FlexibleValue?

    var displayGrade: String {
        if let t = mark_title, !t.isEmpty { return t }
        if let m = mark?.text { return m }
        return "—"
    }

    var isPassFail: Bool { scale?.intValue == 1 }
    var sortGrade: Int { mark?.numericGrade ?? 0 }

    var controlTypeDisplay: String {
        guard let ct = control_type?.lowercased() else { return "Зачёт" }
        if ct.contains("экзамен") { return "Экзамен" }
        return "Зачёт"
    }

    var isExam: Bool {
        guard let ct = control_type?.lowercased() else { return false }
        return ct.contains("экзамен")
    }

    var totalScore: Int? {
        itog?.intValue ?? itog?.stringValue.flatMap(Int.init)
    }

    /// Балл за зачёт/экзамен (максимум 60).
    /// Если `uo` (экзаменационная оценка) есть — используем её.
    /// Иначе вычисляем: itog − (t1 + t2), где t1/t2 — баллы ТКУ1/ТКУ2 (каждый ≤20).
    /// Если t1/t2 отсутствуют — пробуем извлечь из пропорции itog*0.6.
    var examScore: Int? {
        // 1) Пробуем поле uo (устная оценка / оценка за экзамен)
        if let uo = uo?.intValue { return min(uo, 60) }
        if let uoStr = uo?.stringValue, let uoInt = Int(uoStr) { return min(uoInt, 60) }

        // 2) Вычисляем: itog − (t1 + t2)
        if let total = totalScore {
            let t1Val = t1?.intValue ?? t1?.stringValue.flatMap(Int.init) ?? 0
            let t2Val = t2?.intValue ?? t2?.stringValue.flatMap(Int.init) ?? 0
            let computed = total - t1Val - t2Val
            if computed > 0 { return min(computed, 60) }
            // 3) Если отрицательный — пробуем 60% от итога
            return min(Int(Double(total) * 0.6), 60)
        }
        return nil
    }

    /// Какой балл показывать в карточке предмета рядом с "Экзамен/Зачёт".
    /// Это балл за сам зачёт/экзамен (≤60), не общий.
    var displayExamScore: Int {
        examScore ?? 0
    }

    var gradeDescription: String? {
        let t = displayGrade.lowercased()
        if t.contains("отлич") { return "Отлично" }
        if t.contains("хорош") { return "Хорошо" }
        if t.contains("удовл") { return "Удовлетворительно" }
        if t.contains("неудовл") { return "Неудовлетворительно" }
        if t.contains("зачт") { return "Зачтёно" }
        if t.contains("не зачт") { return "Не зачтёно" }
        return nil
    }

    var shouldShowGradeDescription: Bool {
        guard gradeDescription != nil else { return false }
        if isExam { return true }
        if totalScore == 0 { return true }
        return false
    }

    var hasAnyGrade: Bool {
        displayGrade != "—"
    }
}

// MARK: - Группировка по курсам

struct CourseGroup: Identifiable {
    let courseNumber: Int
    let yearValue: Int
    var semesters: [GradebookSemester]
    var id: Int { courseNumber }
    var academicYear: String { "\(yearValue)/\(yearValue + 1)" }
    var totalDisciplines: Int {
        semesters.reduce(0) { $0 + $1.data.count }
    }
}

// MARK: - Менеджер

@MainActor
final class GradebookManager: ObservableObject {
    @Published var years: [GradebookYear] = []
    @Published var courses: [CourseGroup] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var lastUpdated: Date?

    private let cacheKey = "cachedGradebook"
    private let cacheDateKey = "cachedGradebookDate"
    private let snapshotKey = "gradebookSnapshot"

    init() { loadCache() }

    func loadGradebook() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil

        // Читаем куки из обоих хранилищ (HTTPCookieStorage + WKWebView) и мержим
        let wkCookies = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                cont.resume(returning: cookies.filter { $0.domain.contains("fa.ru") })
            }
        }
        let storageCookies = (HTTPCookieStorage.shared.cookies ?? []).filter { $0.domain.contains("fa.ru") }
        var merged = wkCookies
        for cookie in storageCookies {
            if let idx = merged.firstIndex(where: { $0.name == cookie.name && $0.domain == cookie.domain }) {
                merged[idx] = cookie
            } else {
                merged.append(cookie)
            }
        }
        let faCookies = merged
        guard !faCookies.isEmpty else {
            self.error = "Не авторизован. Войдите в личный кабинет."
            self.isLoading = false
            return
        }

        // Гарантируем наличие Bitrix-сессии (BX_ORG_FA_RU_* cookies).
        // Bitrix использует собственную сессию, JWT НЕ нужен.
        await NativeAuthManager.ensureBitrixSession()
        // Перечитываем куки после handshake (могли добавиться BX_ORG_FA_RU_*)
        let wkCookies2 = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                cont.resume(returning: cookies.filter { $0.domain.contains("fa.ru") })
            }
        }
        let storageCookies2 = (HTTPCookieStorage.shared.cookies ?? []).filter { $0.domain.contains("fa.ru") }
        var merged2 = wkCookies2
        for cookie in storageCookies2 {
            if let idx = merged2.firstIndex(where: { $0.name == cookie.name && $0.domain == cookie.domain }) {
                merged2[idx] = cookie
            } else {
                merged2.append(cookie)
            }
        }
        let faCookies2 = merged2.isEmpty ? faCookies : merged2
        // ВАЖНО: для org.fa.ru отправляем ТОЛЬКО cookies домена org.fa.ru
        // (BX_ORG_FA_RU_*, PHPSESSID, vuzportalfinun_session). Cookie хедер с
        // ВСЕМИ fa.ru cookies (включая KEYCLOAK_IDENTITY ~2KB JWT) даёт 8KB+ —
        // nginx возвращает 400 "Request Header Or Cookie Too Large".
        let orgFaCookies = faCookies2.filter { $0.domain.contains("org.fa.ru") }
        let bxCount = orgFaCookies.filter { $0.name.hasPrefix("BX_ORG_FA_RU") }.count
        let cookieHeaderSize = orgFaCookies.reduce(0) { $0 + $1.name.count + $1.value.count + 3 }
        print("[Gradebook] BX_ORG_FA_RU=\(bxCount), org.fa.ru cookies=\(orgFaCookies.count), cookieHeader=\(cookieHeaderSize) bytes")

        // ВАЖНО: trailing slash обязателен — без него Bitrix возвращает 404.
        // /bitrix/vuz/api/marks2  -> 404
        // /bitrix/vuz/api/marks2/ -> 200
        var request = URLRequest(url: URL(string: "https://org.fa.ru/bitrix/vuz/api/marks2/")!)
        // НЕ устанавливаем httpShouldHandleCookies=true, чтобы URLSession не подставлял
        // свои cookies — мы формируем Cookie хедер вручную.
        // Используем ТОЛЬКО org.fa.ru cookies (не все fa.ru) — иначе 8KB+ → nginx 400.
        let headerFields = HTTPCookie.requestHeaderFields(with: orgFaCookies)
        for (name, value) in headerFields {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("https://org.fa.ru/app/profile;mode=edu/marks", forHTTPHeaderField: "Referer")
        // Критические заголовки для org.fa.ru API (без них 400/401)
        request.setValue("8.135.3", forHTTPHeaderField: "App-Version")
        request.setValue("browser-bitrix", forHTTPHeaderField: "App-Key")
        request.setValue("ru", forHTTPHeaderField: "App-Locale")
        request.setValue("-180", forHTTPHeaderField: "App-TimezoneOffset")
        // Authorization: Bearer НЕ добавляем — Bitrix использует собственную сессию
        // (BX_ORG_FA_RU_* cookies). JWT от elk-front невалиден для org.fa.ru.

        do {
            let (respData, resp) = try await URLSession.shared.data(for: request)
            var data = respData
            var http = resp as? HTTPURLResponse
            let initialStatus = http?.statusCode ?? 0
            print("[Gradebook] status=\(initialStatus), data=\(data.count) bytes")

            // Retry на 401: перезапускаем Bitrix SSO handshake и пробуем снова.
            // Раньше здесь обновляли JWT — но JWT не нужен, проблема в истекшей Bitrix-сессии.
            if http?.statusCode == 401 {
                print("[Gradebook] 401 — перезапускаем Bitrix SSO handshake")
                NativeAuthManager.resetBitrixSSO()
                let ok = await NativeAuthManager.shared.bitrixSSOHandshake()
                if ok {
                    // Перечитываем куки после повторного handshake и фильтруем только org.fa.ru
                    let wkCookies3 = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
                        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                            cont.resume(returning: cookies.filter { $0.domain.contains("fa.ru") })
                        }
                    }
                    let storageCookies3 = (HTTPCookieStorage.shared.cookies ?? []).filter { $0.domain.contains("fa.ru") }
                    var merged3 = wkCookies3
                    for cookie in storageCookies3 {
                        if let idx = merged3.firstIndex(where: { $0.name == cookie.name && $0.domain == cookie.domain }) {
                            merged3[idx] = cookie
                        } else {
                            merged3.append(cookie)
                        }
                    }
                    // Фильтруем только org.fa.ru — иначе 8KB+ → nginx 400
                    let retryCookies = merged3.filter { $0.domain.contains("org.fa.ru") }
                    let retryHeaders = HTTPCookie.requestHeaderFields(with: retryCookies)
                    for (name, value) in retryHeaders {
                        request.setValue(value, forHTTPHeaderField: name)
                    }
                    let (retryData, retryResp) = try await URLSession.shared.data(for: request)
                    data = retryData
                    http = retryResp as? HTTPURLResponse
                    print("[Gradebook] retry status=\(http?.statusCode ?? 0)")
                }
            }

            guard let http = http else {
                throw NSError(domain: "gradebook", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Нет ответа от сервера"])
            }
            if http.statusCode != 200 {
                let bodyPreview = String(data: data, encoding: .utf8)?.prefix(300) ?? "<binary>"
                print("[Gradebook] error body=\(bodyPreview)")
            }
            guard http.statusCode == 200 else {
                throw NSError(domain: "gradebook", code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Ошибка сервера: \(http.statusCode)"])
            }

            let jsonString = String(data: data, encoding: .utf8) ?? ""
            let list = try JSONDecoder().decode([GradebookYear].self, from: data)

            // Уведомления об изменениях
            detectGradeChanges(newData: list)

            self.years = list.sorted { $0.year > $1.year }
            self.rebuildCourses()
            self.lastUpdated = Date()
            self.isLoading = false
            self.error = nil

            if let shared = UserDefaults(suiteName: "group.com.schedule.ruz") {
                shared.set(jsonString, forKey: cacheKey)
                shared.set(Date().timeIntervalSince1970, forKey: cacheDateKey)
            }
        } catch {
            self.isLoading = false
            let nsError = error as NSError
            let code = nsError.code
            if !years.isEmpty {
                self.error = "Не удалось обновить. Показаны сохранённые данные."
            } else if code == 401 || code == 403 {
                self.error = "Сессия истекла. Войдите в личный кабинет заново (код \(code))."
            } else if code == 400 {
                self.error = "Ошибка запроса (код \(code)). Попробуйте позже."
            } else {
                self.error = "Ошибка: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Уведомления об изменении оценок

    private func detectGradeChanges(newData: [GradebookYear]) {
        let oldJSON: String = UserDefaults.standard.string(forKey: snapshotKey) ?? ""
        let newJSON: String = (try? JSONEncoder().encode(newData)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard !oldJSON.isEmpty, oldJSON != newJSON else {
            if !newJSON.isEmpty { UserDefaults.standard.set(newJSON, forKey: snapshotKey) }
            return
        }

        // Есть изменения — сравниваем
        var changes: [String] = []
        if let oldData = try? JSONDecoder().decode([GradebookYear].self, from: Data(oldJSON.utf8)) {
            let oldMap = gradeMap(from: oldData)
            let newMap = gradeMap(from: newData)
            for (key, newVal) in newMap {
                if let oldVal = oldMap[key], oldVal != newVal {
                    changes.append(key)
                }
            }
        }

        UserDefaults.standard.set(newJSON, forKey: snapshotKey)

        guard !changes.isEmpty else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let body: String
        if changes.count <= 3 {
            body = "Изменены оценки: " + changes.joined(separator: ", ")
        } else {
            body = "Изменено \(changes.count) оценок"
        }
        NotificationManager.shared.notify(
            title: "Изменение оценок",
            body: body,
            id: "grade-change-\(stamp)"
        )
    }

    private func gradeMap(from years: [GradebookYear]) -> [String: String] {
        var map: [String: String] = [:]
        for y in years {
            for s in y.semesters {
                for r in s.data {
                    let key = "\(r.subject ?? "")|\(r.control_type ?? "")"
                    let val = "\(r.mark?.text ?? "")|\(r.itog?.text ?? "")"
                    map[key] = val
                }
            }
        }
        return map
    }

    // MARK: - Группировка

    func rebuildCourses() {
        let sortedYears = years.sorted { $0.year < $1.year }
        guard let minYear = sortedYears.first?.year else { return }
        courses = sortedYears.map { year in
            CourseGroup(
                courseNumber: year.year - minYear + 1,
                yearValue: year.year,
                semesters: year.semesters.sorted { $0.semester < $1.semester }
            )
        }.sorted { $0.courseNumber > $1.courseNumber }
    }

    // MARK: - Статистика: 5-балльная (только экзамены)

    func semesterAverage5(_ semester: GradebookSemester) -> Double? {
        let vals = semester.data.filter { $0.isExam }.compactMap { $0.mark?.numericGrade }
        guard !vals.isEmpty else { return nil }
        return Double(vals.reduce(0, +)) / Double(vals.count)
    }

    var overallAverage5: Double? {
        var vals: [Int] = []
        for y in years {
            for s in y.semesters {
                for r in s.data {
                    if r.isExam, let g = r.mark?.numericGrade { vals.append(g) }
                }
            }
        }
        guard !vals.isEmpty else { return nil }
        return Double(vals.reduce(0, +)) / Double(vals.count)
    }

    // MARK: - Статистика: 100-балльная (все предметы)

    func semesterAverage100(_ semester: GradebookSemester) -> Double? {
        let vals = semester.data.compactMap { $0.totalScore }
        guard !vals.isEmpty else { return nil }
        return Double(vals.reduce(0, +)) / Double(vals.count)
    }

    var overallAverage100: Double? {
        var vals: [Int] = []
        for y in years {
            for s in y.semesters {
                for r in s.data {
                    if let s = r.totalScore { vals.append(s) }
                }
            }
        }
        guard !vals.isEmpty else { return nil }
        return Double(vals.reduce(0, +)) / Double(vals.count)
    }

    var totalDisciplines: Int {
        years.reduce(0) { $0 + $1.semesters.reduce(0) { $0 + $1.data.count } }
    }

    // MARK: - Кэш

    private func loadCache() {
        guard let shared = UserDefaults(suiteName: "group.com.schedule.ruz"),
              let json = shared.string(forKey: cacheKey) else { return }
        if let data = json.data(using: .utf8),
           let list = try? JSONDecoder().decode([GradebookYear].self, from: data) {
            self.years = list.sorted { $0.year > $1.year }
            self.rebuildCourses()
            if let timestamp = shared.object(forKey: cacheDateKey) as? TimeInterval {
                self.lastUpdated = Date(timeIntervalSince1970: timestamp)
            }
        }
    }

    func clearCache() {
        let shared = UserDefaults(suiteName: "group.com.schedule.ruz")
        shared?.removeObject(forKey: cacheKey)
        shared?.removeObject(forKey: cacheDateKey)
    }
}

// MARK: - Круг прогресса

private struct ScoreProgressCircle: View {
    let score: Int
    let maxScore: Int
    @State private var animated = false

    private var fraction: Double {
        guard maxScore > 0 else { return 0 }
        return min(Double(score) / Double(maxScore), 1.0)
    }

    private var progressColor: Color {
        let pct = fraction * 100
        if pct >= 85 { return .green }
        if pct >= 70 { return Color(red: 0.2, green: 0.6, blue: 0.9) }
        if pct >= 50 { return .orange }
        return .red
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color(.systemGray5), lineWidth: 8)
            Circle()
                .trim(from: 0, to: animated ? fraction : 0)
                .stroke(progressColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundColor(.primary)
                .contentTransition(.numericText())
        }
        .frame(width: 80, height: 80)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { animated = true }
        }
    }
}

// MARK: - Карточка предмета

private struct SubjectCard: View {
    let row: GradebookRow
    /// Балл за зачёт/экзамен (≤60), НЕ итоговый (itog ≤100).
    private var scoreValue: Int { row.displayExamScore }
    /// Итоговый балл за дисциплину (≤100) — для прогресс-круга.
    private var totalScoreValue: Int { row.totalScore ?? 0 }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.subject ?? "Дисциплина")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.primary)
                    .textCase(.uppercase)
                    .fixedSize(horizontal: false, vertical: true)

                if let v = row.t1?.text {
                    infoRow(label: "ТКУ1", value: v)
                }
                if let v = row.t2?.text {
                    infoRow(label: "ТКУ2", value: v)
                }

                // Экзамен / Зачёт — балл за зачёт/экзамен (≤60), не общий
                infoRow(label: row.controlTypeDisplay, value: "\(scoreValue)")

                // Итоговый балл (≤100) — отдельной строкой
                if totalScoreValue > 0 {
                    infoRow(label: "Итог", value: "\(totalScoreValue)")
                }

                // Оценка прописью
                if row.shouldShowGradeDescription, let desc = row.gradeDescription {
                    Text(desc)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(gradeDescColor)
                }
            }
            Spacer(minLength: 8)
            // Круг прогресса показывает итоговый балл (≤100), не зачёт/экзамен
            ScoreProgressCircle(score: totalScoreValue, maxScore: 100)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            Text("—")
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(0.5))
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
        }
    }

    private var gradeDescColor: Color {
        guard let d = row.gradeDescription?.lowercased() else { return .secondary }
        if d.contains("отлич") { return .green }
        if d.contains("хорош") { return Color(red: 0.2, green: 0.6, blue: 0.9) }
        if d.contains("удовл") { return .orange }
        if d.contains("неудовл") { return .red }
        if d.contains("зачт") { return .green }
        if d.contains("не зачт") { return .red }
        return .secondary
    }
}

// MARK: - Пикеры

private struct CoursePicker: View {
    let courses: [CourseGroup]
    @Binding var selectedCourseId: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(courses) { course in
                    let sel = course.courseNumber == selectedCourseId
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            selectedCourseId = course.courseNumber
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Text("\(course.courseNumber) курс")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(sel ? .white : .primary)
                            Text(course.academicYear)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(sel ? .white.opacity(0.8) : .secondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(sel ? Color.accentColor : Color(.tertiarySystemGroupedBackground))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct SemesterPicker: View {
    let semesters: [GradebookSemester]
    @Binding var selectedSemester: Int

    private var sortedSemesters: [GradebookSemester] {
        semesters.sorted { $0.semester < $1.semester }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(sortedSemesters.enumerated()), id: \.element.id) { index, sem in
                // ВАЖНО: используем ИНДЕКС, а не sem.semester. Если сервер вернул
                // в одном году два семестра с semester=3 и semester=4 (оба чётные/нечётные),
                // индекс всегда даёт 0=осенний, 1=весенний — без дублей в названиях.
                let name = index == 0 ? "Осенний семестр" : "Весенний семестр"
                let sel = sem.semester == selectedSemester
                Button {
                    selectedSemester = sem.semester
                } label: {
                    Text(name)
                        .font(.system(size: 13, weight: sel ? .semibold : .regular))
                        .foregroundColor(sel ? Color.accentColor : .secondary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(sel ? Color.accentColor.opacity(0.12) : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(sel ? Color.accentColor : Color(.separator), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Статистика семестра

private struct SemesterStats: View {
    let semester: GradebookSemester
    let manager: GradebookManager

    private var passedCount: Int {
        semester.data.filter { $0.hasAnyGrade }.count
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                if let avg5 = manager.semesterAverage5(semester) {
                    statItem(value: String(format: "%.2f", avg5), label: "Экзамены (5-балл.)",
                             color: avg5 >= 4.5 ? .green : avg5 >= 3.5 ? Color(red: 0.2, green: 0.6, blue: 0.9) : .orange)
                }
                if let avg100 = manager.semesterAverage100(semester) {
                    statItem(value: String(format: "%.1f", avg100), label: "Все (100-балл.)",
                             color: avg100 >= 85 ? .green : avg100 >= 70 ? Color(red: 0.2, green: 0.6, blue: 0.9) : .orange)
                }
            }
            HStack(spacing: 16) {
                statItem(value: "\(passedCount)/\(semester.data.count)", label: "Сдано",
                         color: passedCount == semester.data.count ? .green : .orange)
                statItem(value: "\(semester.data.count)", label: "Дисциплин", color: .primary)
            }
        }
        .padding(.vertical, 4)
    }

    private func statItem(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Главный экран

struct LKGradebookView: View {
    @StateObject private var manager = GradebookManager()
    @State private var selectedCourseId: Int?
    @State private var selectedSemester: Int = 1

    private var profileId: String { LKManager.shared.session?.profileId ?? "" }

    private var selectedCourse: CourseGroup? {
        if let id = selectedCourseId {
            return manager.courses.first { $0.courseNumber == id }
        }
        return manager.courses.first
    }

    private var selectedSemesterData: GradebookSemester? {
        selectedCourse?.semesters.first { $0.semester == selectedSemester }
    }

    var body: some View { navWrappedContent }

    private var navWrappedContent: some View {
        contentView
            .navigationTitle("Зачётная книжка")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { refreshToolbar }
            .onAppear { handleAppear() }
            .onChange(of: manager.years.count) { _, _ in selectFirstCourseIfNeeded() }
            .onChange(of: selectedCourseId ?? -1) { _, newId in
                if newId >= 0 { handleCourseSelected(newId) }
            }
            .refreshable { await manager.loadGradebook() }
    }

    private var refreshToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { Task { await manager.loadGradebook() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(manager.isLoading)
        }
    }

    private func handleAppear() {
        // Автообновление: если данных нет ИЛИ последнее обновление > 24 часов назад
        let stale = manager.lastUpdated == nil
            || Date().timeIntervalSince(manager.lastUpdated!) > 86400
        if manager.years.isEmpty || stale {
            Task { await manager.loadGradebook() }
        }
        selectFirstCourseIfNeeded()
    }

    private func handleCourseSelected(_ newId: Int) {
        guard let course = manager.courses.first(where: { $0.courseNumber == newId }) else { return }
        if !course.semesters.contains(where: { $0.semester == selectedSemester }) {
            selectedSemester = course.semesters.first?.semester ?? 1
        }
    }

    private func selectFirstCourseIfNeeded() {
        guard selectedCourseId == nil, let first = manager.courses.first else { return }
        selectedCourseId = first.courseNumber
        if let firstSem = first.semesters.first { selectedSemester = firstSem.semester }
    }

    @ViewBuilder
    private var contentView: some View {
        if profileId.isEmpty && manager.years.isEmpty {
            notLoggedInView
        } else if manager.isLoading && manager.years.isEmpty {
            loadingView
        } else if let err = manager.error, manager.years.isEmpty {
            errorView(err)
        } else {
            mainContent
        }
    }

    private var notLoggedInView: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 50)).foregroundColor(.orange)
            Text("Сначала войдите в личный кабинет").font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Загружаем оценки...").font(.subheadline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 44)).foregroundColor(.orange)
            Text(message).font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Попробовать снова") {
                manager.error = nil
                Task { await manager.loadGradebook() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Статус-бар наверху: загрузка / ошибка / дата обновления
                gradebookStatusBar
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                if let avg5 = manager.overallAverage5, let avg100 = manager.overallAverage100 {
                    overallBanner(avg5: avg5, avg100: avg100)
                        .padding(.horizontal, 16).padding(.top, 12)
                }
                if manager.courses.count > 1 {
                    CoursePicker(courses: manager.courses, selectedCourseId: Binding(
                        get: { selectedCourseId ?? manager.courses.first?.courseNumber ?? 1 },
                        set: { selectedCourseId = $0 }
                    )).padding(.top, 12)
                }
                if let course = selectedCourse, course.semesters.count > 1 {
                    SemesterPicker(semesters: course.semesters, selectedSemester: $selectedSemester)
                        .padding(.top, 8)
                }
                if let sem = selectedSemesterData {
                    SemesterStats(semester: sem, manager: manager)
                        .padding(.horizontal, 16).padding(.top, 16)
                    LazyVStack(spacing: 10) {
                        ForEach(sem.data) { row in SubjectCard(row: row) }
                    }
                    .padding(.horizontal, 16).padding(.top, 12)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "book.closed").font(.system(size: 36)).foregroundColor(.secondary)
                        Text("Нет данных для этого семестра").font(.subheadline).foregroundColor(.secondary)
                    }.padding(.top, 48)
                }
            }
            .padding(.bottom, 16)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// Статус-бар наверху: загрузка / ошибка / дата обновления
    @ViewBuilder
    private var gradebookStatusBar: some View {
        if manager.isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Обновление...").font(.caption).foregroundColor(.secondary)
                Spacer()
            }
        } else if let err = manager.error {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.caption)
                Text(err).font(.caption).foregroundColor(.orange)
                Spacer()
            }
        } else if let date = manager.lastUpdated {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption2)
                Text("Обновлено: \(formatDate(date))")
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    private func overallBanner(avg5: Double, avg100: Double) -> some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Экзамены").font(.caption).foregroundColor(.secondary)
                    Text(String(format: "%.2f", avg5))
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundColor(avg5 >= 4.5 ? .green : avg5 >= 3.5 ? Color(red: 0.2, green: 0.6, blue: 0.9) : .orange)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("100-балл.").font(.caption).foregroundColor(.secondary)
                    Text(String(format: "%.1f", avg100))
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundColor(avg100 >= 85 ? .green : avg100 >= 70 ? Color(red: 0.2, green: 0.6, blue: 0.9) : .orange)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Дисциплин").font(.caption).foregroundColor(.secondary)
                    Text("\(manager.totalDisciplines)")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundColor(.primary)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy, HH:mm"
        f.locale = Locale(identifier: "ru_RU")
        return f.string(from: date)
    }
}
