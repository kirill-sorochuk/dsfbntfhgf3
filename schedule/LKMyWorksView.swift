import SwiftUI
import WebKit
import Combine

// MARK: - Модели: Bootstrap (секции, типы, статусы)

struct VkrBootstrapResponse: Codable {
    let sections: [VkrSection]
    let types: [VkrType]
    let statuses: [VkrStatus]
    let vkr: VkrDocument?
    let myGroups: [JSONNullPlaceholder]?
    let groups: [JSONNullPlaceholder]?
    let vkrManager: Bool?
    let eduGroupUser: Bool?
    let eduGroupUserGroups: [JSONNullPlaceholder]?
    let disciplines: [VkrDiscipline]?
}

struct VkrSection: Codable, Identifiable, Hashable {
    let id: Int
    let title: String
    let code: String        // "KR", "PRACTICE", "VKR", "OTHER"
    let short: String?
    let isActive: Bool?
    let sort: Int?
    let aplQuota: Int?
    let aplQuotaStart: String?
    let aplAspirantQuota: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, code, short, sort
        case isActive = "is_active"
        case aplQuota = "apl_quota"
        case aplQuotaStart = "apl_quota_start"
        case aplAspirantQuota = "apl_aspirant_quota"
    }
}

struct VkrType: Codable {
    let code: String
    let title: String
    let short: String?
    let sort: Int?
    let section: String
    let workType: String?
}

struct VkrStatus: Codable {
    let code: String
    let title: String
    let sort: Int?
    let color: String?
}

struct VkrDiscipline: Codable {
    let eduYear: Int?
    let title: String?
    let rupSectionId: String?
    let rupId: String?
    let discId: String?
    let terms: [Int]?

    enum CodingKeys: String, CodingKey {
        case eduYear = "edu_year"
        case title
        case rupSectionId = "rup_section_id"
        case rupId = "rup_id"
        case discId = "disc_id"
        case terms
    }
}

/// Заглушка для Any-значений в JSON, которые нам не нужны
struct JSONNullPlaceholder: Codable {
    init(from decoder: Decoder) throws { _ = try decoder.singleValueContainer() }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encodeNil() }
}

// MARK: - Модели: Datagrid (список работ)

struct VkrDatagridResponse: Codable {
    let totalCount: Int
    let data: [VkrDocument]
}

struct VkrDocument: Codable, Identifiable, Hashable {
    let id: Int
    let externalId: String?
    let title: String?
    let authorId: Int?
    let authorFio: String?
    let managerId: Int?
    let managerFio: String?
    let eduYear: Int?
    let eduPeriod: Int?
    let section: String?     // "KR", "PRACTICE", "VKR", "OTHER"
    let type: String?
    let discId: String?
    let discTitle: String?
    let rupId: String?
    let rupSectionId: String?
    let result: String?
    let status: String?     // "NEW", "EXECUTION", "APPROVING", "ALLOWED", "COMPLETED"
    let eduGroupId: Int?
    let eduGroupTitle: String?
    let eduDirectionId: Int?
    let eduDirection: String?
    let facultyId: Int?
    let depId: Int?
    let createdAt: String?
    let updatedAt: String?
    let deletedAt: String?
    let filesQty: Int?
    let mark: String?
    let titleEn: String?
    let quotaTotal: Int?
    let quotaUsed: Int?
    let quotaAvail: Int?
    let practiceKind: String?
    let practiceType: String?
    let orgName: String?
    let deletionMark: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case externalId = "external_id"
        case title
        case authorId = "author_id"
        case authorFio = "author_fio"
        case managerId = "manager_id"
        case managerFio = "manager_fio"
        case eduYear = "edu_year"
        case eduPeriod = "edu_period"
        case section, type
        case discId = "disc_id"
        case discTitle = "disc_title"
        case rupId = "rup_id"
        case rupSectionId = "rup_section_id"
        case result, status
        case eduGroupId = "edu_group_id"
        case eduGroupTitle = "edu_group_title"
        case eduDirectionId = "edu_direction_id"
        case eduDirection = "edu_direction"
        case facultyId = "faculty_id"
        case depId = "dep_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case filesQty = "files_qty"
        case mark
        case titleEn = "title_en"
        case quotaTotal = "quota_total"
        case quotaUsed = "quota_used"
        case quotaAvail = "quota_avail"
        case practiceKind = "practice_kind"
        case practiceType = "practice_type"
        case orgName = "org_name"
        case deletionMark = "deletion_mark"
    }

    /// Человекочитаемое название статуса
    var statusTitle: String {
        switch status ?? "" {
        case "NEW": return "Выполняется"
        case "EXECUTION": return "На рассмотрении руководителем"
        case "APPROVING": return "На согласовании"
        case "ALLOWED": return "Допущена к защите"
        case "COMPLETED": return "Завершена"
        default: return status ?? "—"
        }
    }

    /// Цвет бейджа статуса
    var statusColor: Color {
        switch status ?? "" {
        case "NEW": return .blue
        case "EXECUTION": return .orange
        case "APPROVING": return .purple
        case "ALLOWED": return .green
        case "COMPLETED": return .gray
        default: return .secondary
        }
    }

    /// Год обучения в строковом виде
    var eduYearString: String? {
        guard let y = eduYear else { return nil }
        return "\(y)/\(y + 1)"
    }

    /// Дата создания (из ISO)
    var createdAtString: String? {
        guard let s = createdAt else { return nil }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fmt.date(from: s) {
            let out = DateFormatter()
            out.locale = Locale(identifier: "ru_RU")
            out.dateFormat = "dd.MM.yyyy"
            return out.string(from: date)
        }
        return String(s.prefix(10))
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: VkrDocument, rhs: VkrDocument) -> Bool { lhs.id == rhs.id }
}

// MARK: - Модели: детали работы (включая файлы)

struct VkrDocumentDetailResponse: Codable {
    let document: VkrDocumentDetail?
    let author: VkrPerson?
    let manager: VkrPerson?
    let quota: VkrQuota?
}

struct VkrDocumentDetail: Codable, Identifiable {
    let id: Int
    let externalId: String?
    let title: String?
    let authorId: Int?
    let authorFio: String?
    let managerId: Int?
    let managerFio: String?
    let eduYear: Int?
    let eduPeriod: Int?
    let section: String?
    let type: String?
    let discId: String?
    let discTitle: String?
    let status: String?
    let mark: String?
    let createdAt: String?
    let updatedAt: String?
    let vkrdocs: [VkrDoc]?

    enum CodingKeys: String, CodingKey {
        case id
        case externalId = "external_id"
        case title
        case authorId = "author_id"
        case authorFio = "author_fio"
        case managerId = "manager_id"
        case managerFio = "manager_fio"
        case eduYear = "edu_year"
        case eduPeriod = "edu_period"
        case section, type
        case discId = "disc_id"
        case discTitle = "disc_title"
        case status
        case mark
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case vkrdocs
    }
}

struct VkrDoc: Codable, Identifiable {
    let id: Int
    let krType: String?
    let status: String?
    let chState: String?
    let score: Double?
    let plagiarism: Double?
    let legal: Double?
    let allowDefend: Bool?
    let allowDefendAt: String?
    let checkEnd: String?
    let media: [VkrMedia]?

    enum CodingKeys: String, CodingKey {
        case id
        case krType = "krtype"
        case status
        case chState = "chstate"
        case score, plagiarism, legal
        case allowDefend = "allowdefend"
        case allowDefendAt = "allowdefend_at"
        case checkEnd = "check_end"
        case media
    }

    /// Человекочитаемый статус проверки
    var statusTitle: String {
        switch status ?? "" {
        case "Ready": return "Готово"
        case "InProgress": return "Проверяется"
        case "Failed": return "Ошибка"
        default: return status ?? "—"
        }
    }
}

struct VkrMedia: Codable, Identifiable {
    let id: Int
    let name: String?
    let fileName: String?
    let mimeType: String?
    let size: Int?
    let originalUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case fileName = "file_name"
        case mimeType = "mime_type"
        case size
        case originalUrl = "original_url"
    }

    /// Размер в читаемом виде
    var sizeString: String? {
        guard let s = size, s > 0 else { return nil }
        let kb = Double(s) / 1024
        if kb < 1024 {
            return String(format: "%.0f КБ", kb)
        }
        return String(format: "%.1f МБ", kb / 1024)
    }

    /// Полный URL для скачивания
    var fullURL: URL? {
        guard let u = originalUrl else { return nil }
        return URL(string: "https://org.fa.ru\(u)")
    }
}

struct VkrPerson: Codable {
    let profileId: Int?
    let userId: Int?
    let fullname: String?
    let jobTitle: String?
    let role: String?
    let eduGroupId: Int?
    let departmentId: String?
    let photo: VkrPhoto?
    let departmentTitle: String?

    enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case userId = "user_id"
        case fullname
        case jobTitle = "job_title"
        case role
        case eduGroupId = "edu_group_id"
        case departmentId = "department_id"
        case photo
        case departmentTitle = "department_title"
    }
}

struct VkrPhoto: Codable {
    let orig: String?
    let thumbnail: String?
    let small: String?
}

struct VkrQuota: Codable {
    let aplQuota: Int?
    let aplQuotaStart: String?
    let aplQuotaAvailable: Int?
    let aplQuotaUsed: Int?
    let aplQuotaEduYear: Int?

    enum CodingKeys: String, CodingKey {
        case aplQuota = "apl_quota"
        case aplQuotaStart = "apl_quota_start"
        case aplQuotaAvailable = "apl_quota_available"
        case aplQuotaUsed = "apl_quota_used"
        case aplQuotaEduYear = "apl_quota_edu_year"
    }
}

// MARK: - Менеджер

@MainActor
final class VkrManager: ObservableObject {
    static let shared = VkrManager()

    @Published var sections: [VkrSection] = []
    @Published var statuses: [VkrStatus] = []
    @Published var works: [VkrDocument] = []
    @Published var selectedSection: VkrSection? = nil
    @Published var isLoading = false
    @Published var error: String? = nil
    @Published var bootstrapLoaded = false

    private let cacheKey = "cachedVkrBootstrap"
    private let cacheWorksPrefix = "cachedVkrWorks_"

    init() {
        loadBootstrapCache()
    }

    // MARK: - Bootstrap

    func loadBootstrap(force: Bool = false) async {
        if !force, bootstrapLoaded { return }

        let cookies = await LKManager.shared.faCookiesPublic()
        guard !cookies.isEmpty else {
            self.error = "Не авторизован"
            return
        }
        await NativeAuthManager.ensureBitrixSession()
        let orgCookies = cookies.filter { $0.domain.contains("org.fa.ru") }
        let headerFields = HTTPCookie.requestHeaderFields(with: orgCookies)
        let headers = await vkrHeaders(cookies: orgCookies)

        guard let url = URL(string: "https://org.fa.ru/bitrix/vuz/api/vkr/bootstrap") else { return }

        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("https://org.fa.ru/app/vkr/", forHTTPHeaderField: "Referer")
        _ = headerFields  // для future use

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[VKR] bootstrap status=\(status), data=\(data.count) bytes")
            guard status == 200 else {
                let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                print("[VKR] bootstrap error body=\(body)")
                self.error = "Ошибка bootstrap: \(status)"
                return
            }
            let decoded = try JSONDecoder().decode(VkrBootstrapResponse.self, from: data)
            self.sections = decoded.sections.sorted { $0.sort ?? 0 < $1.sort ?? 0 }
            self.statuses = decoded.statuses.sorted { $0.sort ?? 0 < $1.sort ?? 0 }
            self.bootstrapLoaded = true
            self.error = nil
            if self.selectedSection == nil {
                self.selectedSection = self.sections.first
            }
            // Кэш
            if let json = String(data: data, encoding: .utf8),
               let shared = UserDefaults(suiteName: "group.com.schedule.ruz") {
                shared.set(json, forKey: cacheKey)
            }
        } catch {
            print("[VKR] bootstrap decode error: \(error.localizedDescription)")
            self.error = "Не удалось разобрать: \(error.localizedDescription)"
        }
    }

    // MARK: - Список работ по секции

    func loadWorks(for section: VkrSection, force: Bool = false) async {
        if !force, !works.isEmpty, selectedSection?.code == section.code { return }

        let cookies = await LKManager.shared.faCookiesPublic()
        guard !cookies.isEmpty else {
            self.error = "Не авторизован"
            return
        }
        await NativeAuthManager.ensureBitrixSession()
        let orgCookies = cookies.filter { $0.domain.contains("org.fa.ru") }
        let headers = await vkrHeaders(cookies: orgCookies)

        // Из cookies извлекаем profile_id для фильтра author_id
        let profileId = orgCookies.first(where: { $0.name == "BX_ORG_FA_RU_PROFILE_ID" })?.value
        guard let pid = profileId, let pidInt = Int(pid) else {
            self.error = "Нет profile_id в cookies"
            return
        }

        self.selectedSection = section
        self.isLoading = true
        self.error = nil

        guard let url = URL(string: "https://org.fa.ru/bitrix/vuz/api/model_item/datagrid/VkrDocument") else {
            self.isLoading = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("https://org.fa.ru/app/vkr/list/\(section.code)", forHTTPHeaderField: "Referer")
        request.setValue("https://org.fa.ru", forHTTPHeaderField: "Origin")

        // Тело запроса — формат DevExtreme datagrid filter
        // Включаем фильтр: section=SECTION AND author_id=PID AND deletion_mark=0
        let bodyDict: [String: Any] = [
            "filter": [
                ["deletion_mark", "=", 0],
                "and",
                [
                    ["section", "=", section.code],
                    "and",
                    ["author_id", "=", pidInt]
                ]
            ],
            "requireTotalCount": true,
            "searchOperation": "contains",
            "searchValue": NSNull(),
            "skip": 0,
            "take": 50,
            "userData": [:],
            "sort": [["selector": "id", "desc": true]],
            "group": NSNull()
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        } catch {
            print("[VKR] body encode error: \(error)")
            self.isLoading = false
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[VKR] works status=\(status), section=\(section.code), data=\(data.count) bytes")
            guard status == 200 else {
                let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                print("[VKR] works error body=\(body)")
                self.error = "Ошибка: \(status)"
                self.isLoading = false
                return
            }
            let decoded = try JSONDecoder().decode(VkrDatagridResponse.self, from: data)
            self.works = decoded.data
            self.error = nil
            if let json = String(data: data, encoding: .utf8),
               let shared = UserDefaults(suiteName: "group.com.schedule.ruz") {
                shared.set(json, forKey: cacheWorksPrefix + section.code)
            }
        } catch {
            print("[VKR] works decode error: \(error.localizedDescription)")
            self.error = "Не удалось разобрать: \(error.localizedDescription)"
        }
        self.isLoading = false
    }

    // MARK: - Детали работы

    func loadDocumentDetail(id: Int) async -> VkrDocumentDetailResponse? {
        let cookies = await LKManager.shared.faCookiesPublic()
        guard !cookies.isEmpty else { return nil }
        await NativeAuthManager.ensureBitrixSession()
        let orgCookies = cookies.filter { $0.domain.contains("org.fa.ru") }
        let headers = await vkrHeaders(cookies: orgCookies)

        guard let url = URL(string: "https://org.fa.ru/bitrix/vuz/api/vkr/document/\(id)/detail/") else {
            return nil
        }

        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("https://org.fa.ru/app/vkr/list/\(selectedSection?.code ?? "KR")?id=\(id)", forHTTPHeaderField: "Referer")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[VKR] detail status=\(status), id=\(id), data=\(data.count) bytes")
            guard status == 200 else {
                let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                print("[VKR] detail error body=\(body)")
                return nil
            }
            return try JSONDecoder().decode(VkrDocumentDetailResponse.self, from: data)
        } catch {
            print("[VKR] detail decode error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Заголовки

    /// Заголовки для org.fa.ru API (Bitrix SSO cookies + App-* headers).
    /// Используем ТОЛЬКО cookies домена org.fa.ru.
    private func vkrHeaders(cookies: [HTTPCookie]) async -> [String: String] {
        let orgCookies = cookies.filter { $0.domain.contains("org.fa.ru") }
        var headers = HTTPCookie.requestHeaderFields(with: orgCookies)
        headers["App-Version"] = "8.135.3"
        headers["App-Key"] = "browser-bitrix"
        headers["App-Locale"] = "ru"
        headers["App-TimezoneOffset"] = "-180"
        headers["Accept"] = "application/json"
        return headers
    }

    // MARK: - Кэш

    private func loadBootstrapCache() {
        guard let shared = UserDefaults(suiteName: "group.com.schedule.ruz"),
              let json = shared.string(forKey: cacheKey),
              let data = json.data(using: .utf8) else { return }
        if let decoded = try? JSONDecoder().decode(VkrBootstrapResponse.self, from: data) {
            self.sections = decoded.sections.sorted { $0.sort ?? 0 < $1.sort ?? 0 }
            self.statuses = decoded.statuses.sorted { $0.sort ?? 0 < $1.sort ?? 0 }
            self.bootstrapLoaded = true
            self.selectedSection = self.sections.first
        }
    }

    func loadWorksCache(for section: String) -> [VkrDocument] {
        guard let shared = UserDefaults(suiteName: "group.com.schedule.ruz"),
              let json = shared.string(forKey: cacheWorksPrefix + section),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(VkrDatagridResponse.self, from: data) else {
            return []
        }
        return decoded.data
    }
}

// MARK: - View: список работ

struct LKMyWorksView: View {
    @StateObject private var manager = VkrManager.shared
    @State private var hasLoadedInitial = false

    var body: some View {
        SwiftUI.Group {
            if manager.sections.isEmpty {
                loadingView
            } else {
                content
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Мои работы")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if !manager.bootstrapLoaded {
                await manager.loadBootstrap()
                if let section = manager.selectedSection {
                    await manager.loadWorks(for: section)
                }
                hasLoadedInitial = true
            }
        }
        .refreshable {
            await manager.loadBootstrap(force: true)
            if let section = manager.selectedSection {
                await manager.loadWorks(for: section, force: true)
            }
        }
    }

    // MARK: - Загрузка

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Загрузка работ...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Контент

    private var content: some View {
        VStack(spacing: 0) {
            // Селектор секций (KR, PRACTICE, VKR, OTHER)
            sectionPicker
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            if manager.isLoading && manager.works.isEmpty {
                Spacer()
                ProgressView()
                Text("Загрузка...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else if let error = manager.error {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange.opacity(0.7))
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Повторить") {
                        Task {
                            await manager.loadBootstrap(force: true)
                            if let section = manager.selectedSection {
                                await manager.loadWorks(for: section, force: true)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 32)
                Spacer()
            } else if manager.works.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("Нет работ в этом разделе")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(manager.works) { work in
                            NavigationLink {
                                LKMyWorkDetailView(workId: work.id, work: work)
                            } label: {
                                VkrWorkCard(work: work)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    // MARK: - Селектор секций

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(manager.sections) { section in
                    let isSelected = manager.selectedSection?.code == section.code
                    Button {
                        Task { await manager.loadWorks(for: section) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: sectionIcon(for: section.code))
                                .font(.system(size: 13, weight: .medium))
                            Text(sectionTitle(for: section.code))
                                .font(.system(.subheadline, design: .rounded).weight(isSelected ? .bold : .medium))
                        }
                        .foregroundStyle(isSelected ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            isSelected ? Color.accentColor : Color(.secondarySystemBackground),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sectionIcon(for code: String) -> String {
        switch code {
        case "KR": return "doc.text.fill"
        case "PRACTICE": return "briefcase.fill"
        case "VKR": return "graduationcap.fill"
        case "OTHER": return "square.stack.fill"
        default: return "doc.fill"
        }
    }

    private func sectionTitle(for code: String) -> String {
        switch code {
        case "KR": return "Курсовые"
        case "PRACTICE": return "Практики"
        case "VKR": return "ВКР"
        case "OTHER": return "Другие"
        default: return code
        }
    }
}

// MARK: - Карточка работы (формат "как в расписании")

private struct VkrWorkCard: View {
    let work: VkrDocument
    @AppStorage("accentColor") private var accentRaw = "faTeal"
    private var accent: Color { AccentColors.color(accentRaw) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Левая колонка: иконка секции + статус-бейдж снизу
            VStack(spacing: 6) {
                Image(systemName: sectionIcon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(accent)
                    .frame(width: 44, height: 44)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                Spacer(minLength: 4)

                // Бейдж статуса (мини)
                Text(work.statusTitle)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(work.statusColor, in: Capsule())
                    .frame(maxWidth: 60)
            }
            .frame(width: 54)

            // Правая колонка: заголовок + мета-данные
            VStack(alignment: .leading, spacing: 6) {
                Text(work.title ?? "Без названия")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let date = work.createdAtString {
                    Label(date, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let disc = work.discTitle, !disc.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "book.fill")
                            .font(.system(size: 11))
                            .foregroundColor(accent)
                        Text(disc)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                if let mgr = work.managerFio, !mgr.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 11))
                            .foregroundColor(accent)
                        Text("Руководитель: \(mgr)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // Оценка + год + файлы
                HStack(spacing: 12) {
                    if let mark = work.mark, !mark.isEmpty {
                        Label(mark, systemImage: "star.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.yellow)
                    }
                    if let files = work.filesQty, files > 0 {
                        Label("\(files)", systemImage: "doc.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var sectionIcon: String {
        switch work.section ?? "" {
        case "KR": return "doc.text.fill"
        case "PRACTICE": return "briefcase.fill"
        case "VKR": return "graduationcap.fill"
        case "OTHER": return "square.stack.fill"
        default: return "doc.fill"
        }
    }
}

// MARK: - Детальный просмотр работы

struct LKMyWorkDetailView: View {
    let workId: Int
    let work: VkrDocument
    @StateObject private var manager = VkrManager.shared
    @State private var detail: VkrDocumentDetailResponse? = nil
    @State private var isLoading = false
    @State private var selectedMediaURL: URL? = nil
    @State private var selectedMediaName: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Заголовок работы
                headerCard

                // Основная информация
                infoCard

                // Руководитель
                if let mgr = detail?.manager, mgr.fullname != nil {
                    managerCard(mgr)
                }

                // Файлы (документы на проверку)
                if let vkrdocs = detail?.document?.vkrdocs {
                    ForEach(vkrdocs) { vkrdoc in
                        filesCard(vkrdoc)
                    }
                }

                if detail == nil && isLoading {
                    ProgressView()
                        .padding()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Работа")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if detail == nil {
                isLoading = true
                detail = await manager.loadDocumentDetail(id: workId)
                isLoading = false
            }
        }
        .sheet(isPresented: Binding(
            get: { selectedMediaURL != nil },
            set: { if !$0 { selectedMediaURL = nil; selectedMediaName = nil } }
        )) {
            if let url = selectedMediaURL {
                NavigationStack {
                    VkrFileViewer(url: url, fileName: selectedMediaName)
                }
                #if os(iOS)
                .presentationDetents([.large])
                #endif
            }
        }
    }

    // MARK: - Заголовок

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .font(.title2)
                    .foregroundStyle(.purple)
                Text(work.title ?? "Без названия")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            HStack(spacing: 8) {
                Text(work.statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(work.statusColor, in: Capsule())
                if let mark = work.mark, !mark.isEmpty {
                    Label(mark, systemImage: "star.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.yellow)
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Информация

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Информация")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Divider()
            if let disc = work.discTitle, !disc.isEmpty {
                row(label: "Дисциплина", value: disc)
            }
            if let dir = work.eduDirection, !dir.isEmpty {
                row(label: "Направление", value: dir)
            }
            if let group = work.eduGroupTitle, !group.isEmpty {
                row(label: "Группа", value: group)
            }
            if let year = work.eduYearString {
                row(label: "Учебный год", value: year)
            }
            if let period = work.eduPeriod {
                row(label: "Семестр", value: "\(period)")
            }
            if let date = work.createdAtString {
                row(label: "Создано", value: date)
            }
            if let files = work.filesQty {
                row(label: "Файлов", value: "\(files)")
            }
            if let avail = work.quotaAvail, let total = work.quotaTotal {
                row(label: "Квота", value: "\(avail) из \(total) доступно")
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Руководитель

    private func managerCard(_ mgr: VkrPerson) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Руководитель")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 12) {
                if let photo = mgr.photo?.small, let url = URL(string: "https://org.fa.ru\(photo)") {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            ZStack {
                                Circle().fill(Color(.tertiarySystemFill))
                                Image(systemName: "person.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                } else {
                    ZStack {
                        Circle().fill(Color(.tertiarySystemFill))
                            .frame(width: 44, height: 44)
                        Image(systemName: "person.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(mgr.fullname ?? "—")
                        .font(.body.weight(.medium))
                    if let title = mgr.jobTitle, !title.isEmpty {
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Файлы (всплывающее окно при тапе)

    private func filesCard(_ vkrdoc: VkrDoc) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "doc.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Документ на проверку")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(vkrdoc.statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(vkrdoc.status == "Ready" ? Color.green : Color.orange, in: Capsule())
            }
            Divider()
            // Результаты проверки
            if let score = vkrdoc.score {
                HStack(spacing: 12) {
                    scoreView(label: "Оригинальность", value: String(format: "%.2f%%", score), color: score >= 70 ? .green : (score >= 40 ? .orange : .red))
                    if let plag = vkrdoc.plagiarism {
                        scoreView(label: "Заимствования", value: String(format: "%.2f%%", plag), color: .red)
                    }
                    if let legal = vkrdoc.legal, legal > 0 {
                        scoreView(label: "Цитирование", value: String(format: "%.2f%%", legal), color: .blue)
                    }
                }
            }
            if let chState = vkrdoc.chState, !chState.isEmpty {
                Label(chState, systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let allowDefend = vkrdoc.allowDefend, allowDefend {
                Label("Допущена к защите", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
            // Файлы — при тапе открывают sheet с QuickLook (не Safari)
            if let media = vkrdoc.media, !media.isEmpty {
                Divider()
                Text("Файлы")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(media) { m in
                    Button {
                        // Устанавливаем выбранный файл для показа в sheet
                        selectedMediaURL = m.fullURL
                        selectedMediaName = m.name
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: fileIcon(for: m.mimeType))
                                .font(.body)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name ?? "Файл")
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if let size = m.sizeString {
                                    Text(size)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func scoreView(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .center, spacing: 4) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Хелперы

    private func row(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fileIcon(for mime: String?) -> String {
        switch mime ?? "" {
        case let m where m.contains("pdf"): return "doc.richtext.fill"
        case let m where m.contains("word") || m.contains("docx"): return "doc.text.fill"
        case let m where m.contains("image"): return "photo.fill"
        case let m where m.contains("zip"): return "doc.zipper"
        default: return "doc.fill"
        }
    }
}

// MARK: - Просмотр файла (QuickLook) с кнопкой «Поделиться»

/// Скачивает файл с org.fa.ru (используя Bitrix SSO cookies) и показывает через QuickLook.
/// Кнопка «Поделиться» в тулбаре шарит локальный файл через ShareLink.
struct VkrFileViewer: View {
    let url: URL
    let fileName: String?
    @Environment(\.dismiss) private var dismiss
    @State private var localFileURL: URL? = nil
    @State private var isLoading = true
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack {
            if isLoading {
                Spacer()
                ProgressView("Загрузка файла...")
                    .font(.subheadline)
                Spacer()
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange.opacity(0.7))
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Spacer()
            } else if let fileURL = localFileURL {
                QuickLookView(url: fileURL)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle(fileName ?? "Файл")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Готово") { dismiss() }
            }
            if let fileURL = localFileURL {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: fileURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task {
            await downloadFile()
        }
    }

    /// Скачивает файл с org.fa.ru, подставляя Bitrix SSO cookies.
    private func downloadFile() async {
        isLoading = true
        errorMessage = nil

        // Получаем cookies домена org.fa.ru
        let cookies = await LKManager.shared.faCookiesPublic()
        guard !cookies.isEmpty else {
            errorMessage = "Не авторизован"
            isLoading = false
            return
        }
        await NativeAuthManager.ensureBitrixSession()
        let orgCookies = cookies.filter { $0.domain.contains("org.fa.ru") }
        let headerFields = HTTPCookie.requestHeaderFields(with: orgCookies)

        var request = URLRequest(url: url)
        for (name, value) in headerFields {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("https://org.fa.ru/app/vkr/", forHTTPHeaderField: "Referer")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[VKR] file download status=\(status), size=\(data.count) bytes")
            guard status == 200 else {
                errorMessage = "Ошибка загрузки: \(status)"
                isLoading = false
                return
            }
            // Сохраняем во временный файл
            let tempDir = FileManager.default.temporaryDirectory
            let safeName = fileName?.replacingOccurrences(of: "/", with: "_") ?? "file"
            let fileURL = tempDir.appendingPathComponent(safeName)
            try data.write(to: fileURL)
            self.localFileURL = fileURL
            isLoading = false
        } catch {
            print("[VKR] file download error: \(error)")
            errorMessage = "Не удалось загрузить: \(error.localizedDescription)"
            isLoading = false
        }
    }
}

// MARK: - QuickLook wrapper (UIKit)

import QuickLook

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
