import SwiftUI
import WebKit
import Combine

// MARK: - Модели рейтинга PGAS

struct StudentRatingResponse: Codable {
    let totalCount: Int?
    let page: Int?
    let pageCount: Int?
    let pageSize: Int?
    let items: [StudentRating]
}

struct StudentRating: Codable, Identifiable {
    let id: Int
    let userId: Int?
    let ratingType: String?
    let ratingValue: Double?
    let modifiedAt: Int64?
    let profile: StudentRatingProfile?

    /// Дата изменения в читаемом формате
    var modifiedAtString: String? {
        guard let ts = modifiedAt, ts > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ru_RU")
        fmt.dateFormat = "dd.MM.yyyy"
        return fmt.string(from: date)
    }
}

struct StudentRatingProfile: Codable {
    let userId: Int?
    let fullName: String?
    let firstName: String?
    let lastName: String?
    let middleName: String?
    let phone: String?
    let email: String?
    let photoUrl: String?
    let erasedAt: Int?
}

// MARK: - Семестр

struct RatingSemester: Identifiable, Hashable {
    let code: String   // "spring-2026"
    let title: String  // "Весна 2025/26"
    var id: String { code }
}

// MARK: - Менеджер

@MainActor
final class RatingManager: ObservableObject {
    static let shared = RatingManager()

    @Published var ratings: [StudentRating] = []
    @Published var selectedSemester: RatingSemester
    @Published var isLoading = false
    @Published var error: String? = nil
    @Published var lastUpdated: Date? = nil

    private let cacheKeyPrefix = "cachedRating_"

    /// Список доступных семестров — генерируется от текущего года назад.
    /// Формат кода: "spring-2026" / "autumn-2025".
    /// API возвращает данные только если они реально есть на сервере.
    let availableSemesters: [RatingSemester] = RatingManager.buildSemesters()

    init() {
        // По умолчанию — текущий семестр
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        // Определяем код текущего семестра: осенний (авг–дек / янв) или весенний (фев–июль)
        let currentCode: String
        if month >= 8 || month <= 1 {
            // Осень: если месяц >= 8 — текущий год, иначе прошлый год
            currentCode = "autumn-\(month >= 8 ? year : year - 1)"
        } else {
            currentCode = "spring-\(year)"
        }
        selectedSemester = availableSemesters.first(where: { $0.code == currentCode })
            ?? availableSemesters.first!
        loadCache(for: selectedSemester.code)
    }

    private static func buildSemesters() -> [RatingSemester] {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let year = cal.component(.year, from: now)
        var list: [RatingSemester] = []
        // 4 года назад до текущего семестра
        for y in stride(from: year, through: year - 4, by: -1) {
            list.append(RatingSemester(code: "spring-\(y)", title: "Весна \(y - 1)/\(String(y).suffix(2))"))
            list.append(RatingSemester(code: "autumn-\(y - 1)", title: "Осень \(y - 1)/\(String(y).suffix(2))"))
        }
        return list.sorted { $0.code > $1.code }
    }

    // MARK: - Загрузка

    func loadRating(force: Bool = false) async {
        if isLoading { return }
        if !force, !ratings.isEmpty { return }
        isLoading = true
        error = nil

        let semester = selectedSemester.code
        guard let url = URL(string: "https://lk.fa.ru/services/api/profile/v1/my-student-rating?page=1&pageSize=10&semester=\(semester)&sort=modifiedAt-") else {
            self.error = "Неверный URL"
            self.isLoading = false
            return
        }

        // Получаем cookies fa.ru (для Bearer-запросов нужен либо Bearer, либо cookies).
        // Endpoint lk.fa.ru/services/api/* принимает либо Bearer, либо cookies BFF сессии.
        let cookies = await LKManager.shared.faCookiesPublic()
        guard !cookies.isEmpty else {
            self.error = "Не авторизован. Войдите в личный кабинет."
            self.isLoading = false
            return
        }
        let headerFields = HTTPCookie.requestHeaderFields(with: cookies)

        var request = URLRequest(url: url)
        for (name, value) in headerFields {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://lk.fa.ru/services/ed/rating?page=1&pageSize=10&semester=\(semester)",
                          forHTTPHeaderField: "Referer")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("Europe/Moscow", forHTTPHeaderField: "X-Timezone-IANA")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            print("[Rating] status=\(status), data=\(data.count) bytes, semester=\(semester)")

            guard status == 200 else {
                let bodyPreview = String(data: data, encoding: .utf8)?.prefix(200) ?? "<binary>"
                print("[Rating] error body=\(bodyPreview)")
                self.error = "Ошибка сервера: \(status)"
                self.isLoading = false
                return
            }

            let decoded = try JSONDecoder().decode(StudentRatingResponse.self, from: data)
            self.ratings = decoded.items
            self.lastUpdated = Date()
            self.error = nil

            if let json = String(data: data, encoding: .utf8),
               let shared = UserDefaults(suiteName: "group.com.schedule.ruz") {
                shared.set(json, forKey: cacheKeyPrefix + semester)
                shared.set(Date().timeIntervalSince1970, forKey: cacheKeyPrefix + semester + "_date")
            }
        } catch {
            print("[Rating] decode error: \(error.localizedDescription)")
            self.error = "Не удалось разобрать ответ: \(error.localizedDescription)"
        }
        self.isLoading = false
    }

    /// Переключение семестра — перезагружает данные
    func selectSemester(_ semester: RatingSemester) async {
        selectedSemester = semester
        ratings = []
        loadCache(for: semester.code)
        await loadRating()
    }

    // MARK: - Кэш

    private func loadCache(for semester: String) {
        guard let shared = UserDefaults(suiteName: "group.com.schedule.ruz"),
              let json = shared.string(forKey: cacheKeyPrefix + semester),
              let data = json.data(using: .utf8) else { return }
        if let decoded = try? JSONDecoder().decode(StudentRatingResponse.self, from: data) {
            self.ratings = decoded.items
            if let timestamp = shared.object(forKey: cacheKeyPrefix + semester + "_date") as? TimeInterval {
                self.lastUpdated = Date(timeIntervalSince1970: timestamp)
            }
        }
    }
}

// MARK: - View: раздел рейтинга

struct LKRatingView: View {
    @StateObject private var manager = RatingManager.shared

    var body: some View {
        SwiftUI.Group {
            if manager.isLoading && manager.ratings.isEmpty {
                loadingView
            } else if let error = manager.error {
                errorView(error)
            } else if manager.ratings.isEmpty {
                emptyView
            } else {
                ratingContent
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Рейтинг")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if manager.ratings.isEmpty {
                await manager.loadRating()
            }
        }
        .refreshable {
            await manager.loadRating(force: true)
        }
    }

    // MARK: - Загрузка / ошибка / пусто

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Загрузка рейтинга...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
                Task { await manager.loadRating(force: true) }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "star.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("Нет данных за выбранный семестр")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Попробуйте выбрать другой семестр")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            semesterPicker
                .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - Контент

    private var ratingContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                semesterPicker

                ForEach(manager.ratings) { rating in
                    RatingCard(rating: rating)
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

    // MARK: - Селектор семестра

    private var semesterPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Семестр")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(manager.availableSemesters) { semester in
                        let isSelected = semester.code == manager.selectedSemester.code
                        Button {
                            Task { await manager.selectSemester(semester) }
                        } label: {
                            Text(semester.title)
                                .font(.system(.subheadline, design: .rounded).weight(isSelected ? .bold : .regular))
                                .foregroundStyle(isSelected ? .white : .primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    isSelected ? Color.blue : Color(.secondarySystemBackground),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - Карточка рейтинга

private struct RatingCard: View {
    let rating: StudentRating

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Заголовок: тип рейтинга
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "star.fill")
                    .font(.title3)
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ratingTypeTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let updated = rating.modifiedAtString {
                        Text("Обновлено: \(updated)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Divider()

            // Крупное значение рейтинга
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let value = rating.ratingValue {
                    Text(String(format: "%.2f", value))
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .foregroundStyle(ratingColor(for: value))
                    Text("из 100")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Шкала прогресса
            if let value = rating.ratingValue {
                RatingProgressBar(value: value)
                    .padding(.top, 4)
            }

            // Профиль студента
            if let profile = rating.profile, let fullName = profile.fullName, !fullName.isEmpty {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fullName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        if let email = profile.email, !email.isEmpty {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var ratingTypeTitle: String {
        switch rating.ratingType ?? "" {
        case "PGAS": return "Рейтинг PGAS"
        default: return rating.ratingType ?? "Рейтинг"
        }
    }

    private func ratingColor(for value: Double) -> Color {
        switch value {
        case 90...: return .green
        case 75..<90: return Color(red: 0.2, green: 0.7, blue: 0.3)
        case 60..<75: return .blue
        case 40..<60: return .orange
        default: return .red
        }
    }
}

private struct RatingProgressBar: View {
    let value: Double  // 0...100

    private var fraction: Double {
        max(0, min(value / 100, 1))
    }

    private var color: Color {
        switch value {
        case 90...: return .green
        case 75..<90: return Color(red: 0.2, green: 0.7, blue: 0.3)
        case 60..<75: return .blue
        case 40..<60: return .orange
        default: return .red
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                    .frame(height: 10)
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * fraction, height: 10)
            }
        }
        .frame(height: 10)
    }
}

// MARK: - Подраздел рейтинга внутри LKProfileDetailsView

/// Компактный блок рейтинга для встраивания в раздел профиля.
/// Показывает текущий рейтинг с кнопкой «Подробнее» для перехода в полный раздел.
struct LKRatingCompactView: View {
    @StateObject private var manager = RatingManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                Text("Рейтинг")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                NavigationLink {
                    LKRatingView()
                } label: {
                    Text("Подробнее")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                }
            }

            if manager.isLoading && manager.ratings.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Загрузка...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let first = manager.ratings.first, let value = first.ratingValue {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.2f", value))
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(ratingColor(for: value))
                    Text("из 100")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(manager.selectedSemester.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                RatingProgressBar(value: value)
                    .frame(height: 8)
            } else if let error = manager.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Нет данных")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .task {
            if manager.ratings.isEmpty {
                await manager.loadRating()
            }
        }
    }

    private func ratingColor(for value: Double) -> Color {
        switch value {
        case 90...: return .green
        case 75..<90: return Color(red: 0.2, green: 0.7, blue: 0.3)
        case 60..<75: return .blue
        case 40..<60: return .orange
        default: return .red
        }
    }
}

private struct RatingProgressBar2: View {
    let value: Double
    private var fraction: Double { max(0, min(value / 100, 1)) }
    private var color: Color {
        switch value {
        case 90...: return .green
        case 75..<90: return Color(red: 0.2, green: 0.7, blue: 0.3)
        case 60..<75: return .blue
        case 40..<60: return .orange
        default: return .red
        }
    }
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule().fill(color).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 8)
    }
}
