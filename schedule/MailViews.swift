// ======================================================================
// MailViews.swift — Полностью нативный UI почтового клиента Mail.ru (e.mail.ru)
// Использует нативные iOS-формы: List, NavigationStack, .searchable, swipeActions
// + Главное окно с папками (sidebar)
// + Список писем (с pull-to-refresh, swipe actions)
// + Детали письма (с HTML-телом, вложениями, действиями)
// + Написание/Ответ/Пересылка (нативная форма)
// + Адресная книга (отдельный NavigationStack)
// + Поиск писем (нативный .searchable)
// ======================================================================

import SwiftUI
import WebKit

// MARK: - Корневой вид почты (4-я вкладка)

struct MailRootView: View {
    @ObservedObject var mailManager = MailManager.shared
    @ObservedObject var authManager = MailAuthManager.shared
    @State private var selectedFolder: MailFolder?
    @State private var selectedMessage: MailMessage?
    @State private var showCompose = false
    @State private var showLogin = false
    @State private var showContacts = false
    @State private var showSearch = false
    @State private var searchText = ""
    @AppStorage("mailDidLogout") private var didExplicitLogout = false
    @AppStorage("mailAutoCheck") private var mailAutoCheck = true
    @AppStorage("mailNotifications") private var mailNotifications = true
    
    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            
            switch mailManager.state {
            case .loggedIn:
                mailContentView
            case .loggedOut:
                if didExplicitLogout {
                    mailLoggedOutView
                } else {
                    mailContentView
                }
            case .unknown:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Загрузка почты...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Почта")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if mailManager.state == .loggedIn {
                    HStack(spacing: 14) {
                        Button {
                            showSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        Button {
                            showContacts = true
                        } label: {
                            Image(systemName: "person.2")
                        }
                        Button {
                            showCompose = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showLogin) {
            MailLoginView(
                onAuthSuccess: {
                    didExplicitLogout = false
                    showLogin = false
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        await mailManager.checkMailSession()
                    }
                }
            )
        }
        .fullScreenCover(isPresented: $showCompose) {
            MailComposeView(
                to: [],
                cc: [],
                subject: "",
                initialBody: "",
                onSend: { to, cc, bcc, subject, body in
                    Task {
                        _ = await mailManager.sendMessage(
                            to: to, cc: cc, bcc: bcc,
                            subject: subject, body: body
                        )
                        showCompose = false
                        if let folder = selectedFolder {
                            await mailManager.fetchMessages(folderId: folder.id)
                        }
                    }
                },
                onDismiss: { showCompose = false }
            )
        }
        .sheet(isPresented: $showContacts) {
            NavigationStack {
                MailAddressBookView()
            }
        }
        .sheet(isPresented: $showSearch) {
            NavigationStack {
                MailSearchView()
            }
        }
        .onAppear {
            if mailManager.state == .loggedOut && !didExplicitLogout {
                Task {
                    await mailManager.checkMailSession()
                }
            }
            // Запрашиваем разрешение на уведомления при первом открытии
            if mailNotifications {
                Task {
                    let center = UNUserNotificationCenter.current()
                    let settings = await center.notificationSettings()
                    if settings.authorizationStatus == .notDetermined {
                        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                    }
                }
            }
        }
    }
    
    // MARK: - Основной контент с папками и сообщениями
    
    private var mailContentView: some View {
        HStack(spacing: 0) {
            mailSidebar
            
            // Список сообщений
            if let folder = selectedFolder {
                MailMessageListView(folder: folder)
            } else {
                // Если есть папки — открываем входящие по умолчанию
                if let inbox = mailManager.folders.first(where: { $0.type == "inbox" }) {
                    MailMessageListView(folder: inbox)
                        .onAppear { selectedFolder = inbox }
                } else {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "tray.inbox")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("Выберите папку")
                            .font(.title3.bold())
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }
    
    // MARK: - Сайдбар с папками
    
    private var mailSidebar: some View {
        List {
            // Кнопка входа если не авторизован
            if mailManager.state == .loggedOut {
                Section {
                    Button {
                        showLogin = true
                    } label: {
                        HStack {
                            Image(systemName: "lock.circle")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Войти в почту")
                                    .font(.subheadline.bold())
                                Text("Mail.ru для бизнеса")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Папки
            Section {
                ForEach(mailManager.folders) { folder in
                    Button {
                        selectedFolder = folder
                        Task {
                            await mailManager.fetchMessages(folderId: folder.id)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: folder.icon)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(selectedFolder?.id == folder.id ? .accentColor : .secondary)
                                .frame(width: 24)
                            
                            Text(folder.displayName)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            
                            Spacer()
                            
                            if folder.hasUnread {
                                Text("\(folder.unreadCount)")
                                    .font(.caption2.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor, in: Circle())
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(selectedFolder?.id == folder.id ? Color.accentColor.opacity(0.1) : Color.clear)
                }
            }
            
            // Ссылка на полный клиент
            if mailManager.state == .loggedIn {
                Section {
                    Link(destination: URL(string: "https://e.mail.ru/inbox")!) {
                        HStack {
                            Image(systemName: "safari.fill")
                                .foregroundColor(.blue)
                            Text("Открыть в веб-версии")
                                .font(.subheadline)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                
                // Кнопка выхода
                Section {
                    Button(role: .destructive) {
                        Task {
                            await MainActor.run {
                                authManager.logout()
                                didExplicitLogout = true
                            }
                        }
                    } label: {
                        Label("Выйти из почты", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.sidebar)
        #endif
        .scrollContentBackground(.hidden)
    }
    
    // MARK: - Экран «не авторизован»
    
    private var mailLoggedOutView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "envelope.circle")
                .font(.system(size: 64))
                .foregroundColor(.secondary.opacity(0.5))
            
            VStack(spacing: 8) {
                Text("Корпоративная почта")
                    .font(.title2.bold())
                Text("Mail.ru для бизнеса")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            // Преимущества
            VStack(alignment: .leading, spacing: 14) {
                Label("Просмотр писем без браузера", systemImage: "envelope.open.fill")
                Label("Уведомления о новых письмах", systemImage: "bell.badge.fill")
                Label("Чтение, ответ и пересылка", systemImage: "arrowshape.turn.up.left.fill")
                Label("Поиск по почте", systemImage: "magnifyingglass")
                Label("Адресная книга университета", systemImage: "person.2.fill")
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            .padding(.horizontal, 32)
            
            Button {
                showLogin = true
            } label: {
                HStack {
                    Image(systemName: "envelope.open.fill")
                    Text("Войти в почту")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.white)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 40)
            
            Link(destination: URL(string: "https://e.mail.ru/inbox")!) {
                Text("Открыть почту в браузере")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .underline()
            }
            
            Spacer()
        }
    }
}

// ======================================================================
// MARK: - Список сообщений
// ======================================================================

struct MailMessageListView: View {
    let folder: MailFolder
    @ObservedObject var mailManager = MailManager.shared
    @State private var selectedMessageId: String?
    @State private var showDetail = false
    @State private var navigatedMessageId: String?

    var body: some View {
        SwiftUI.Group {
            if mailManager.isLoadingMessages && mailManager.messages.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Загрузка...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else if mailManager.messages.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: folder.icon)
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("Нет писем")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    if folder.type == "inbox" {
                        Text("В этой папке пока нет входящих писем")
                            .font(.subheadline)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    Spacer()
                }
            } else {
                List {
                    ForEach(mailManager.messages) { message in
                        Button {
                            selectedMessageId = message.id
                            navigatedMessageId = message.id
                            showDetail = true
                        } label: {
                            MailMessageRow(message: message)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading) {
                            if !message.isRead {
                                Button {
                                    Task { await mailManager.toggleRead(message: message) }
                                } label: {
                                    Label("Прочитано", systemImage: "envelope.open")
                                }
                                .tint(.blue)
                            } else {
                                Button {
                                    Task { await mailManager.toggleRead(message: message) }
                                } label: {
                                    Label("Непрочитано", systemImage: "envelope")
                                }
                                .tint(.gray)
                            }
                            Button {
                                Task { await mailManager.toggleStar(message: message) }
                            } label: {
                                Label(message.isStarred ? "Убрать" : "Избранное", systemImage: message.isStarred ? "star.slash" : "star")
                            }
                            .tint(.yellow)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await mailManager.deleteMessage(message) }
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                            Button {
                                Task { await mailManager.archiveMessage(message) }
                            } label: {
                                Label("Архив", systemImage: "archivebox")
                            }
                            .tint(.gray)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationDestination(isPresented: $showDetail) {
            if let msgId = navigatedMessageId {
                MailMessageDetailView(messageId: msgId, folder: folder)
            }
        }
        .onAppear {
            if mailManager.currentFolderId != folder.id || mailManager.messages.isEmpty {
                Task { await mailManager.fetchMessages(folderId: folder.id) }
            }
        }
        .refreshable {
            await mailManager.fetchMessages(folderId: folder.id)
            await mailManager.refreshTotalUnread()
        }
    }
}

// ======================================================================
// MARK: - Строка сообщения (нативный стиль Mail.app)
// ======================================================================

struct MailMessageRow: View {
    let message: MailMessage
    
    var body: some View {
        HStack(spacing: 12) {
            // Аватар отправителя
            ZStack {
                Circle()
                    .fill(message.isRead ? Color(.secondarySystemGroupedBackground) : Color.accentColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                Text(String(message.displayFrom.prefix(1)).uppercased())
                    .font(.system(size: 16, weight: message.isRead ? .regular : .semibold))
                    .foregroundColor(message.isRead ? .secondary : .accentColor)
            }
            
            // Контент
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(message.displayFrom)
                        .font(.system(size: 15, weight: message.isRead ? .regular : .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text(message.displayDate)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Text(message.displaySubject)
                    .font(.system(size: 14, weight: message.isRead ? .regular : .medium))
                    .foregroundColor(message.isRead ? .secondary : .primary)
                    .lineLimit(1)
                
                HStack {
                    Text(message.displayPreview)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if message.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if message.isStarred {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .opacity(message.isRead ? 0.85 : 1.0)
    }
}

// ======================================================================
// MARK: - Детали сообщения
// ======================================================================

struct MailMessageDetailView: View {
    let messageId: String
    let folder: MailFolder
    @ObservedObject var mailManager = MailManager.shared
    @State private var message: MailMessage?
    @State private var showReplySheet = false
    @State private var showForwardSheet = false
    @State private var replyMode: ReplyMode = .reply
    @State private var showMoveSheet = false
    
    enum ReplyMode {
        case reply, replyAll, forward
    }
    
    var body: some View {
        SwiftUI.Group {
            if let msg = message {
                messageContent(msg)
            } else if mailManager.isLoadingMessage {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Загрузка письма...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Письмо не найдено")
                    .foregroundColor(.secondary)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    replyMode = .reply
                    showReplySheet = true
                } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                }
                .disabled(message == nil)
                
                Button {
                    replyMode = .replyAll
                    showReplySheet = true
                } label: {
                    Image(systemName: "arrowshape.turn.up.left.2")
                }
                .disabled(message == nil)
                
                Button {
                    replyMode = .forward
                    showForwardSheet = true
                } label: {
                    Image(systemName: "arrowshape.turn.up.right")
                }
                .disabled(message == nil)
                
                Spacer()
                
                Button {
                    if let msg = message {
                        Task { await mailManager.toggleStar(message: msg) }
                    }
                } label: {
                    Image(systemName: message?.isStarred == true ? "star.fill" : "star")
                        .foregroundColor(message?.isStarred == true ? .yellow : .secondary)
                }
                
                Menu {
                    Button {
                        showMoveSheet = true
                    } label: {
                        Label("Переместить", systemImage: "folder")
                    }
                    Button(role: .destructive) {
                        if let msg = message {
                            Task { await mailManager.deleteMessage(msg) }
                        }
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { showReplySheet || showForwardSheet },
            set: { if !$0 { showReplySheet = false; showForwardSheet = false } }
        )) {
            if let msg = message {
                MailComposeView(
                    to: replyMode == .forward ? [] : [msg.from?.email ?? ""],
                    cc: replyMode == .replyAll ? (msg.cc ?? []).map { $0.email } : [],
                    subject: replyMode == .forward
                        ? "Fwd: \(msg.displaySubject)"
                        : (msg.displaySubject.hasPrefix("Re:") ? "" : "Re: ") + msg.displaySubject,
                    initialBody: replyMode == .forward
                        ? "\n\n---------- Переслано ----------\nОт: \(msg.displayFrom)\nДата: \(msg.displayDate)\nТема: \(msg.displaySubject)\n\n\(msg.bodyText ?? msg.displayPreview)"
                        : "\n\n\(msg.displayFrom) wrote:\n> \(msg.displayPreview)",
                    onSend: { to, cc, bcc, subject, body in
                        Task {
                            let replyToId = replyMode != .forward ? msg.id : nil
                            let forwardId = replyMode == .forward ? msg.id : nil
                            _ = await mailManager.sendMessage(
                                to: to, cc: cc, bcc: bcc,
                                subject: subject, body: body,
                                replyTo: replyToId,
                                forwardOf: forwardId
                            )
                            showReplySheet = false
                            showForwardSheet = false
                            await mailManager.fetchMessages(folderId: folder.id)
                        }
                    },
                    onDismiss: { showReplySheet = false; showForwardSheet = false }
                )
            }
        }
        .sheet(isPresented: $showMoveSheet) {
            NavigationStack {
                List {
                    ForEach(mailManager.folders) { folder in
                        Button {
                            if let msg = message {
                                Task { await mailManager.moveMessage(msg, to: folder.id) }
                            }
                            showMoveSheet = false
                        } label: {
                            HStack {
                                Image(systemName: folder.icon)
                                    .foregroundColor(.accentColor)
                                Text(folder.displayName)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .navigationTitle("Переместить в")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Отмена") { showMoveSheet = false }
                    }
                }
            }
        }
        .onAppear {
            Task { await mailManager.fetchMessage(id: messageId) }
        }
        .onChange(of: mailManager.currentMessage) { _, newValue in
            if newValue?.id == messageId {
                message = newValue
            }
        }
    }
    
    @ViewBuilder
    private func messageContent(_ msg: MailMessage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Заголовок
                Text(msg.displaySubject)
                    .font(.title2.bold())
                    .padding(.top, 8)
                
                // Отправитель и дата
                HStack(alignment: .top) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Text(String(msg.displayFrom.prefix(1)).uppercased())
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(msg.displayFrom)
                            .font(.headline)
                        Text(msg.from?.email ?? "")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Text(msg.displayDate)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                // Получатели
                if !msg.to.isEmpty {
                    HStack {
                        Text("Кому:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(msg.to.map { $0.displayName }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                if let cc = msg.cc, !cc.isEmpty {
                    HStack {
                        Text("Копия:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(cc.map { $0.displayName }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Divider()
                
                // Тело письма
                if let html = msg.bodyHTML {
                    #if os(iOS)
                    MailHTMLView(htmlString: html)
                        .frame(minHeight: 300)
                    #else
                    Text(msg.bodyText ?? "")
                        .font(.body)
                    #endif
                } else {
                    Text(msg.bodyText ?? msg.displayPreview)
                        .font(.body)
                        .lineSpacing(6)
                }
                
                // Вложения
                if let attachments = msg.attachments, !attachments.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Вложения (\(attachments.count))")
                            .font(.subheadline.bold())
                        
                        ForEach(attachments) { attachment in
                            HStack {
                                Image(systemName: attachmentIcon(for: attachment.mimeType))
                                    .font(.system(size: 20))
                                    .foregroundColor(.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(attachment.filename ?? "Файл")
                                        .font(.subheadline)
                                    if !attachment.displaySize.isEmpty {
                                        Text(attachment.displaySize)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "arrow.down.circle")
                                    .foregroundColor(.secondary)
                            }
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                
                Spacer(minLength: 80)
            }
            .padding(.horizontal, 16)
        }
    }
    
    private func attachmentIcon(for mimeType: String?) -> String {
        guard let mt = mimeType?.lowercased() else { return "doc" }
        if mt.hasPrefix("image/") { return "photo" }
        if mt.hasPrefix("video/") { return "video" }
        if mt.hasPrefix("audio/") { return "music.note" }
        if mt.contains("pdf") { return "doc.richtext" }
        if mt.contains("zip") || mt.contains("rar") { return "archivebox" }
        return "doc"
    }
}

// ======================================================================
// MARK: - HTML рендеринг письма
// ======================================================================

#if canImport(UIKit)
struct MailHTMLView: UIViewRepresentable {
    let htmlString: String
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        let styledHTML = """
        <html><head><meta name='viewport' content='width=device-width, initial-scale=1.0'>
        <style>
            body { font-family: -apple-system, system-ui, sans-serif; font-size: 15px; 
                   color: \(UIColor.label.isDark ? "#fff" : "#000"); 
                   line-height: 1.6; padding: 0; margin: 0; 
                   -webkit-text-size-adjust: none; }
            a { color: #007AFF; }
            img { max-width: 100%; height: auto; }
            pre, code { font-size: 13px; background: rgba(128,128,128,0.12); padding: 2px 4px; border-radius: 4px; }
            blockquote { border-left: 3px solid #ccc; margin-left: 0; padding-left: 12px; color: #666; }
            table { max-width: 100%; }
        </style></head><body>\(htmlString)</body></html>
        """
        uiView.loadHTMLString(styledHTML, baseURL: nil)
    }
    
    func makeCoordinator() -> Coordinator { Coordinator() }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body.scrollHeight") { height, _ in
                if let h = height as? CGFloat {
                    webView.frame.size.height = h
                    webView.invalidateIntrinsicContentSize()
                }
            }
        }
    }
}

private extension UIColor {
    var isDark: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r * 0.299 + g * 0.587 + b * 0.114) < 0.5
    }
}
#endif

// ======================================================================
// MARK: - Написание письма (нативная форма)
// ======================================================================

struct MailComposeView: View {
    let to: [String]
    let cc: [String]
    let subject: String
    let initialBody: String
    let onSend: ([String], [String], [String], String, String) -> Void
    let onDismiss: () -> Void
    
    @ObservedObject var mailManager = MailManager.shared
    @State private var toText = ""
    @State private var ccText = ""
    @State private var bccText = ""
    @State private var subjectText = ""
    @State private var bodyText = ""
    @State private var showCC = false
    @State private var showBCC = false
    @State private var showAddressBook = false
    @State private var addressBookTarget = AddressTarget.to
    @State private var isSending = false
    @State private var contactSearch = ""
    @FocusState private var focusedField: ComposeField?
    
    enum ComposeField {
        case to, cc, bcc, subject, emailBody
    }
    
    enum AddressTarget {
        case to, cc, bcc
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Поля заголовка
                VStack(spacing: 0) {
                    // Кому
                    composeFieldRow(label: "Кому", text: $toText, field: .to)
                    
                    if showCC {
                        composeFieldRow(label: "Копия", text: $ccText, field: .cc)
                    }
                    
                    if showBCC {
                        composeFieldRow(label: "Скрытая", text: $bccText, field: .bcc)
                    }
                    
                    // Кнопки CC/BCC
                    if !showCC || !showBCC {
                        HStack(spacing: 16) {
                            if !showCC {
                                Button("Копия (CC)") {
                                    withAnimation { showCC = true }
                                }
                                .font(.caption)
                                .foregroundColor(.accentColor)
                            }
                            if !showBCC {
                                Button("Скрытая (BCC)") {
                                    withAnimation { showBCC = true }
                                }
                                .font(.caption)
                                .foregroundColor(.accentColor)
                            }
                            Spacer()
                            Button {
                                addressBookTarget = .to
                                showAddressBook = true
                                Task { await mailManager.fetchWorkspaceContacts() }
                            } label: {
                                Image(systemName: "person.2")
                                    .font(.system(size: 14))
                            }
                            .foregroundColor(.accentColor)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                    
                    Divider()
                    
                    // Тема
                    HStack {
                        Text("Тема")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                        TextField("Тема письма", text: $subjectText)
                            .font(.body)
                            .focused($focusedField, equals: .subject)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    
                    Divider()
                    
                    // Тело письма
                    TextEditor(text: $bodyText)
                        .font(.body)
                        .focused($focusedField, equals: .emailBody)
                        .padding(.horizontal, 8)
                    
                    Spacer()
                }
                .background(Color(.systemBackground))
            }
            .navigationTitle("Новое письмо")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        send()
                    } label: {
                        HStack(spacing: 6) {
                            if isSending {
                                ProgressView().controlSize(.small).tint(.white)
                            }
                            Text("Отправить")
                        }
                    }
                    .disabled(!canSend || isSending)
                    .fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $showAddressBook) {
            NavigationStack {
                MailAddressBookPicker(
                    searchText: $contactSearch,
                    onSelect: { contact in
                        let email = contact.email ?? ""
                        switch addressBookTarget {
                        case .to:
                            toText = appendAddress(toText, email)
                        case .cc:
                            ccText = appendAddress(ccText, email)
                        case .bcc:
                            bccText = appendAddress(bccText, email)
                        }
                        showAddressBook = false
                    }
                )
                .searchable(text: $contactSearch, prompt: "Поиск контактов")
                .onChange(of: contactSearch) { _, newValue in
                    Task { await mailManager.fetchWorkspaceContacts(query: newValue) }
                }
            }
        }
        .onAppear {
            toText = to.joined(separator: ", ")
            ccText = cc.joined(separator: ", ")
            subjectText = subject
            bodyText = initialBody
        }
    }
    
    private func composeFieldRow(label: String, text: Binding<String>, field: ComposeField) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 64, alignment: .leading)
            
            TextField("Адрес", text: text)
                .font(.body)
                .focused($focusedField, equals: field)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
            
            Button {
                addressBookTarget = field == .cc ? .cc : (field == .bcc ? .bcc : .to)
                showAddressBook = true
                Task { await mailManager.fetchWorkspaceContacts() }
            } label: {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 14))
            }
            .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    private var canSend: Bool {
        !toText.trimmingCharacters(in: .whitespaces).isEmpty
    }
    
    private func send() {
        isSending = true
        let recipients = parseAddresses(toText)
        let ccRecipients = parseAddresses(ccText)
        let bccRecipients = parseAddresses(bccText)
        
        onSend(recipients, ccRecipients, bccRecipients, subjectText, bodyText)
    }
    
    private func parseAddresses(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("@") }
    }
    
    private func appendAddress(_ current: String, _ new: String) -> String {
        if current.isEmpty { return new }
        return current + ", " + new
    }
}

// ======================================================================
// MARK: - Адресная книга
// ======================================================================

struct MailAddressBookView: View {
    @ObservedObject var mailManager = MailManager.shared
    @State private var searchText = ""
    @State private var isLoading = false
    
    var body: some View {
        SwiftUI.Group {
            if mailManager.contacts.isEmpty && !isLoading {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "person.2")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("Справочник пуст")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Загрузите контакты из университета")
                        .font(.subheadline)
                        .foregroundColor(.secondary.opacity(0.7))
                    
                    Button {
                        Task {
                            isLoading = true
                            await mailManager.fetchWorkspaceContacts()
                            isLoading = false
                        }
                    } label: {
                        Text("Загрузить контакты")
                            .font(.subheadline.bold())
                            .foregroundColor(.accentColor)
                    }
                    Spacer()
                }
            } else {
                List {
                    ForEach(filteredContacts) { contact in
                        ContactRow(contact: contact)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Контакты")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $searchText, prompt: "Поиск контактов")
        .onChange(of: searchText) { _, newValue in
            Task { await mailManager.fetchWorkspaceContacts(query: newValue) }
        }
        .task {
            if mailManager.contacts.isEmpty {
                isLoading = true
                await mailManager.fetchWorkspaceContacts()
                isLoading = false
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await mailManager.fetchWorkspaceContacts() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }
    
    private var filteredContacts: [MailContact] {
        if searchText.isEmpty { return mailManager.contacts }
        return mailManager.contacts.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(searchText) ||
            ($0.email ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }
}

struct ContactRow: View {
    let contact: MailContact
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 40, height: 40)
                Text(String(contact.displayName.prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(contact.displayName)
                    .font(.subheadline.bold())
                Text(contact.email ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let dept = contact.department {
                    Text(dept)
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
            Spacer()
            
            if let phone = contact.phone, !phone.isEmpty {
                Image(systemName: "phone")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// ======================================================================
// MARK: - Пикер контактов
// ======================================================================

struct MailAddressBookPicker: View {
    @Binding var searchText: String
    let onSelect: (MailContact) -> Void
    @ObservedObject var mailManager = MailManager.shared
    
    var body: some View {
        SwiftUI.Group {
            if mailManager.contacts.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Загрузка контактов...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                List(mailManager.contacts) { contact in
                    Button {
                        onSelect(contact)
                    } label: {
                        ContactRow(contact: contact)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Выбрать контакт")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// ======================================================================
// MARK: - Экран поиска писем
// ======================================================================

struct MailSearchView: View {
    @ObservedObject var mailManager = MailManager.shared
    @State private var searchText = ""
    @State private var hasSearched = false
    
    var body: some View {
        VStack(spacing: 0) {
            if mailManager.isSearching {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text("Поиск...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else if mailManager.searchResults.isEmpty && hasSearched {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("Ничего не найдено")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else if !mailManager.searchResults.isEmpty {
                List {
                    ForEach(mailManager.searchResults) { message in
                        NavigationLink {
                            MailMessageDetailView(messageId: message.id, folder: MailFolder(id: "SEARCH", name: "Поиск", type: nil, unreadCount: 0, totalCount: 0))
                        } label: {
                            MailMessageRow(message: message)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("Введите запрос для поиска")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .navigationTitle("Поиск писем")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $searchText, prompt: "Поиск по почте...")
        .onChange(of: searchText) { _, newValue in
            hasSearched = !newValue.isEmpty
            Task { await mailManager.searchMessages(query: newValue) }
        }
    }
}

// ======================================================================
// MARK: - Экран входа в почту
// ======================================================================

struct MailLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    
    var onAuthSuccess: (() -> Void)?
    
    var body: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()
                
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Загрузка страницы входа...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                
                if let error = errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.red.opacity(0.7))
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Повторить") {
                            errorMessage = nil
                            isLoading = false
                        }
                        .font(.subheadline.bold())
                        .foregroundColor(.accentColor)
                    }
                    .padding(.horizontal, 40)
                }
                
                MailAuthWebView(
                    onAuthSuccess: {
                        onAuthSuccess?()
                    },
                    onError: { msg in
                        errorMessage = msg
                    },
                    isLoading: $isLoading
                )
                .opacity(isLoading ? 0 : 1)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(Circle())
                    }
                }
            }
        }
    }
}
