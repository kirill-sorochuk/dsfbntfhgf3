// ======================================================================
// MailManager.swift — Полностью нативный почтовый клиент Mail.ru (e.mail.ru)
// Авторизация через WKWebView (cookie z-c), API через JSON-эндпоинты
// + Фоновая проверка новых писем (BGTaskScheduler)
// + Локальные уведомления о новых письмах
// + Поиск по письмам
// + Работа с вложениями
// ======================================================================

import Foundation
import SwiftUI
import WebKit
import Combine
import BackgroundTasks
import UserNotifications
import WidgetKit

// MARK: - Логирование

private func mailLog(_ items: Any..., separator: String = " ") {
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss.SSS"
    let time = fmt.string(from: Date())
    let msg = items.map { "\($0)" }.joined(separator: separator)
    print("\(time) [MAIL] \(msg)")
}

// MARK: - Модели данных

struct MailFolder: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: String?
    let unreadCount: Int
    let totalCount: Int
    
    var icon: String {
        switch type {
        case "inbox": return "tray.inbox.fill"
        case "sent": return "paperplane.fill"
        case "drafts": return "doc.badge.gearshape"
        case "spam": return "exclamationmark.triangle.fill"
        case "trash": return "trash.fill"
        case "starred": return "star.fill"
        case "archive": return "archivebox.fill"
        default: return "folder.fill"
        }
    }
    
    var displayName: String {
        switch type {
        case "inbox": return "Входящие"
        case "sent": return "Отправленные"
        case "drafts": return "Черновики"
        case "spam": return "Спам"
        case "trash": return "Корзина"
        case "starred": return "Избранные"
        case "archive": return "Архив"
        default: return name
        }
    }
    
    var hasUnread: Bool { unreadCount > 0 }
    
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: MailFolder, rhs: MailFolder) -> Bool { lhs.id == rhs.id }
}

struct MailMessage: Codable, Identifiable, Equatable {
    let id: String
    let from: MailAddress?
    let to: [MailAddress]
    let cc: [MailAddress]?
    let bcc: [MailAddress]?
    let subject: String?
    let preview: String?
    let bodyHTML: String?
    let bodyText: String?
    let date: String?
    let isRead: Bool
    let isStarred: Bool
    let isAnswered: Bool
    let isForwarded: Bool
    let hasAttachments: Bool
    let attachments: [MailAttachment]?
    let folderId: String?
    let inReplyTo: String?
    let references: String?
    
    var displaySubject: String {
        (subject ?? "(Без темы)").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    var displayPreview: String {
        (preview ?? bodyText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(140).description
    }
    
    var displayFrom: String {
        from?.displayName ?? "Неизвестный"
    }
    
    var displayDate: String {
        guard let dateStr = date else { return "" }
        let input = ISO8601DateFormatter()
        input.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = input.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr) else {
            return dateStr.prefix(10).description
        }
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            let out = DateFormatter()
            out.dateFormat = "HH:mm"
            return out.string(from: d)
        }
        let out = DateFormatter()
        out.locale = Locale(identifier: "ru_RU")
        out.dateFormat = cal.component(.year, from: d) == cal.component(.year, from: Date()) ? "d MMM" : "dd.MM.yy"
        return out.string(from: d)
    }
}

struct MailAddress: Codable, Identifiable, Hashable {
    let email: String
    let name: String?
    
    var id: String { email }
    var displayName: String {
        if let name = name, !name.isEmpty {
            return name
        }
        return email
    }
    
    func hash(into hasher: inout Hasher) { hasher.combine(email) }
    static func == (lhs: MailAddress, rhs: MailAddress) -> Bool { lhs.email == rhs.email }
}

struct MailAttachment: Codable, Identifiable, Equatable {
    let id: String
    let filename: String?
    let size: Int?
    let mimeType: String?
    let url: String?
    
    var displaySize: String {
        guard let bytes = size else { return "" }
        if bytes < 1024 { return "\(bytes) Б" }
        if bytes < 1024 * 1024 { return String(format: "%.0f КБ", Double(bytes) / 1024) }
        return String(format: "%.1f МБ", Double(bytes) / (1024 * 1024))
    }
}

struct MailContact: Codable, Identifiable {
    let id: String
    let name: String?
    let email: String?
    let department: String?
    let position: String?
    let phone: String?
    
    var displayName: String { name ?? email ?? "Без имени" }
    
    enum CodingKeys: String, CodingKey {
        case id, name, email, department, position, phone
    }
}

// MARK: - Состояния авторизации почты

enum MailAuthStep: Equatable {
    case idle
    case loading
    case waitingCredentials
    case exchanging
    case success
    case error(String)
    
    static func == (lhs: MailAuthStep, rhs: MailAuthStep) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading),
             (.waitingCredentials, .waitingCredentials),
             (.exchanging, .exchanging), (.success, .success):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Менеджер авторизации почты (Mail.ru cookie-based)

@MainActor
class MailAuthManager: ObservableObject {
    static let shared = MailAuthManager()
    
    @Published var errorMessage: String? = nil
    @Published var isLoading: Bool = false
    
    var onAuthSuccess: (() -> Void)?
    
    private init() {}
    
    func reset() {
        errorMessage = nil
        isLoading = false
    }
    
    func logout() {
        KeychainHelper.delete(key: "mailSessionToken")
        reset()
        MailManager.shared.logout()
    }
}

// ======================================================================
// MARK: - WKWebView авторизация для почты (e.mail.ru)
// ======================================================================

struct MailAuthWebView: UIViewRepresentable {
    let onAuthSuccess: () -> Void
    let onError: (String) -> Void
    @Binding var isLoading: Bool
    
    private let mailURL = "https://e.mail.ru/inbox"
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
        webView.load(URLRequest(url: URL(string: mailURL)!))
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onAuthSuccess: onAuthSuccess, onError: onError, isLoading: $isLoading, mailURL: mailURL)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        let onAuthSuccess: () -> Void
        let onError: (String) -> Void
        @Binding var isLoading: Bool
        let mailURL: String
        private var checkCount = 0
        
        init(onAuthSuccess: @escaping () -> Void, onError: @escaping (String) -> Void,
             isLoading: Binding<Bool>, mailURL: String) {
            self.onAuthSuccess = onAuthSuccess
            self.onError = onError
            self._isLoading = isLoading
            self.mailURL = mailURL
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            let url = webView.url?.absoluteString ?? ""
            
            if url.contains("e.mail.ru") && !url.contains("login") && !url.contains("auth") && !url.contains("signup") {
                checkCount += 1
                if checkCount >= 2 {
                    Task { @MainActor in
                        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                        let zcCookie = cookies.first { $0.name == "z-c" && $0.domain.contains("mail.ru") }
                        if let zc = zcCookie {
                            KeychainHelper.save(key: "mailSessionToken", string: zc.value)
                            mailLog("Сессия Mail.ru сохранена (z-c)")
                            // Синхронизируем куки в HTTPCookieStorage
                            for cookie in cookies where cookie.domain.contains("mail.ru") {
                                HTTPCookieStorage.shared.setCookie(cookie)
                            }
                            onAuthSuccess()
                        } else if cookies.contains(where: { $0.domain.contains("mail.ru") }) {
                            mailLog("Куки mail.ru найдены, но нет z-c — пробуем")
                            // Сохраняем что есть
                            for cookie in cookies where cookie.domain.contains("mail.ru") {
                                HTTPCookieStorage.shared.setCookie(cookie)
                            }
                            onAuthSuccess()
                        }
                    }
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            if (error as NSError).code != NSURLErrorCancelled {
                onError("Не удалось загрузить страницу: \(error.localizedDescription)")
            }
        }
    }
}

// ======================================================================
// MARK: - MailManager — основной менеджер почты (e.mail.ru API)
// ======================================================================

@MainActor
class MailManager: ObservableObject {
    static let shared = MailManager()
    
    enum MailState {
        case unknown, loggedIn, loggedOut
    }
    
    // Основные данные
    @Published var state: MailState = .unknown
    @Published var folders: [MailFolder] = []
    @Published var messages: [MailMessage] = []
    @Published var currentFolderId: String = "INBOX"
    @Published var currentMessage: MailMessage?
    @Published var contacts: [MailContact] = []
    
    // Поиск
    @Published var searchResults: [MailMessage] = []
    @Published var searchQuery: String = ""
    @Published var isSearching: Bool = false
    
    // Состояния загрузки
    @Published var isLoadingFolders = false
    @Published var isLoadingMessages = false
    @Published var isLoadingMessage = false
    @Published var totalMessages = 0
    @Published var unreadCount = 0
    @Published var totalUnreadCount = 0  // Суммарно по всем папкам
    @Published var errorMessage: String? = nil
    @Published var lastNewMailCheck: Date? = nil
    
    // Mail.ru API
    private let baseURL = "https://e.mail.ru"
    private let apiBase = "https://e.mail.ru/api/v1"
    
    // Сессионная кука z-c (основной токен Mail.ru)
    private var sessionToken: String? {
        KeychainHelper.loadString(key: "mailSessionToken")
    }
    
    /// Защита от повторной регистрации фоновой задачи почты.
    private static var backgroundTaskRegistered = false
    
    // Идентификатор фоновой задачи
    let backgroundTaskIdentifier = "com.fa.schedule.mailRefresh"
    
    // Кеш последних ID писем для определения «новых»
    private var lastSeenMessageIDs: Set<String> = []
    
    private init() {
        Task { await checkMailSession() }
        #if os(iOS)
        registerBackgroundTask()
        #endif
    }
    
    // =================================================================
    // MARK: - Проверка сессии
    // =================================================================
    
    func checkMailSession() async {
        let hasToken = sessionToken != nil
        
        let cookies = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                cont.resume(returning: cookies.filter { $0.domain.contains("mail.ru") })
            }
        }
        
        guard hasToken || !cookies.isEmpty else {
            mailLog("Сессия Mail.ru не найдена")
            state = .loggedOut
            return
        }
        
        mailLog("Проверка сессии Mail.ru... (token=\(hasToken), cookies=\(cookies.count))")
        
        // Пробуем загрузить папки — если успешно, значит сессия валидна
        await fetchFolders()
        
        if !folders.isEmpty {
            state = .loggedIn
            // Загружаем входящие и считаем непрочитанные
            await fetchMessages(folderId: "INBOX")
            await refreshTotalUnread()
            // Запускаем фоновую проверку
            scheduleNextMailCheck()
        } else {
            state = .loggedOut
        }
    }
    
    /// Тихо обновляет папки и счётчик непрочитанных (без UI-блокировки)
    func refreshFoldersAndUnread() async {
        guard state == .loggedIn else { return }
        await fetchFolders()
        await refreshTotalUnread()
        lastNewMailCheck = Date()
    }
    
    /// Суммарный счётчик непрочитанных по всем папкам
    func refreshTotalUnread() async {
        var total = 0
        for folder in folders {
            total += folder.unreadCount
        }
        totalUnreadCount = total
        // Обновляем badge приложения
        #if canImport(UIKit)
        DispatchQueue.main.async {
            if #available(iOS 16.0, *) {
                UNUserNotificationCenter.current().setBadgeCount(total)
            } else {
                UIApplication.shared.applicationIconBadgeNumber = total
            }
        }
        #endif
    }
    
    // =================================================================
    // MARK: - Папки
    // =================================================================
    
    func fetchFolders() async {
        isLoadingFolders = true
        errorMessage = nil
        
        let result = await mailRequest("POST", path: "/user/folders")
        
        if let data = result.data {
            let inner = unwrapMailRuBody(data)
            
            if let decoded = try? JSONDecoder().decode([MailFolder].self, from: inner) {
                folders = decoded
            } else if let json = try? JSONSerialization.jsonObject(with: inner) as? [String: Any],
                      let folderArray = json["folders"] as? [[String: Any]] {
                folders = parseFolders(folderArray)
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let body = json["body"] as? [String: Any],
                      let folderArray = body["folders"] as? [[String: Any]] {
                folders = parseFolders(folderArray)
            } else {
                folders = defaultFolders()
            }
        } else if result.statusCode == 401 {
            mailLog("Токен Mail.ru протух (401)")
            KeychainHelper.delete(key: "mailSessionToken")
            folders = []
            state = .loggedOut
        } else {
            folders = defaultFolders()
        }
        
        isLoadingFolders = false
    }
    
    // =================================================================
    // MARK: - Сообщения
    // =================================================================
    
    func fetchMessages(folderId: String, offset: Int = 0, limit: Int = 50) async {
        isLoadingMessages = true
        currentFolderId = folderId
        errorMessage = nil
        
        let body: [String: Any] = [
            "email_id": folderId,
            "offset": offset,
            "limit": limit,
            "html_part": "prefer",
            "sort": "date",
            "order": "desc",
            "last_modified": 0
        ]
        
        let result = await mailRequest("POST", path: "/messages/list", body: body)
        
        if let data = result.data {
            let inner = unwrapMailRuBody(data)
            
            if let decoded = try? JSONDecoder().decode([MailMessage].self, from: inner) {
                messages = decoded
            } else if let json = try? JSONSerialization.jsonObject(with: inner) as? [String: Any],
                      let msgArray = json["messages"] as? [[String: Any]] {
                messages = parseMessages(msgArray)
                totalMessages = json["total"] as? Int ?? msgArray.count
                let newCount = json["new_count"] as? Int ?? json["unread"] as? Int
                if let nc = newCount { unreadCount = nc }
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let body = json["body"] as? [String: Any],
                      let msgArray = body["messages"] as? [[String: Any]] {
                messages = parseMessages(msgArray)
                totalMessages = body["total"] as? Int ?? msgArray.count
            } else {
                messages = []
            }
        } else {
            messages = []
        }
        
        if unreadCount == 0 {
            unreadCount = messages.filter { !$0.isRead }.count
        }
        
        // Сохраняем ID писем для последующего детекта «новых»
        if folderId == "INBOX" && offset == 0 {
            let currentIDs = Set(messages.map { $0.id })
            if lastSeenMessageIDs.isEmpty {
                // Первый раз — просто запоминаем, не уведомляем
                lastSeenMessageIDs = currentIDs
            } else {
                // Находим новые письма
                let newOnes = currentIDs.subtracting(lastSeenMessageIDs)
                if !newOnes.isEmpty {
                    let newMessages = messages.filter { newOnes.contains($0.id) }
                    await notifyNewMail(newMessages)
                    lastSeenMessageIDs = currentIDs
                }
            }
        }
        
        isLoadingMessages = false
    }
    
    func fetchMessage(id: String) async {
        isLoadingMessage = true
        
        let body: [String: Any] = [
            "email_id": id,
            "html": 1
        ]
        
        let result = await mailRequest("POST", path: "/messages/read", body: body)
        
        if let data = result.data {
            let inner = unwrapMailRuBody(data)
            
            if let decoded = try? JSONDecoder().decode(MailMessage.self, from: inner) {
                currentMessage = decoded
                if let idx = messages.firstIndex(where: { $0.id == id }) {
                    messages[idx] = decoded
                }
            } else if let json = try? JSONSerialization.jsonObject(with: inner) as? [String: Any],
                      let msgDict = json["message"] as? [String: Any] {
                if let msg = parseSingleMessage(msgDict) {
                    currentMessage = msg
                    if let idx = messages.firstIndex(where: { $0.id == id }) {
                        messages[idx] = msg
                    }
                }
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let body = json["body"] as? [String: Any],
                      let msgDict = body["message"] as? [String: Any] {
                if let msg = parseSingleMessage(msgDict) {
                    currentMessage = msg
                    if let idx = messages.firstIndex(where: { $0.id == id }) {
                        messages[idx] = msg
                    }
                }
            }
        }
        
        // Автоматически помечаем как прочитанное
        if let msg = currentMessage, !msg.isRead {
            await markAsRead(messageId: msg.id)
        }
        
        isLoadingMessage = false
    }
    
    // =================================================================
    // MARK: - Поиск
    // =================================================================
    
    func searchMessages(query: String) async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        
        isSearching = true
        searchQuery = query
        
        let body: [String: Any] = [
            "query": query,
            "limit": 50,
            "offset": 0
        ]
        
        let result = await mailRequest("POST", path: "/messages/search", body: body)
        
        if let data = result.data {
            let inner = unwrapMailRuBody(data)
            
            if let json = try? JSONSerialization.jsonObject(with: inner) as? [String: Any],
               let msgArray = json["messages"] as? [[String: Any]] {
                searchResults = parseMessages(msgArray)
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let body = json["body"] as? [String: Any],
                      let msgArray = body["messages"] as? [[String: Any]] {
                searchResults = parseMessages(msgArray)
            } else {
                // Локальный поиск по текущим письмам как фоллбэк
                let q = query.lowercased()
                searchResults = messages.filter {
                    ($0.subject ?? "").lowercased().contains(q) ||
                    ($0.preview ?? "").lowercased().contains(q) ||
                    ($0.from?.name ?? "").lowercased().contains(q) ||
                    ($0.from?.email ?? "").lowercased().contains(q)
                }
            }
        }
        
        isSearching = false
    }
    
    // =================================================================
    // MARK: - Действия с сообщениями
    // =================================================================
    
    func markAsRead(messageId: String) async {
        let body: [String: Any] = [
            "email_ids": [messageId],
            "flags": ["seen": true]
        ]
        _ = await mailRequest("POST", path: "/messages/flags", body: body)
        await fetchMessages(folderId: currentFolderId)
        await refreshTotalUnread()
    }
    
    func markAsUnread(messageId: String) async {
        let body: [String: Any] = [
            "email_ids": [messageId],
            "flags": ["seen": false]
        ]
        _ = await mailRequest("POST", path: "/messages/flags", body: body)
        await fetchMessages(folderId: currentFolderId)
        await refreshTotalUnread()
    }
    
    func toggleRead(message: MailMessage) async {
        let body: [String: Any] = [
            "email_ids": [message.id],
            "flags": ["seen": !message.isRead]
        ]
        _ = await mailRequest("POST", path: "/messages/flags", body: body)
        await fetchMessages(folderId: currentFolderId)
        await refreshTotalUnread()
    }
    
    func toggleStar(message: MailMessage) async {
        let body: [String: Any] = [
            "email_ids": [message.id],
            "flags": ["flagged": !message.isStarred]
        ]
        _ = await mailRequest("POST", path: "/messages/flags", body: body)
        await fetchMessages(folderId: currentFolderId)
    }
    
    func deleteMessage(_ message: MailMessage) async {
        let body: [String: Any] = [
            "email_ids": [message.id]
        ]
        _ = await mailRequest("POST", path: "/messages/delete", body: body)
        await fetchMessages(folderId: currentFolderId)
        await refreshTotalUnread()
    }
    
    func moveMessage(_ message: MailMessage, to folderId: String) async {
        let body: [String: Any] = [
            "email_ids": [message.id],
            "folder_id": folderId
        ]
        _ = await mailRequest("POST", path: "/messages/move", body: body)
        await fetchMessages(folderId: currentFolderId)
    }
    
    func archiveMessage(_ message: MailMessage) async {
        await moveMessage(message, to: "ARCHIVE")
    }
    
    // =================================================================
    // MARK: - Отправка
    // =================================================================
    
    func sendMessage(
        to: [String], cc: [String] = [], bcc: [String] = [],
        subject: String, body: String, htmlBody: String? = nil,
        replyTo: String? = nil, forwardOf: String? = nil,
        attachments: [Data] = [], attachmentNames: [String] = []
    ) async -> Bool {
        let toList = to.map { ["email": $0] as [String: String] }
        let ccList = cc.map { ["email": $0] as [String: String] }
        
        var msgBody: [String: Any] = [
            "to": toList,
            "subject": subject,
            "body": [
                "text": body
            ] as [String: String]
        ]
        
        if !ccList.isEmpty { msgBody["cc"] = ccList }
        if let html = htmlBody {
            var bodyDict = msgBody["body"] as? [String: String] ?? ["text": body]
            bodyDict["html"] = html
            msgBody["body"] = bodyDict
        }
        if let rid = replyTo { msgBody["in_reply_to"] = rid }
        if let fid = forwardOf { msgBody["forward_of"] = fid }
        
        msgBody["send_uid"] = UUID().uuidString
        
        let result = await mailRequest("POST", path: "/messages/send", body: msgBody)
        return result.statusCode == 200
    }
    
    // =================================================================
    // MARK: - Контакты (справочник org.fa.ru)
    // =================================================================
    
    func fetchContacts(query: String = "") async {
        await fetchWorkspaceContacts(query: query)
    }
    
    func fetchWorkspaceContacts(query: String = "") async {
        let cookies = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                cont.resume(returning: cookies.filter { $0.domain.contains("fa.ru") })
            }
        }
        guard !cookies.isEmpty else { return }
        // Гарантируем наличие Bitrix-сессии (BX_ORG_FA_RU_* cookies).
        await NativeAuthManager.ensureBitrixSession()
        // ВАЖНО: для org.fa.ru — только cookies домена org.fa.ru.
        // Все fa.ru cookies (включая KEYCLOAK_IDENTITY ~2KB) дают 8KB+ → nginx 400.
        let orgCookies = cookies.filter { $0.domain.contains("org.fa.ru") }
        let headerFields = HTTPCookie.requestHeaderFields(with: orgCookies)
        
        var urlString = "https://org.fa.ru/bitrix/vuz/api/directory/contacts"
        if !query.isEmpty {
            urlString += "?search=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        }
        
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        // Cookie хедер уже добавлен через headerFields — не используем
        // httpShouldHandleCookies, чтобы URLSession не подменял его своим.
        for (name, value) in headerFields {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("8.135.3", forHTTPHeaderField: "App-Version")
        request.setValue("browser-bitrix", forHTTPHeaderField: "App-Key")
        
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = json["items"] as? [[String: Any]] {
            let newContacts = items.compactMap { item -> MailContact? in
                guard let email = item["email"] as? String else { return nil }
                return MailContact(
                    id: String(item["id"] as? Int ?? 0),
                    name: item["name"] as? String ?? item["fullname"] as? String,
                    email: email,
                    department: item["department"] as? String,
                    position: item["position"] as? String,
                    phone: item["phone"] as? String ?? item["mobile"] as? String
                )
            }
            contacts = newContacts
        }
    }
    
    // =================================================================
    // MARK: - HTTP запросы к Mail.ru API
    // =================================================================
    
    private struct MailResult {
        let data: Data?
        let statusCode: Int
        let error: Error?
    }
    
    /// Извлекает inner body из ответа Mail.ru: { "body": { ... } } → { ... }
    private func unwrapMailRuBody(_ data: Data) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = json["body"] as? [String: Any] else {
            return data
        }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? data
    }
    
    private func mailRequest(_ method: String, path: String, body: [String: Any]? = nil) async -> MailResult {
        let urlString = apiBase + path
        guard let url = URL(string: urlString) else {
            return MailResult(data: nil, statusCode: 0, error: nil)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = true
        
        // Авторизация: сначала пробуем токен из Keychain, потом куки из WebView
        if let token = sessionToken {
            request.setValue("z-c=\(token)", forHTTPHeaderField: "Cookie")
            mailLog("API \(path): используем z-c из Keychain")
        } else {
            let cookies = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
                WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                    cont.resume(returning: cookies.filter { $0.domain.contains("mail.ru") })
                }
            }
            if !cookies.isEmpty {
                let headerFields = HTTPCookie.requestHeaderFields(with: cookies)
                for (name, value) in headerFields {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                mailLog("API \(path): используем \(cookies.count) кук mail.ru")
            } else {
                mailLog("API \(path): нет авторизации")
                return MailResult(data: nil, statusCode: 401, error: nil)
            }
        }
        
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            
            if statusCode == 401 {
                mailLog("API \(path): 401 — очищаем токен")
                KeychainHelper.delete(key: "mailSessionToken")
                state = .loggedOut
            }
            
            return MailResult(data: data, statusCode: statusCode, error: nil)
        } catch {
            mailLog("API \(path): ошибка \(error.localizedDescription)")
            return MailResult(data: nil, statusCode: 0, error: error)
        }
    }
    
    // =================================================================
    // MARK: - Парсинг ответов Mail.ru
    // =================================================================
    
    private func parseFolders(_ array: [[String: Any]]) -> [MailFolder] {
        array.compactMap { dict -> MailFolder? in
            let id = dict["id"] as? String
                ?? (dict["email_id"] as? String)
                ?? (dict["id"] as? Int).map(String.init)
                ?? ""
            
            let sym = dict["sym"] as? String ?? dict["type"] as? String ?? dict["folder_type"] as? String
            
            return MailFolder(
                id: id,
                name: dict["name"] as? String ?? sym ?? id,
                type: sym,
                unreadCount: dict["new_cnt"] as? Int ?? dict["unread_count"] as? Int ?? dict["unread"] as? Int ?? 0,
                totalCount: dict["cnt"] as? Int ?? dict["total_count"] as? Int ?? dict["total"] as? Int ?? 0
            )
        }
    }
    
    private func parseMessages(_ array: [[String: Any]]) -> [MailMessage] {
        array.compactMap { dict -> MailMessage? in
            parseSingleMessage(dict)
        }
    }
    
    private func parseSingleMessage(_ dict: [String: Any]) -> MailMessage? {
        guard let id = dict["id"] as? String
            ?? (dict["id"] as? Int).map(String.init) else { return nil }
        
        let fromDict: [String: Any]? = dict["from"] as? [String: Any]
            ?? (dict["from"] as? [[String: Any]])?.first
        let from = fromDict.map { MailAddress(
            email: $0["email"] as? String ?? "",
            name: $0["name"] as? String
        ) }
        
        let toArray = (dict["to"] as? [[String: Any]])?.compactMap { d in
            MailAddress(email: d["email"] as? String ?? "", name: d["name"] as? String)
        } ?? []
        
        let ccArray = (dict["cc"] as? [[String: Any]])?.compactMap { d in
            MailAddress(email: d["email"] as? String ?? "", name: d["name"] as? String)
        }
        
        let attachArray = (dict["attachments"] as? [[String: Any]])?.compactMap { a -> MailAttachment? in
            guard let attachId = a["id"] as? String
                ?? (a["id"] as? Int).map(String.init) else { return nil }
            return MailAttachment(
                id: attachId,
                filename: a["filename"] as? String ?? a["name"] as? String,
                size: a["size"] as? Int,
                mimeType: a["mime_type"] as? String ?? a["type"] as? String,
                url: a["url"] as? String
            )
        }
        
        let dateVal = dict["date"] as? String ?? dict["created_at"] as? String
        
        return MailMessage(
            id: id,
            from: from,
            to: toArray,
            cc: ccArray,
            bcc: nil,
            subject: dict["subject"] as? String,
            preview: dict["snippet"] as? String ?? dict["preview"] as? String,
            bodyHTML: dict["body_html"] as? String ?? dict["html_body"] as? String,
            bodyText: dict["body_text"] as? String ?? dict["text_body"] as? String,
            date: dateVal,
            isRead: dict["seen"] as? Bool ?? dict["is_read"] as? Bool ?? true,
            isStarred: dict["flagged"] as? Bool ?? dict["is_starred"] as? Bool ?? false,
            isAnswered: dict["answered"] as? Bool ?? dict["is_answered"] as? Bool ?? false,
            isForwarded: dict["forwarded"] as? Bool ?? dict["is_forwarded"] as? Bool ?? false,
            hasAttachments: !(attachArray?.isEmpty ?? true),
            attachments: attachArray,
            folderId: dict["folder_id"] as? String ?? dict["email_id"] as? String,
            inReplyTo: dict["in_reply_to"] as? String,
            references: dict["references"] as? String
        )
    }
    
    // =================================================================
    // MARK: - Дефолтные папки
    // =================================================================
    
    private func defaultFolders() -> [MailFolder] {
        [
            MailFolder(id: "INBOX", name: "Входящие", type: "inbox", unreadCount: 0, totalCount: 0),
            MailFolder(id: "STARRED", name: "Избранные", type: "starred", unreadCount: 0, totalCount: 0),
            MailFolder(id: "SENT", name: "Отправленные", type: "sent", unreadCount: 0, totalCount: 0),
            MailFolder(id: "DRAFTS", name: "Черновики", type: "drafts", unreadCount: 0, totalCount: 0),
            MailFolder(id: "SPAM", name: "Спам", type: "spam", unreadCount: 0, totalCount: 0),
            MailFolder(id: "TRASH", name: "Корзина", type: "trash", unreadCount: 0, totalCount: 0),
            MailFolder(id: "ARCHIVE", name: "Архив", type: "archive", unreadCount: 0, totalCount: 0)
        ]
    }
    
    // =================================================================
    // MARK: - Уведомления о новых письмах
    // =================================================================
    
    private func notifyNewMail(_ newMessages: [MailMessage]) async {
        guard !newMessages.isEmpty else { return }
        
        // Запрашиваем разрешение если ещё не запрошено
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        
        if settings.authorizationStatus == .denied { return }
        
        // Для 1 письма — детальное уведомление
        // Для нескольких — сводное
        if newMessages.count == 1, let msg = newMessages.first {
            let content = UNMutableNotificationContent()
            content.title = msg.displayFrom
            content.body = msg.displaySubject
            content.sound = .default
            content.userInfo = ["messageId": msg.id, "type": "newMail"]
            let request = UNNotificationRequest(
                identifier: "mail-\(msg.id)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        } else {
            let content = UNMutableNotificationContent()
            content.title = "Новые письма: \(newMessages.count)"
            let body = newMessages.prefix(3)
                .map { "• \($0.displayFrom): \($0.displaySubject)" }
                .joined(separator: "\n")
            content.body = body
            content.sound = .default
            content.userInfo = ["type": "newMailBatch"]
            let request = UNNotificationRequest(
                identifier: "mail-batch-\(Int(Date().timeIntervalSince1970))",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
        
        mailLog("Уведомлено о \(newMessages.count) новых письмах")
    }
    
    // =================================================================
    // MARK: - Фоновая проверка
    // =================================================================
    
    #if os(iOS)
    private func registerBackgroundTask() {
        // Защита от повторной регистрации
        guard !Self.backgroundTaskRegistered else {
            print("[BGTask][Mail] Фоновая задача уже зарегистрирована — пропуск")
            return
        }
        Self.backgroundTaskRegistered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { [weak self] task in
            guard let self else { return }
            Task { @MainActor in
                self.handleMailRefresh(task: task as! BGAppRefreshTask)
            }
        }
    }
    
    private func handleMailRefresh(task: BGAppRefreshTask) {
        scheduleNextMailCheck()
        Task { @MainActor in
            await self.refreshFoldersAndUnread()
            // Обновляем виджеты если они используют данные почты
            WidgetCenter.shared.reloadAllTimelines()
            task.setTaskCompleted(success: true)
        }
    }
    
    func scheduleNextMailCheck() {
        // Каждые 15 минут проверяем новые письма
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
    
    // =================================================================
    // MARK: - Выход
    // =================================================================
    
    func logout() {
        KeychainHelper.delete(key: "mailSessionToken")
        let store = WKWebsiteDataStore.default()
        let websiteDataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: websiteDataTypes) { records in
            let mailRecords = records.filter { $0.displayName.contains("mail.ru") }
            store.removeData(ofTypes: websiteDataTypes, for: mailRecords) {}
        }
        
        folders = []
        messages = []
        contacts = []
        currentMessage = nil
        state = .loggedOut
        totalMessages = 0
        unreadCount = 0
        totalUnreadCount = 0
        
        // Сбрасываем badge
        #if canImport(UIKit)
        DispatchQueue.main.async {
            if #available(iOS 16.0, *) {
                UNUserNotificationCenter.current().setBadgeCount(0)
            } else {
                UIApplication.shared.applicationIconBadgeNumber = 0
            }
        }
        #endif
        
        mailLog("Выход из почты Mail.ru выполнен")
    }
}
