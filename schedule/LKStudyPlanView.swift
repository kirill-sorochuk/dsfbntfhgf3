import SwiftUI
import WebKit
import Combine

// MARK: - Модели учебного плана

struct StudyPlanResponse: Codable {
    let meta: StudyPlanMeta
    let data: StudyPlanInfo
    let academicDisciplines: [StudyPlanYear]
}

struct StudyPlanMeta: Codable {
    let status: String?
    let code: Int?
}

struct StudyPlanInfo: Codable {
    let nrec: Int?
    let name: String?
    let regnum: String?
    let curType: String?
    let startYear: Int?
    let edulevel: String?
    let studyformName: String?
    let specialityCode: String?
    let specialityName: String?
    let departmentName: String?
    let curStatus: String?
    let eduProgName: String?
}

struct StudyPlanYear: Codable {
    let studyYear: Int
    let academicPeriods: [[StudyPlanDiscipline]]
}

struct StudyPlanDiscipline: Codable, Identifiable {
    let disId: Int?
    let disciplineLevel: String?
    let name: String?
    let allHours: Int?
    let lectures: Int?
    let laboratoryWorkTime: Int?
    let practicalWorkTime: Int?
    let independentWorkTime: Int?
    let controlType: String?
    let controlForm: [String]?
    let teachers: [String]?

    /// Идентификатор для Identifiable (для .sheet(item:)).
    /// Если disId есть — используем его, иначе — хеш от name.
    var id: String {
        if let did = disId { return "disc-\(did)" }
        return "disc-\(name?.hashValue ?? 0)"
    }
}

// MARK: - Расширения моделей

extension StudyPlanYear {
    /// Возвращает индекс курса (1, 2, 3...) относительно первого года в плане.
    static func courseNumber(for year: Int, in years: [StudyPlanYear]) -> Int {
        guard let minYear = years.map(\.studyYear).min() else { return 1 }
        return year - minYear + 1
    }

    /// Строка академического года, например "2024/2025".
    var academicYearString: String {
        "\(studyYear)/\(studyYear + 1)"
    }

    /// Суммарное количество дисциплин за год (по всем семестрам).
    var totalDisciplines: Int {
        academicPeriods.reduce(0) { $0 + $1.count }
    }

    /// Суммарное количество часов за год.
    var totalHours: Int {
        academicPeriods.flatMap { $0 }.compactMap(\.allHours).reduce(0, +)
    }
}

extension StudyPlanDiscipline {
    /// Форма контроля одной строкой ("Экзамен", "Зачёт" и т.д.).
    var controlFormString: String {
        (controlForm ?? []).joined(separator: ", ")
    }

    /// Список преподавателей одной строкой (через запятую).
    var teachersString: String {
        (teachers ?? []).joined(separator: ", ")
    }

    /// Цвет бейджа формы контроля.
    var controlFormColor: Color {
        let s = controlFormString.lowercased()
        if s.contains("экзамен") { return .red }
        if s.contains("зачёт") || s.contains("зачет") { return .blue }
        if s.contains("курсов") { return .purple }
        return .secondary
    }
}

// MARK: - Менеджер

@MainActor
final class StudyPlanManager: ObservableObject {
    static let shared = StudyPlanManager()

    @Published var plan: StudyPlanResponse? = nil
    @Published var isLoading = false
    @Published var error: String? = nil
    @Published var lastUpdated: Date? = nil

    private let cacheKey = "cachedStudyPlan"
    private let cacheDateKey = "cachedStudyPlanDate"

    init() {
        loadCache()
    }

    // MARK: - Загрузка с сервера

    func loadStudyPlan(force: Bool = false) async {
        if isLoading { return }
        if !force, plan != nil { return }
        isLoading = true
        error = nil

        // Endpoint: https://lk.fa.ru/elk/api/study-plans/student
        // Использует NextAuth session cookies (НЕ Bitrix SSO).
        let cookies = await LKManager.shared.faCookiesPublic()
        guard !cookies.isEmpty else {
            self.error = "Не авторизован. Войдите в личный кабинет."
            self.isLoading = false
            return
        }

        let headerFields = HTTPCookie.requestHeaderFields(with: cookies)
        guard let url = URL(string: "https://lk.fa.ru/elk/api/study-plans/student") else {
            self.error = "Неверный URL"
            self.isLoading = false
            return
        }

        var request = URLRequest(url: url)
        for (name, value) in headerFields {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://lk.fa.ru/elk/study-plans", forHTTPHeaderField: "Referer")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            print("[StudyPlan] status=\(status), data=\(data.count) bytes")

            guard status == 200 else {
                let bodyPreview = String(data: data, encoding: .utf8)?.prefix(200) ?? "<binary>"
                print("[StudyPlan] error body=\(bodyPreview)")
                self.error = "Ошибка сервера: \(status)"
                self.isLoading = false
                return
            }

            let decoded = try JSONDecoder().decode(StudyPlanResponse.self, from: data)
            self.plan = decoded
            self.lastUpdated = Date()
            self.error = nil

            // Кэш
            if let json = String(data: data, encoding: .utf8),
               let shared = UserDefaults(suiteName: "group.com.schedule.ruz") {
                shared.set(json, forKey: cacheKey)
                shared.set(Date().timeIntervalSince1970, forKey: cacheDateKey)
            }
        } catch {
            print("[StudyPlan] decode error: \(error.localizedDescription)")
            self.error = "Не удалось разобрать ответ: \(error.localizedDescription)"
        }
        self.isLoading = false
    }

    // MARK: - Кэш

    private func loadCache() {
        guard let shared = UserDefaults(suiteName: "group.com.schedule.ruz"),
              let json = shared.string(forKey: cacheKey),
              let data = json.data(using: .utf8) else { return }
        if let decoded = try? JSONDecoder().decode(StudyPlanResponse.self, from: data) {
            self.plan = decoded
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

// MARK: - View: Учебный план

struct LKStudyPlanView: View {
    @StateObject private var manager = StudyPlanManager.shared

    var body: some View {
        SwiftUI.Group {
            if manager.isLoading && manager.plan == nil {
                loadingView
            } else if let plan = manager.plan {
                planContent(plan)
            } else if let error = manager.error {
                errorView(error)
            } else {
                placeholderView
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Учебный план")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if manager.plan == nil {
                await manager.loadStudyPlan()
            }
        }
        .refreshable {
            await manager.loadStudyPlan(force: true)
        }
        .sheet(item: $selectedDiscipline) { disc in
            NavigationStack {
                StudyPlanDisciplineDetailView(discipline: disc)
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #endif
        }
    }

    // MARK: - Загрузка

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Загрузка учебного плана...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            Spacer()
            Button {
                Task { await manager.loadStudyPlan() }
            } label: {
                VStack(spacing: 12) {
                    Image(systemName: "book.text.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("Загрузить учебный план")
                        .font(.headline)
                        .foregroundStyle(.blue)
                }
            }
            Spacer()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange.opacity(0.7))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Повторить") {
                Task { await manager.loadStudyPlan(force: true) }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    // MARK: - Контент

    private func planContent(_ plan: StudyPlanResponse) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                // Карточка с информацией о программе
                if !plan.data.specialityName.isNilOrEmpty {
                    infoCard(plan.data, years: plan.academicDisciplines)
                }

                // Список лет/семестров
                ForEach(plan.academicDisciplines, id: \.studyYear) { yearData in
                    yearSection(yearData, allYears: plan.academicDisciplines)
                }

                if let updated = manager.lastUpdated {
                    Text("Обновлено: \(updated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 24)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    // MARK: - Карточка программы

    private func infoCard(_ info: StudyPlanInfo, years: [StudyPlanYear]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Код + название специальности
            HStack(alignment: .top, spacing: 8) {
                if let code = info.specialityCode, !code.isEmpty {
                    Text(code)
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.orange, in: Capsule())
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let name = info.specialityName, !name.isEmpty {
                        Text(name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                    if let prog = info.eduProgName, !prog.isEmpty, prog != info.specialityName {
                        Text(prog)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            // Свойства программы
            infoRow(label: "Уровень", value: info.edulevel)
            if let form = info.studyformName, !form.isEmpty {
                infoRow(label: "Форма обучения", value: form)
            }
            if let dept = info.departmentName, !dept.isEmpty {
                infoRow(label: "Факультет", value: dept)
            }
            if let year = info.startYear {
                infoRow(label: "Год начала", value: "\(year)")
            }
            if let status = info.curStatus, !status.isEmpty {
                infoRow(label: "Статус", value: status)
            }
            if let regnum = info.regnum, !regnum.isEmpty {
                infoRow(label: "Рег. номер", value: regnum)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func infoRow(label: String, value: String?) -> some View {
        guard let value, !value.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
    }

    // MARK: - Год (раскрываемый)

    @State private var expandedYears: Set<Int> = []
    @State private var expandedSemesters: Set<String> = []  // key: "year-semesterIdx"
    @State private var selectedDiscipline: StudyPlanDiscipline? = nil

    /// Возвращает номер текущего курса на основе текущей даты и года начала обучения.
    /// Например: сентябрь 2026, начало 2024 → курс 3.
    private func currentCourseNumber(allYears: [StudyPlanYear]) -> Int {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        // Учебный год начинается в сентябре. Если сейчас январь–август —
        // это вторая половина учебного года (осенний семестр прошлого).
        let startYear: Int
        if let first = allYears.map(\.studyYear).min() {
            startYear = first
        } else {
            return 1
        }
        // Текущий учебный год: с сентября этого года по август следующего
        let currentEduYear = month >= 9 ? year : year - 1
        let course = currentEduYear - startYear + 1
        return max(1, course)
    }

    private func yearSection(_ yearData: StudyPlanYear, allYears: [StudyPlanYear]) -> some View {
        let courseNum = StudyPlanYear.courseNumber(for: yearData.studyYear, in: allYears)
        let isExpanded = expandedYears.contains(yearData.studyYear)
        let isCurrent = courseNum == currentCourseNumber(allYears: allYears)

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    if isExpanded {
                        expandedYears.remove(yearData.studyYear)
                    } else {
                        expandedYears.insert(yearData.studyYear)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(isCurrent ? Color.accentColor.opacity(0.18) : Color.orange.opacity(0.15))
                            .frame(width: 44, height: 44)
                        Text("\(courseNum)")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .foregroundStyle(isCurrent ? Color.accentColor : .orange)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("\(courseNum) курс")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            if isCurrent {
                                Text("текущий")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor, in: Capsule())
                            }
                        }
                        Text("\(yearData.academicYearString) · \(yearData.totalDisciplines) дисциплин · \(yearData.totalHours) ч")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.leading, 16)
                ForEach(Array(yearData.academicPeriods.enumerated()), id: \.offset) { idx, semester in
                    semesterSection(semester, semesterNum: idx + 1, yearId: yearData.studyYear)
                }
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .onAppear {
            // По умолчанию раскрываем только текущий курс
            if expandedYears.isEmpty, isCurrent {
                expandedYears.insert(yearData.studyYear)
                // И текущий семестр
                let currentSemesterIdx = currentSemesterIndex()
                if currentSemesterIdx >= 0, yearData.academicPeriods.indices.contains(currentSemesterIdx) {
                    expandedSemesters.insert("\(yearData.studyYear)-\(currentSemesterIdx + 1)")
                }
            }
        }
    }

    /// Возвращает индекс текущего семестра (0=осенний, 1=весенний) на основе месяца.
    private func currentSemesterIndex() -> Int {
        let cal = Calendar(identifier: .gregorian)
        let month = cal.component(.month, from: Date())
        // Сентябрь–январь → осенний (idx=0), февраль–август → весенний (idx=1)
        return (month >= 9 || month <= 1) ? 0 : 1
    }

    // MARK: - Семестр (раскрываемый)

    private func semesterSection(_ disciplines: [StudyPlanDiscipline], semesterNum: Int, yearId: Int) -> some View {
        let key = "\(yearId)-\(semesterNum)"
        let isExpanded = expandedSemesters.contains(key)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    if isExpanded {
                        expandedSemesters.remove(key)
                    } else {
                        expandedSemesters.insert(key)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(semesterNum == 1 ? "Осенний семестр" : "Весенний семестр")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(disciplines.count) дисциплин")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(Array(disciplines.enumerated()), id: \.offset) { _, disc in
                    Button {
                        selectedDiscipline = disc
                    } label: {
                        disciplineRow(disc)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Дисциплина (краткая карточка в списке)

    private func disciplineRow(_ disc: StudyPlanDiscipline) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Название + форма контроля
            HStack(alignment: .top, spacing: 8) {
                Text(disc.name ?? "Дисциплина")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !disc.controlFormString.isEmpty {
                    Text(disc.controlFormString)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(disc.controlFormColor, in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            // Уровень дисциплины (Б.1.1.1.1)
            if let level = disc.disciplineLevel, !level.isEmpty {
                Text(level)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Часы (кратко — только общее количество)
            if let total = disc.allHours, total > 0 {
                Label("\(total) ч", systemImage: "clock")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func hoursRow(_ disc: StudyPlanDiscipline, total: Int) -> some View {
        HStack(spacing: 12) {
            Label("\(total)", systemImage: "clock")
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)

            if let lec = disc.lectures, lec > 0 {
                pill("Лек \(lec)", color: .blue)
            }
            if let prac = disc.practicalWorkTime, prac > 0 {
                pill("Прак \(prac)", color: .green)
            }
            if let lab = disc.laboratoryWorkTime, lab > 0 {
                pill("Лаб \(lab)", color: .purple)
            }
            if let selfStudy = disc.independentWorkTime, selfStudy > 0 {
                pill("СРС \(selfStudy)", color: .orange)
            }
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(.caption2, design: .rounded).weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Helpers

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        self?.isEmpty ?? true
    }
}

// MARK: - Детали дисциплины (sheet)

struct StudyPlanDisciplineDetailView: View {
    let discipline: StudyPlanDiscipline
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Заголовок: название + форма контроля
                headerCard
                // Часы
                hoursCard
                // Преподаватели
                if !discipline.teachersString.isEmpty {
                    teachersCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Дисциплина")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Готово") { dismiss() }
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(discipline.name ?? "Дисциплина")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            HStack(spacing: 8) {
                if !discipline.controlFormString.isEmpty {
                    Text(discipline.controlFormString)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(discipline.controlFormColor, in: Capsule())
                }
                if let level = discipline.disciplineLevel, !level.isEmpty {
                    Text(level)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let ct = discipline.controlType, !ct.isEmpty {
                Text("Тип: \(ct)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var hoursCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Часы")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Divider()
            if let total = discipline.allHours, total > 0 {
                row(label: "Всего", value: "\(total) ч", highlight: true)
            }
            if let lec = discipline.lectures, lec > 0 {
                row(label: "Лекции", value: "\(lec) ч")
            }
            if let prac = discipline.practicalWorkTime, prac > 0 {
                row(label: "Практические", value: "\(prac) ч")
            }
            if let lab = discipline.laboratoryWorkTime, lab > 0 {
                row(label: "Лабораторные", value: "\(lab) ч")
            }
            if let selfStudy = discipline.independentWorkTime, selfStudy > 0 {
                row(label: "Самостоятельная работа", value: "\(selfStudy) ч")
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var teachersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Преподаватели")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Divider()
            ForEach(discipline.teachers ?? [], id: \.self) { teacher in
                HStack(spacing: 8) {
                    Image(systemName: "person.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(teacher)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func row(label: String, value: String, highlight: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(highlight ? .bold : .medium))
                .foregroundStyle(highlight ? Color.accentColor : .primary)
        }
    }
}
