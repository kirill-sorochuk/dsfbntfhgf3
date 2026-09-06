import SwiftUI
import WebKit

// MARK: - Уведомления

struct LKNotificationsView: View {
    @ObservedObject var manager = LKManager.shared
    @State private var notifications: [NotificationItem] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String? = nil

    var body: some View {
        SwiftUI.Group {
            if isLoading {
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView()
                        .controlSize(.large)
                    Text("Загрузка уведомлений...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else if !hasLoaded {
                VStack(spacing: 16) {
                    Spacer()
                    Button {
                        loadNotifications()
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary.opacity(0.5))
                            Text("Загрузить уведомления")
                                .font(.headline)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Spacer()
                }
            } else if let error = errorMessage, notifications.isEmpty {
                // Ошибка загрузки + кнопка повторить
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange.opacity(0.7))
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("Повторить") {
                        loadNotifications()
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
            } else if notifications.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "bell.slash")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("Уведомлений нет")
                        .font(.title3.bold())
                        .foregroundStyle(.secondary)
                    Text("Здесь будут отображаться важные уведомления из личного кабинета.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Spacer()
                }
            } else {
                notificationList
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Уведомления")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if !hasLoaded {
                loadNotifications()
            }
        }
        .refreshable {
            await refreshNotifications()
        }
    }

    // MARK: - Список

    private var notificationList: some View {
        List {
            ForEach(notifications) { notification in
                NotificationRowView(notification: notification)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
    }

    // MARK: - Загрузка

    private func loadNotifications() {
        isLoading = true
        errorMessage = nil
        Task {
            await fetchNotifications()
            hasLoaded = true
            isLoading = false
        }
    }

    private func refreshNotifications() async {
        await fetchNotifications()
        hasLoaded = true
    }

    private func fetchNotifications() async {
        let cookies = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                cont.resume(returning: cookies)
            }
        }
        let faCookies = cookies.filter { $0.domain.contains("fa.ru") }
        guard !faCookies.isEmpty else {
            await MainActor.run { notifications = [] }
            return
        }
        // Гарантируем наличие Bitrix-сессии (BX_ORG_FA_RU_* cookies).
        await NativeAuthManager.ensureBitrixSession()
        // ВАЖНО: для org.fa.ru — только cookies домена org.fa.ru.
        // Все fa.ru cookies (включая KEYCLOAK_IDENTITY ~2KB) дают 8KB+ → nginx 400.
        let orgCookies = faCookies.filter { $0.domain.contains("org.fa.ru") }
        let headerFields = HTTPCookie.requestHeaderFields(with: orgCookies)

        let urlCandidates = [
            "https://org.fa.ru/bitrix/vuz/api/notifications/",
            "https://lk.fa.ru/api/notifications"
        ]

        var result: [NotificationItem]? = nil

        for urlString in urlCandidates {
            guard let url = URL(string: urlString) else { continue }
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
                  http.statusCode == 200 else { continue }

            if let decoded = try? JSONDecoder().decode([NotificationItem].self, from: data) {
                result = decoded
                break
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["items"] as? [[String: Any]] {
                let parsed = items.compactMap { NotificationItem.from(dict: $0) }
                if !parsed.isEmpty {
                    result = parsed
                    break
                }
            }
        }

        await MainActor.run {
            if let items = result {
                notifications = items.sorted { a, b in
                    (b.date ?? "") > (a.date ?? "")
                }
            } else {
                errorMessage = "Не удалось загрузить уведомления"
            }
        }
    }
}

// MARK: - Модель уведомления

struct NotificationItem: Identifiable, Codable {
    let id: Int
    let title: String?
    let text: String?
    let date: String?
    let isRead: Bool?
    let type: String?

    var displayTitle: String {
        (title ?? "Уведомление").unicodeDecoded
    }

    var displayText: String {
        (text ?? "").unicodeDecoded
    }

    var formattedDate: String? {
        guard let dateStr = date else { return nil }
        let input = DateFormatter()
        input.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let d = input.date(from: dateStr) {
            let output = DateFormatter()
            output.locale = Locale(identifier: "ru_RU")
            output.dateStyle = .medium
            output.timeStyle = .short
            return output.string(from: d)
        }
        input.dateFormat = "yyyy-MM-dd"
        if let d2 = input.date(from: String(dateStr.prefix(10))) {
            let output = DateFormatter()
            output.locale = Locale(identifier: "ru_RU")
            output.dateFormat = "dd.MM.yyyy"
            return output.string(from: d2)
        }
        return dateStr
    }

    static func from(dict: [String: Any]) -> NotificationItem? {
        guard let id = dict["id"] as? Int ?? (dict["ID"] as? String).flatMap(Int.init) else {
            return nil
        }
        return NotificationItem(
            id: id,
            title: dict["title"] as? String ?? dict["NAME"] as? String,
            text: dict["text"] as? String ?? dict["PREVIEW_TEXT"] as? String,
            date: dict["date"] as? String ?? dict["DATE_CREATE"] as? String,
            isRead: dict["isRead"] as? Bool ?? (dict["READ"] as? String == "Y"),
            type: dict["type"] as? String
        )
    }
}

// MARK: - Строка уведомления

struct NotificationRowView: View {
    let notification: NotificationItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !(notification.isRead ?? true) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                }

                Text(notification.displayTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer()
            }

            if !notification.displayText.isEmpty {
                Text(notification.displayText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if let date = notification.formattedDate {
                Text(date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
