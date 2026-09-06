import Foundation
import WebKit
import SwiftUI
import Combine

// MARK: - Модели сессии

struct LKUser: Codable {
    let name: String?
    let email: String?
    let image: String?
}

struct LKExtendedUserData: Codable {
    let login: String?
    let email: String?
    let shortName: String?
    let firstName: String?
    let middleName: String?
    let lastName: String?
    let preferredLanguage: String?
    let avatarUrl: String?
    let id: String?
    let group: String?
}

struct LKSession: Codable {
    let user: LKUser?
    let expires: String?
    let extendedUserData: LKExtendedUserData?
    let userId: String?

    var fullName: String? {
        if let f = extendedUserData?.firstName,
           let m = extendedUserData?.middleName,
           let l = extendedUserData?.lastName {
            return "\(l) \(f) \(m)"
        }
        return user?.name
    }

    var avatarURL: URL? {
        let path = extendedUserData?.avatarUrl ?? user?.image
        guard let path = path else { return nil }
        if path.hasPrefix("http") {
            return URL(string: path)
        } else {
            return URL(string: "https://lk.fa.ru" + path)
        }
    }

    var profileId: String {
        return userId ?? extendedUserData?.id ?? ""
    }

    var studentGroup: String? {
        extendedUserData?.group
    }

    /// Истекла ли сессия.
    /// Сервер lk.fa.ru возвращает expires в формате ISO 8601.
    /// Проверяем с запасом 60 секунд, чтобы избежать ложного «устарела».
    var isExpired: Bool {
        guard let exp = expires else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: exp) {
            return date.addingTimeInterval(60) < Date()
        }
        // Fallback: без дробных секунд
        formatter.formatOptions = [.withInternetDateTime]
        if let date2 = formatter.date(from: exp) {
            return date2.addingTimeInterval(60) < Date()
        }
        return false
    }
}

// MARK: - Данные из org.fa.ru (профиль, приказы)

struct BitrixProfile: Codable {
    let id: Int?
    let eduForm: String?
    let eduMarkBookNum: String?
    let eduStatus: String?
    let eduCourse: Int?
    let eduLevel: String?
    let eduGroup: BitrixNamedEntity?
    let faculty: BitrixNamedEntity?
    let eduDirection: BitrixNamedEntity?
    let eduSpecialization: BitrixNamedEntity?
    let eduQualification: BitrixNamedEntity?
    let user: BitrixUser?
    let phone: String?
    let mobile: String?
    let personalEmail: String?
    let personalMobile: String?
    let birthdate: String?

    enum CodingKeys: String, CodingKey {
        case id, phone, mobile, birthdate, personalEmail, personalMobile
        case eduForm = "edu_form"
        case eduMarkBookNum = "edu_mark_book_num"
        case eduStatus = "edu_status"
        case eduCourse = "edu_course"
        case eduLevel = "edu_level"
        case eduGroup = "edu_group"
        case faculty
        case eduDirection = "edu_direction"
        case eduSpecialization = "edu_specialization"
        case eduQualification = "edu_qualification"
        case user
    }
}

struct BitrixNamedEntity: Codable {
    let id: Int?
    let title: String?
    let shortTitle: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case shortTitle = "short_title"
    }
}

struct BitrixUser: Codable {
    let id: Int?
    let fullname: String?
    let lastname: String?
    let name: String?
    let surname: String?
    let email: String?
    let phone: String?
    let birthdate: String?
    let sex: String?
    let code: String?
    let photo: BitrixPhoto?
}

struct BitrixPhoto: Codable {
    let orig: String?
    let thumbnail: String?
    let small: String?
}

// MARK: - Приказы

struct Order: Codable, Identifiable, Hashable {
    let id: Int
    let number: String?
    let date: String?
    let dateApprove: String?
    let title: String?
    let action: String?

    var displayNumber: String {
        return number?.unicodeDecoded ?? ""
    }

    var displayTitle: String {
        return title?.unicodeDecoded ?? ""
    }

    var displayAction: String {
        return action?.unicodeDecoded ?? ""
    }

    var formattedDate: String? {
        guard let dateStr = date else { return nil }
        let input = DateFormatter()
        input.dateFormat = "yyyy-MM-dd"
        guard let d = input.date(from: dateStr) else { return dateStr }
        let output = DateFormatter()
        output.locale = Locale(identifier: "ru_RU")
        output.dateFormat = "dd.MM.yyyy"
        return output.string(from: d)
    }

    var formattedApproveDate: String? {
        guard let dateStr = dateApprove else { return nil }
        let input = DateFormatter()
        input.dateFormat = "yyyy-MM-dd"
        guard let d = input.date(from: dateStr) else { return dateStr }
        let output = DateFormatter()
        output.locale = Locale(identifier: "ru_RU")
        output.dateFormat = "dd.MM.yyyy"
        return output.string(from: d)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Order, rhs: Order) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Student ID

struct StudentIDData: Codable {
    let fullName: String?
    let avatarUrl: String?
    let recordBookNumber: String?
    let studyForm: String?
    let expirationDate: String?
    let enrollmentOrder: EnrollmentOrder?

    enum CodingKeys: String, CodingKey {
        case fullName, avatarUrl, recordBookNumber, studyForm, expirationDate
        case enrollmentOrder
    }
}

struct EnrollmentOrder: Codable {
    let orderNumber: String?
    let orderName: String?
    let orderDate: String?
}

// MARK: - Менеджер авторизации ЛК

@MainActor
final class LKManager: ObservableObject {
    static let shared = LKManager()

    enum AuthState {
        case unknown, loggedIn, loggedOut
    }

    @Published var session: LKSession?
    @Published var state: AuthState = .unknown
    @Published var didExplicitLogout = false

    // Данные из org.fa.ru
    @Published var bitrixProfile: BitrixProfile?
    @Published var orders: [Order] = []
    @Published var studentID: StudentIDData?
    @Published var studentCardData: Data?
    @Published var isLoadingData = false

    // Кеш зачётной книжки (для показа при истёкшей сессии)
    @Published var cachedGradebookSnapshot: Data? = nil

    // Сессионные куки (для отладки и синхронизации)
    @Published var lastSessionCheck: Date? = nil
    @Published var lastSessionError: String? = nil

    private let sessionURLCandidates: [URL] = [
        URL(string: "https://lk.fa.ru/api/auth/session")!,
        URL(string: "https://lk.fa.ru/elk/api/auth/session")!
    ]

    // Таймер фоновой проверки сессии
    private var sessionCheckTimer: Timer?

    init() {
        didExplicitLogout = UserDefaults.standard.bool(forKey: "lkDidExplicitLogout")
        loadCachedGradebookSnapshot()
        Task { await checkSession() }
    }

    // MARK: - Проверка сессии

    /// Проверяет сессию: пробует несколько способов и сохраняет результат.
    /// Если сессия валидна — подгружает все данные профиля.
    /// Если сессия истекла (но пользователь НЕ делал явный выход) — поднимает
    /// кешированные данные и оставляет state=.loggedOut с hasCachedData=true,
    /// чтобы UI показал профиль с баннером "Сессия истекла".
    func checkSession() async {
        state = .unknown
        lastSessionError = nil

        // Сначала пробуем быструю GET-проверку /api/auth/session
        if let s = await fetchSessionGET(), s.user != nil {
            await applySession(s)
            return
        }

        // Если GET не сработал — пробуем POST /elk/api/auth/session с CSRF
        if let s = await fetchSessionPOST(), s.user != nil {
            await applySession(s)
            return
        }

        // Сессия не получилась. Загружаем кеш (если он есть), чтобы показать
        // профиль даже без активной сессии.
        loadCachedProfileIntoMemory()

        let cookies = await faCookies()
        if cookies.isEmpty {
            // Нет cookies вообще — нечего восстанавливать
            session = nil
            state = .loggedOut
            lastSessionError = "Нет cookies fa.ru"
        } else {
            // Cookies есть, но сервер не вернул сессию — она истекла.
            // Если пользователь НЕ делал явный logout — оставляем state=.loggedOut
            // но с hasCachedData=true (профиль покажется из кеша с баннером).
            // Сохраним признак истёкшей сессии для UI.
            UserDefaults.standard.set(true, forKey: "lkSessionExpired")
            session = nil
            state = .loggedOut
            lastSessionError = "Сессия истекла. Необходимо войти заново"
        }
        lastSessionCheck = Date()
    }

    /// Загружает кешированные данные (bitrixProfile, orders, studentID) в память,
    /// чтобы UI мог показать профиль даже когда серверная сессия истекла.
    private func loadCachedProfileIntoMemory() {
        guard let shared = UserDefaults(suiteName: "group.com.schedule.ruz") else { return }
        // Восстанавливаем LKSession из cachedSession (для шапки профиля)
        if let cache = shared.dictionary(forKey: "cachedSession") {
            let user = LKUser(
                name: cache["fullName"] as? String,
                email: cache["email"] as? String,
                image: cache["avatarUrl"] as? String
            )
            let ext = LKExtendedUserData(
                login: nil, email: cache["email"] as? String,
                shortName: nil, firstName: nil, middleName: nil,
                lastName: cache["fullName"] as? String, preferredLanguage: nil,
                avatarUrl: cache["avatarUrl"] as? String,
                id: cache["userId"] as? String, group: cache["group"] as? String
            )
            self.session = LKSession(
                user: user, expires: nil, extendedUserData: ext,
                userId: cache["userId"] as? String
            )
        }
        // Восстанавливаем приказы из кеша
        if let ordersJSON = shared.string(forKey: "cachedOrders"),
           let data = ordersJSON.data(using: .utf8),
           let cachedOrders = try? JSONDecoder().decode([Order].self, from: data) {
            self.orders = cachedOrders
        }
    }

    /// Применяет полученную сессию и подгружает все данные
    private func applySession(_ s: LKSession) async {
        session = s
        state = .loggedIn
        lastSessionCheck = Date()
        lastSessionError = nil
        // Сессия восстановлена — сбрасываем признак истёкшей сессии
        UserDefaults.standard.set(false, forKey: "lkSessionExpired")
        // Пользователь вошёл (явно или тихо) — сбрасываем признак явного logout
        didExplicitLogout = false
        UserDefaults.standard.set(false, forKey: "lkDidExplicitLogout")

        if let groupName = s.studentGroup, !groupName.isEmpty {
            NotificationCenter.default.post(
                name: .init("LKStudentGroupAvailable"),
                object: groupName
            )
        }
        // Автоматическая подгрузка всех данных после входа
        await loadAllData()
    }

    /// Тихая проверка сессии (без обновления state в .unknown)
    func probeSession() async -> LKSession? {
        if let s = await fetchSessionGET(), s.user != nil { return s }
        return await fetchSessionPOST()
    }

    /// Принудительно перепроверить сессию (для pull-to-refresh)
    func refreshSession() async {
        await checkSession()
    }

    // MARK: - Загрузка всех данных после авторизации

    func loadAllData() async {
        guard state == .loggedIn else { return }
        isLoadingData = true

        // Параллельная загрузка всех данных (без кеширования по времени — всегда свежие после входа)
        async let profileTask = fetchBitrixProfile()
        async let ordersTask = fetchOrders()
        async let studentIdTask = fetchStudentID()

        bitrixProfile = await profileTask
        orders = await ordersTask
        studentID = await studentIdTask

        // Сохраняем кеш сессии и профиля (для показа при истёкшей сессии)
        saveSessionCache()
        // Сохраняем приказы в кеш для показа при истёкшей сессии
        saveOrdersCache()

        // Добавляем группу студента в избранное
        if let groupTitle = bitrixProfile?.eduGroup?.title {
            addStudentGroupToFavorites(groupTitle)
        }

        isLoadingData = false
    }

    /// Сохраняет кеш сессии в App Group UserDefaults (для виджетов и фоллбэка)
    private func saveSessionCache() {
        guard let shared = UserDefaults(suiteName: "group.com.schedule.ruz") else { return }
        if let s = session {
            let cacheData: [String: Any] = [
                "fullName": s.fullName ?? "",
                "group": s.studentGroup ?? "",
                "email": s.user?.email ?? s.extendedUserData?.email ?? "",
                "userId": s.profileId,
                "avatarUrl": s.extendedUserData?.avatarUrl ?? s.user?.image ?? "",
                "cachedAt": Date().timeIntervalSince1970
            ]
            shared.set(cacheData, forKey: "cachedSession")
            shared.set(true, forKey: "cachedGradebook")
        }
    }

    /// Сохраняет приказы в App Group UserDefaults (для показа при истёкшей сессии)
    private func saveOrdersCache() {
        guard let shared = UserDefaults(suiteName: "group.com.schedule.ruz") else { return }
        if let data = try? JSONEncoder().encode(orders),
           let json = String(data: data, encoding: .utf8) {
            shared.set(json, forKey: "cachedOrders")
        }
    }

    /// True, если есть кешированные данные профиля (для UI: показать профиль
    /// вместо экрана "войдите" при истёкшей сессии)
    var hasCachedProfileData: Bool {
        guard let shared = UserDefaults(suiteName: "group.com.schedule.ruz") else { return false }
        return shared.dictionary(forKey: "cachedSession") != nil
    }

    /// True, если сессия истекла (cookies есть, но сервер не вернул сессию).
    /// UI показывает баннер "Сессия истекла — продлите" вместо загрузки данных.
    var sessionExpired: Bool {
        UserDefaults.standard.bool(forKey: "lkSessionExpired") && !didExplicitLogout
    }

    private func loadCachedGradebookSnapshot() {
        guard let shared = UserDefaults(suiteName: "group.com.schedule.ruz") else { return }
        if shared.bool(forKey: "cachedGradebook") {
            // Просто отметка, что кеш есть — загружаем сами данные по требованию
            cachedGradebookSnapshot = Data()
        }
    }

    // MARK: - org.fa.ru API
    // org.fa.ru использует Bitrix-сессию (BX_ORG_FA_RU_* cookies),
    // а НЕ JWT Bearer. Сессия устанавливается через Bitrix SSO handshake
    // в NativeAuthManager.bitrixSSOHandshake() (5 шагов через /bitrix/vuz/sso/*).
    // JWT с client_id=elk-front технически невалиден для org.fa.ru.
    //
    // ВАЖНО: для org.fa.ru нужно отправлять ТОЛЬКО cookies домена org.fa.ru
    // (BX_ORG_FA_RU_*, PHPSESSID, vuzportalfinun_session). Cookie хедер с
    // ВСЕМИ fa.ru cookies (включая KEYCLOAK_IDENTITY ~2KB JWT) даёт 8KB+ —
    // nginx возвращает 400 "Request Header Or Cookie Too Large".
    //
    // Все fetchBitrix* методы вызывают ensureBitrixSession() перед запросом
    // — это гарантирует наличие BX_ORG_FA_RU_* cookies.

    /// Возвращает cookies, подходящие для org.fa.ru:
    /// только cookies с доменом org.fa.ru (BX_ORG_FA_RU_*, PHPSESSID, vuzportalfinun_session).
    /// Не включает KEYCLOAK_IDENTITY (path=/realms/elk/, домен auth.fa.ru) — он не нужен и
    /// раздувает Cookie хедер до 8KB+ → nginx 400 "Request Header Or Cookie Too Large".
    private func bitrixCookies(from cookies: [HTTPCookie]) -> [HTTPCookie] {
        cookies.filter { cookie in
            // Домен может быть ".org.fa.ru", "org.fa.ru" — оба валидны
            cookie.domain.contains("org.fa.ru")
        }
    }

    private func bitrixHeaders(_ cookies: [HTTPCookie]) async -> [String: String] {
        // Оставляем только cookies домена org.fa.ru — иначе Cookie хедер
        // получается 8KB+ и nginx возвращает 400 "Request Header Or Cookie Too Large".
        let orgCookies = bitrixCookies(from: cookies)
        var headers = HTTPCookie.requestHeaderFields(with: orgCookies)
        headers["App-Version"] = "8.135.3"
        headers["App-Key"] = "browser-bitrix"
        headers["App-Locale"] = "ru"
        headers["App-TimezoneOffset"] = "-180"
        headers["Accept"] = "application/json"
        // Authorization: Bearer НЕ добавляем — Bitrix использует собственную сессию.
        // JWT от client_id=elk-front невалиден для org.fa.ru
        // (aud=account, allowed-origins=lk.fa.ru).
        return headers
    }

    func fetchBitrixProfile() async -> BitrixProfile? {
        let cookies = await faCookies()
        guard !cookies.isEmpty else {
            print("[LK] fetchBitrixProfile: нет cookies fa.ru")
            return nil
        }
        // Гарантируем наличие Bitrix-сессии (BX_ORG_FA_RU_* cookies).
        // Если handshake ещё не выполнен — он запустится и дождёмся его завершения.
        await NativeAuthManager.ensureBitrixSession()
        let cookies2 = await faCookies()  // перечитываем после handshake
        let bxCount = cookies2.filter { $0.name.hasPrefix("BX_ORG_FA_RU") }.count
        let orgCookies = bitrixCookies(from: cookies2)
        let cookieHeaderSize = orgCookies.reduce(0) { $0 + $1.name.count + $1.value.count + 3 }
        print("[LK] fetchBitrixProfile: BX_ORG_FA_RU=\(bxCount), org.fa.ru cookies=\(orgCookies.count), cookieHeader=\(cookieHeaderSize) bytes")
        let headers = await bitrixHeaders(cookies2)
        guard let url = URL(string: "https://org.fa.ru/bitrix/vuz/api/profile/current") else { return nil }

        var request = URLRequest(url: url)
        // НЕ устанавливаем httpShouldHandleCookies=true, чтобы URLSession не подставлял
        // свои cookies — мы формируем Cookie хедер вручную через bitrixHeaders().
        // Иначе URLSession.shared может использовать закешированные cookies для keep-alive
        // соединения, которые устарели.
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            print("[LK] fetchBitrixProfile: status=\(status), data=\(data.count) bytes")
            if status == 200 {
                if let profile = try? JSONDecoder().decode(BitrixProfile.self, from: data) {
                    return profile
                }
                print("[LK] fetchBitrixProfile: decode failed, body=\(String(data: data, encoding: .utf8)?.prefix(200) ?? "?")")
                return nil
            }
            // Логируем тело ответа для диагностики (особенно для 400 Bad Request)
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(300) ?? "<binary>"
            print("[LK] fetchBitrixProfile: status=\(status) body=\(bodyPreview)")
            if status == 401 {
                print("[LK] fetchBitrixProfile: 401 — перезапускаем Bitrix SSO handshake")
                NativeAuthManager.resetBitrixSSO()
                let ok = await NativeAuthManager.shared.bitrixSSOHandshake()
                if ok {
                    let retryCookies = await faCookies()
                    let retryHeaders = await bitrixHeaders(retryCookies)
                    var retryRequest = URLRequest(url: url)
                    for (name, value) in retryHeaders {
                        retryRequest.setValue(value, forHTTPHeaderField: name)
                    }
                    let (retryData, retryResp) = try await URLSession.shared.data(for: retryRequest)
                    let retryStatus = (retryResp as? HTTPURLResponse)?.statusCode ?? 0
                    print("[LK] fetchBitrixProfile: retry status=\(retryStatus)")
                    if retryStatus == 200 {
                        return try? JSONDecoder().decode(BitrixProfile.self, from: retryData)
                    }
                }
            }
            return nil
        } catch {
            print("[LK] fetchBitrixProfile: error \(error.localizedDescription)")
            return nil
        }
    }

    func fetchOrders() async -> [Order] {
        let cookies = await faCookies()
        guard !cookies.isEmpty else {
            print("[LK] fetchOrders: нет cookies fa.ru")
            return []
        }
        // Гарантируем наличие Bitrix-сессии.
        await NativeAuthManager.ensureBitrixSession()
        let cookies2 = await faCookies()
        let bxCount = cookies2.filter { $0.name.hasPrefix("BX_ORG_FA_RU") }.count
        let orgCookies = bitrixCookies(from: cookies2)
        let cookieHeaderSize = orgCookies.reduce(0) { $0 + $1.name.count + $1.value.count + 3 }
        print("[LK] fetchOrders: BX_ORG_FA_RU=\(bxCount), org.fa.ru cookies=\(orgCookies.count), cookieHeader=\(cookieHeaderSize) bytes")
        let headers = await bitrixHeaders(cookies2)
        guard let url = URL(string: "https://org.fa.ru/bitrix/vuz/api/orders/") else { return [] }

        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            print("[LK] fetchOrders: status=\(status), data=\(data.count) bytes")
            if status == 200,
               var rawOrders = try? JSONDecoder().decode([Order].self, from: data) {
                var seen = Set<Int>()
                rawOrders.removeAll { !seen.insert($0.id).inserted }
                rawOrders.sort { ($0.date ?? "") > ($1.date ?? "") }
                return rawOrders
            }
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(300) ?? "<binary>"
            print("[LK] fetchOrders: status=\(status) body=\(bodyPreview)")
            if status == 401 {
                print("[LK] fetchOrders: 401 — перезапускаем Bitrix SSO handshake")
                NativeAuthManager.resetBitrixSSO()
                let ok = await NativeAuthManager.shared.bitrixSSOHandshake()
                if ok {
                    let retryCookies = await faCookies()
                    let retryHeaders = await bitrixHeaders(retryCookies)
                    var retryRequest = URLRequest(url: url)
                    for (name, value) in retryHeaders {
                        retryRequest.setValue(value, forHTTPHeaderField: name)
                    }
                    let (retryData, retryResp) = try await URLSession.shared.data(for: retryRequest)
                    let retryStatus = (retryResp as? HTTPURLResponse)?.statusCode ?? 0
                    print("[LK] fetchOrders: retry status=\(retryStatus)")
                    if retryStatus == 200,
                       var retryOrders = try? JSONDecoder().decode([Order].self, from: retryData) {
                        var seen2 = Set<Int>()
                        retryOrders.removeAll { !seen2.insert($0.id).inserted }
                        retryOrders.sort { ($0.date ?? "") > ($1.date ?? "") }
                        return retryOrders
                    }
                }
            }
            return []
        } catch {
            print("[LK] fetchOrders: error \(error.localizedDescription)")
            return []
        }
    }

    func fetchStudentID() async -> StudentIDData? {
        let cookies = await faCookies()
        guard !cookies.isEmpty else { return nil }
        let headerFields = HTTPCookie.requestHeaderFields(with: cookies)

        guard let url = URL(string: "https://lk.fa.ru/elk/api/profile/student-id") else { return nil }

        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = true
        for (name, value) in headerFields {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("https://lk.fa.ru/elk/profile/STUDENT/\(session?.profileId ?? "")", forHTTPHeaderField: "Referer")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return nil }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let cleanedData = try? JSONSerialization.data(withJSONObject: json)
            return try? JSONDecoder().decode(StudentIDData.self, from: cleanedData ?? data)
        }

        return try? JSONDecoder().decode(StudentIDData.self, from: data)
    }

    // MARK: - Студенческий билет (PDF из org.fa.ru)

    struct StudentCardResponse: Codable {
        let error: Int?
        let status: String?
        let path: String?
        let pathDoc: String?
    }

    func fetchStudentCard() async {
        let cookies = await faCookies()
        guard !cookies.isEmpty else {
            print("[LK] fetchStudentCard: нет cookies fa.ru")
            studentCardData = nil
            return
        }
        // Гарантируем наличие Bitrix-сессии.
        await NativeAuthManager.ensureBitrixSession()
        let cookies2 = await faCookies()
        let bxCount = cookies2.filter { $0.name.hasPrefix("BX_ORG_FA_RU") }.count
        let orgCookies = bitrixCookies(from: cookies2)
        let cookieHeaderSize = orgCookies.reduce(0) { $0 + $1.name.count + $1.value.count + 3 }
        print("[LK] fetchStudentCard: BX_ORG_FA_RU=\(bxCount), org.fa.ru cookies=\(orgCookies.count), cookieHeader=\(cookieHeaderSize) bytes")
        let headers = await bitrixHeaders(cookies2)

        let profileId = cookies2.first(where: { $0.name == "BX_ORG_FA_RU_PROFILE_ID" })?.value
            ?? session?.profileId
            ?? ""
        guard !profileId.isEmpty else {
            print("[LK] fetchStudentCard: нет profileId")
            studentCardData = nil
            return
        }

        guard let url = URL(string: "https://org.fa.ru/bitrix/vuz/api/profiles/studentCard/\(profileId)") else { return }

        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("https://org.fa.ru/app/profile/home", forHTTPHeaderField: "Referer")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            print("[LK] fetchStudentCard: status=\(status), data=\(data.count) bytes")
            if status == 200 {
                await processStudentCardResponse(data, headers: headers)
                return
            }
            if status == 401 {
                print("[LK] fetchStudentCard: 401 — перезапускаем Bitrix SSO handshake")
                NativeAuthManager.resetBitrixSSO()
                let ok = await NativeAuthManager.shared.bitrixSSOHandshake()
                if ok {
                    let retryCookies = await faCookies()
                    let retryHeaders = await bitrixHeaders(retryCookies)
                    var retryRequest = URLRequest(url: url)
                    for (name, value) in retryHeaders {
                        retryRequest.setValue(value, forHTTPHeaderField: name)
                    }
                    retryRequest.setValue("https://org.fa.ru/app/profile/home", forHTTPHeaderField: "Referer")
                    let (retryData, retryResp) = try await URLSession.shared.data(for: retryRequest)
                    let retryStatus = (retryResp as? HTTPURLResponse)?.statusCode ?? 0
                    print("[LK] fetchStudentCard: retry status=\(retryStatus)")
                    if retryStatus == 200 {
                        await processStudentCardResponse(retryData, headers: retryHeaders)
                        return
                    }
                }
            }
            print("[LK] fetchStudentCard: returning nil, status=\(status)")
            studentCardData = nil
        } catch {
            print("[LK] fetchStudentCard: error \(error.localizedDescription)")
            studentCardData = nil
        }
    }

    /// Обрабатывает ответ /studentCard/<id>: извлекает путь к PDF и загружает PDF.
    private func processStudentCardResponse(_ data: Data, headers: [String: String]) async {
        let resp = try? JSONDecoder().decode(StudentCardResponse.self, from: data)
        guard let pdfPath = resp?.path, !pdfPath.isEmpty else {
            studentCardData = nil
            return
        }

        let pdfURL = URL(string: "https://org.fa.ru\(pdfPath)")!
        var pdfRequest = URLRequest(url: pdfURL)
        // Cookie хедер уже добавлен через headers выше — не используем
        // httpShouldHandleCookies, чтобы URLSession не подменял его своим.
        for (name, value) in headers {
            pdfRequest.setValue(value, forHTTPHeaderField: name)
        }
        pdfRequest.setValue("https://org.fa.ru/app/profile/home", forHTTPHeaderField: "Referer")
        pdfRequest.setValue("*/*", forHTTPHeaderField: "Accept")

        if let (pdfData, pdfResponse) = try? await URLSession.shared.data(for: pdfRequest),
           let pdfHTTP = pdfResponse as? HTTPURLResponse,
           pdfHTTP.statusCode == 200 {
            studentCardData = pdfData
            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let cacheURL = cacheDir.appendingPathComponent("student_card.pdf")
            try? pdfData.write(to: cacheURL)
        } else {
            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let cacheURL = cacheDir.appendingPathComponent("student_card.pdf")
            if let cached = try? Data(contentsOf: cacheURL) {
                studentCardData = cached
            } else {
                studentCardData = nil
            }
        }
    }

    func clearStudentCardCache() {
        studentCardData = nil
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let cacheURL = cacheDir.appendingPathComponent("student_card.pdf")
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: - Добавление группы в избранное

    private func addStudentGroupToFavorites(_ groupName: String) {
        Task {
            let api = RuzAPI.shared
            if let found = try? await api.fetchGroups(query: groupName) {
                if let studentGroup = found.first(where: { $0.type == "group" }) {
                    let defaults = UserDefaults(suiteName: "group.com.schedule.ruz")
                    guard let defaults else { return }

                    var currentFavorites: [Group] = []
                    if let data = defaults.data(forKey: "favorites") {
                        currentFavorites = (try? JSONDecoder().decode([Group].self, from: data)) ?? []
                    }

                    if !currentFavorites.contains(where: { $0.id == studentGroup.id }) {
                        currentFavorites.append(studentGroup)
                        if let encoded = try? JSONEncoder().encode(currentFavorites) {
                            defaults.set(encoded, forKey: "favorites")
                            print("[LK] Группа \(groupName) добавлена в избранное")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Cookies и сессия

    /// Синхронизирует куки из HTTPCookieStorage в WKWebsiteDataStore (важно для WebView).
    static func syncCookiesToWKWebView() async {
        let httpCookies = HTTPCookieStorage.shared.cookies ?? []
        let faCookies = httpCookies.filter { $0.domain.contains("fa.ru") }
        let wkStore = WKWebsiteDataStore.default().httpCookieStore
        for cookie in faCookies {
            await wkStore.setCookie(cookie)
        }
    }

    /// Синхронизирует куки из WKWebsiteDataStore в HTTPCookieStorage (если WebView обновил их).
    static func syncCookiesFromWKWebView() async {
        let wkCookies = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                cont.resume(returning: cookies)
            }
        }
        for cookie in wkCookies where cookie.domain.contains("fa.ru") {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    /// Публичный доступ к cookies fa.ru для других менеджеров (например, StudyPlanManager).
    func faCookiesPublic() async -> [HTTPCookie] {
        await faCookies()
    }

    private func faCookies() async -> [HTTPCookie] {
        // Читаем из обоих хранилищ и мержим (HTTPCookieStorage имеет приоритет — свежие от URL loading)
        let wkCookies = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                cont.resume(returning: cookies.filter { $0.domain.contains("fa.ru") })
            }
        }
        let storageCookies = (HTTPCookieStorage.shared.cookies ?? []).filter { $0.domain.contains("fa.ru") }

        // Мерж: HTTPCookieStorage (свежие) перезаписывают WKWebView по имени+домену
        var merged = wkCookies
        for cookie in storageCookies {
            if let idx = merged.firstIndex(where: { $0.name == cookie.name && $0.domain == cookie.domain }) {
                merged[idx] = cookie
            } else {
                merged.append(cookie)
            }
        }
        return merged
    }

    /// GET-запрос к /api/auth/session (Next.js-style endpoint)
    private func fetchSessionGET() async -> LKSession? {
        let cookies = await faCookies()
        guard !cookies.isEmpty else { return nil }

        // Сначала синхронизируем куки в WebView — на случай если авторизация шла через WebView
        await Self.syncCookiesToWKWebView()

        let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)
        guard let url = URL(string: "https://lk.fa.ru/api/auth/session") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = true
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://lk.fa.ru", forHTTPHeaderField: "Referer")
        for (name, value) in cookieHeader {
            request.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200 else { return nil }

            // Пустое тело {} = не авторизован
            if data.isEmpty || data.count <= 2 { return nil }

            // Пробуем декодировать с extendedUserData
            if let s = try? JSONDecoder().decode(LKSession.self, from: data), s.user != nil {
                return s
            }

            // Fallback: достаём только user, expires
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                guard json["user"] != nil else { return nil }
                let userDict = json["user"] as? [String: Any]
                let s = LKSession(
                    user: LKUser(
                        name: userDict?["name"] as? String,
                        email: userDict?["email"] as? String,
                        image: userDict?["image"] as? String
                    ),
                    expires: json["expires"] as? String,
                    extendedUserData: nil,
                    userId: userDict?["id"] as? String
                )
                return s.user != nil ? s : nil
            }
            return nil
        } catch {
            print("[LK] GET session error: \(error.localizedDescription)")
            return nil
        }
    }

    /// POST-запрос к /elk/api/auth/session (Next.js auth endpoint с CSRF)
    private func fetchSessionPOST() async -> LKSession? {
        let cookies = await faCookies()
        guard !cookies.isEmpty else { return nil }

        await Self.syncCookiesToWKWebView()

        // Извлекаем CSRF-токен из cookies
        let csrfCookie = cookies.first { $0.name == "__Host-next-auth.csrf-token" || $0.name.contains("csrf") }
        let csrfToken = csrfCookie?.value.components(separatedBy: "%7C").first
            ?? csrfCookie?.value.components(separatedBy: "|").first

        guard let url = URL(string: "https://lk.fa.ru/elk/api/auth/session") else { return nil }

        let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = true
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://lk.fa.ru", forHTTPHeaderField: "Referer")
        request.setValue("https://lk.fa.ru", forHTTPHeaderField: "Origin")
        for (name, value) in cookieHeader {
            request.setValue(value, forHTTPHeaderField: name)
        }

        // Тело запроса с CSRF-токеном
        if let csrf = csrfToken {
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["csrfToken": csrf])
        } else {
            request.httpBody = Data()
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200 || http.statusCode == 302 else { return nil }

            // Пустое тело = не авторизован
            if data.isEmpty || data.count <= 2 { return nil }

            // Пробуем декодировать
            if let s = try? JSONDecoder().decode(LKSession.self, from: data), s.user != nil {
                return s
            }

            // Fallback парсинг
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                guard json["user"] != nil else { return nil }
                let userDict = json["user"] as? [String: Any]
                let s = LKSession(
                    user: LKUser(
                        name: userDict?["name"] as? String,
                        email: userDict?["email"] as? String,
                        image: userDict?["image"] as? String
                    ),
                    expires: json["expires"] as? String,
                    extendedUserData: nil,
                    userId: userDict?["id"] as? String
                )
                return s.user != nil ? s : nil
            }
            return nil
        } catch {
            print("[LK] POST session error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Запуск фоновой проверки сессии

    /// Запускает периодическую проверку сессии (раз в 5 минут)
    func startSessionKeepalive() {
        sessionCheckTimer?.invalidate()
        sessionCheckTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Только если уже залогинен — тихо проверяем, не понижая state в .unknown
                if self.state == .loggedIn, let s = await self.probeSession(), s.user != nil {
                    self.session = s
                    self.lastSessionCheck = Date()
                }
            }
        }
    }

    func stopSessionKeepalive() {
        sessionCheckTimer?.invalidate()
        sessionCheckTimer = nil
    }

    // MARK: - Выход

    func logout() async {
        didExplicitLogout = true
        UserDefaults.standard.set(true, forKey: "lkDidExplicitLogout")

        // Очищаем сохранённые учётные данные
        KeychainHelper.delete(key: "savedUsername")
        KeychainHelper.delete(key: "savedPassword")
        UserDefaults.standard.set(false, forKey: "rememberMe")

        // Очищаем кэш фото профиля
        if let userId = session?.userId ?? session?.extendedUserData?.id {
            PhotoCache.clear(for: userId)
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) { cont.resume(returning: ()) }
        }

        // Очищаем cookies из HTTPCookieStorage
        if let cookies = HTTPCookieStorage.shared.cookies {
            for cookie in cookies where cookie.domain.contains("fa.ru") {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }

        // Сбрасываем кеш сессии
        if let shared = UserDefaults(suiteName: "group.com.schedule.ruz") {
            shared.removeObject(forKey: "cachedSession")
            shared.removeObject(forKey: "cachedGradebook")
        }

        session = nil
        bitrixProfile = nil
        orders = []
        studentID = nil
        state = .loggedOut
        stopSessionKeepalive()
    }
}

// MARK: - Unicode Decode Extension

extension String {
    var unicodeDecoded: String {
        let mutable = NSMutableString(string: self) as CFMutableString
        CFStringTransform(mutable, nil, "Any-Hex/Java" as CFString, true)
        return (mutable as String).replacingOccurrences(of: "\\/", with: "/")
    }
}

// =================================================================
// MARK: - Keychain Helper (шифрованное хранение)
// =================================================================

enum KeychainHelper {
    static func save(key: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func save(key: String, string: String) {
        if let data = string.data(using: .utf8) {
            save(key: key, data: data)
        }
    }

    static func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        return result as? Data
    }

    static func loadString(key: String) -> String? {
        guard let data = load(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// =================================================================
// MARK: - Photo Cache (кэш фото на устройстве по аккаунту)
// =================================================================

enum PhotoCache {
    private static let cacheDir = FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask
    )[0].appendingPathComponent("ProfilePhotos", isDirectory: true)

    static func cacheKey(for userId: String) -> String {
        let data = Data(userId.utf8)
        let hash = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> UInt64 in
            var fnv: UInt64 = 14695981039346656037
            for byte in ptr {
                fnv ^= UInt64(byte)
                fnv &+= 14695981039346656037
            }
            return fnv
        }
        return String(format: "%016llx", hash)
    }

    static func save(imageData: Data, for userId: String) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let fileURL = cacheDir.appendingPathComponent(cacheKey(for: userId) + ".jpg")
        try? imageData.write(to: fileURL)
    }

    static func load(for userId: String) -> Data? {
        let fileURL = cacheDir.appendingPathComponent(cacheKey(for: userId) + ".jpg")
        return try? Data(contentsOf: fileURL)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: cacheDir)
    }

    static func clear(for userId: String) {
        let fileURL = cacheDir.appendingPathComponent(cacheKey(for: userId) + ".jpg")
        try? FileManager.default.removeItem(at: fileURL)
    }
}
