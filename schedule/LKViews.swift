import SwiftUI
import WebKit

// MARK: - Загрузка изображения с cookies (для аватара ЛК)

struct CookieImage: View {
    let url: URL
    let size: CGFloat
    @State private var uiImage: UIImage?
    @State private var isLoading = false

    var body: some View {
        SwiftUI.Group {
            if let uiImage = uiImage {
                Image(uiImage: uiImage).resizable().scaledToFill()
            } else if isLoading {
                ProgressView()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: size * 0.78))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
        .task {
            guard url.absoluteString != "about:blank",
                  url.scheme == "http" || url.scheme == "https" else { return }
            let userId = extractUserId(from: url)
            if let userId, let cachedData = PhotoCache.load(for: userId),
               let cachedImg = UIImage(data: cachedData) {
                self.uiImage = cachedImg
                return
            }
            await loadImage(userId: userId)
        }
    }

    private func extractUserId(from url: URL) -> String? {
        let path = url.path
        let components = path.components(separatedBy: "/")
        for comp in components.reversed() {
            if let num = Int(comp) { return String(num) }
        }
        return nil
    }

    private func loadImage(userId: String?) async {
        isLoading = true
        let cookies = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                cont.resume(returning: cookies)
            }
        }
        let faCookies = cookies.filter { $0.domain.contains("fa.ru") }
        let headerFields = HTTPCookie.requestHeaderFields(with: faCookies)

        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = true
        for (name, value) in headerFields {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("https://lk.fa.ru", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        if let (data, _) = try? await URLSession.shared.data(for: request),
           let img = UIImage(data: data) {
            self.uiImage = img
            if let userId { PhotoCache.save(imageData: data, for: userId) }
        }
        isLoading = false
    }
}

// MARK: - Профиль (стиль Fitness-приложения)

struct LKRootView: View {
    @StateObject private var manager = LKManager.shared
    @EnvironmentObject private var scheduleVM: ScheduleViewModel
    @State private var showLogin = false
    @State private var isCheckingSession = false
    @State private var didJustLogin = false
    @AppStorage("iconColorMode") private var iconColorMode = "accent"

    private var hasCachedGradebook: Bool {
        UserDefaults(suiteName: "group.com.schedule.ruz")?.bool(forKey: "cachedGradebook") ?? false
    }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            if didJustLogin {
                // После авторизации — показываем загрузку пока проверяем сессию
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Загрузка профиля...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                switch manager.state {
                case .loggedIn:
                    profileContentView
                case .loggedOut:
                    // Если пользователь сам вышел — показываем экран входа.
                    // Если сессия истекла (но не по явному выходу) И есть кеш —
                    // показываем профиль с кеша + баннер "Сессия истекла".
                    if manager.didExplicitLogout || !manager.hasCachedProfileData {
                        loggedOutView
                    } else {
                        profileContentView
                    }
                case .unknown:
                    Spacer()
                    ProgressView("\u{041f}\u{0440}\u{043e}\u{0432}\u{0435}\u{0440}\u{044f}\u{0435}\u{043c} \u{0441}\u{0435}\u{0441}\u{0441}\u{0438}\u{044e}...")
                    Spacer()
                }
            }
        }
        .navigationTitle("Профиль")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if manager.state == .loggedIn || manager.hasCachedProfileData {
                    Button {
                        Task {
                            await manager.refreshSession()
                            if manager.state == .loggedIn {
                                await manager.loadAllData()
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .onAppear {
            // Тихо перепроверяем сессию при появлении вкладки
            if manager.state == .loggedIn {
                Task {
                    if let s = await manager.probeSession(), s.user != nil {
                        manager.session = s
                        manager.lastSessionCheck = Date()
                    }
                }
            }
        }
        .sheet(isPresented: $showLogin) {
            NativeLoginView(
                onAuthSuccess: {
                    didJustLogin = true
                    manager.didExplicitLogout = false
                    UserDefaults.standard.set(false, forKey: "lkDidExplicitLogout")
                    showLogin = false
                    Task {
                        // Синхронизируем куки из HTTPCookieStorage в WKWebView
                        await LKManager.syncCookiesToWKWebView()
                        // Даём время на обработку кук
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        // ВАЖНО: дожидаемся Bitrix SSO handshake ПЕРЕД загрузкой данных.
                        // fetchBitrixProfile / fetchOrders / fetchStudentCard и др. требуют
                        // BX_ORG_FA_RU_* cookies, которые появляются только после handshake.
                        // Handshake уже запущен fire-and-forget в fetchSessionAndFinish(),
                        // но если его не дождаться — первые запросы уйдут без cookies и
                        // получат 401, что вызовет retry, но race condition может привести
                        // к тому, что cookies не подхватятся вовремя.
                        await NativeAuthManager.ensureBitrixSession()
                        // Перепроверяем сессию и подгружаем данные
                        await manager.checkSession()
                        // Запускаем периодическую проверку
                        manager.startSessionKeepalive()
                        didJustLogin = false
                    }
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
        }
    }

    // MARK: - Профиль (основной контент)

    private var profileContentView: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Аватар + имя + университет
                profileHeader

                // Баннер истёкшей сессии
                if manager.state == .loggedOut && !manager.didExplicitLogout {
                    sessionExpiredBanner
                }

                // Сетка меню (стиль Fitness)
                menuGrid

                // Кнопка «Выйти»
                logoutButton
                    .padding(.bottom, 24)
            }
            .padding(.top, 8)
        }
        .refreshable {
            // Тихо перепроверяем сессию
            if let s = await manager.probeSession(), s.user != nil {
                manager.session = s
                manager.lastSessionCheck = Date()
                await manager.loadAllData()
            } else if manager.state != .loggedIn {
                // Сессия истекла — перепроверяем с UI
                await manager.checkSession()
            }
        }
    }

    // MARK: - Шапка профиля

    private var profileHeader: some View {
        VStack(spacing: 10) {
            if let avatarURL = manager.session?.avatarURL,
               avatarURL.scheme == "http" || avatarURL.scheme == "https" {
                CookieImage(url: avatarURL, size: 84)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 84))
                    .foregroundColor(.secondary)
            }

            Text(manager.session?.fullName ?? "Студент")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("\u{0424}\u{0438}\u{043d}\u{0430}\u{043d}\u{0441}\u{043e}\u{0432}\u{044b}\u{0439} \u{0443}\u{043d}\u{0438}\u{0432}\u{0435}\u{0440}\u{0441}\u{0438}\u{0442}\u{0435}\u{0442}")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let group = manager.session?.studentGroup, !group.isEmpty {
                Text(group)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.accentColor)
            }

            if manager.state == .loggedOut && !manager.didExplicitLogout {
                Text("Сессия истекла")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Баннер истёкшей сессии (пробует восстановить, иначе открывает вход)

    private var sessionExpiredBanner: some View {
        Button {
            restoreSession()
        } label: {
            HStack(spacing: 10) {
                if isCheckingSession {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\u{0421}\u{0435}\u{0441}\u{0441}\u{0438}\u{044f} \u{0438}\u{0441}\u{0442}\u{0435}\u{043a}\u{043b}\u{0430}")
                        .font(.system(size: 14, weight: .semibold))
                    Text("\u{041d}\u{0430}\u{0436}\u{043c}\u{0438}\u{0442}\u{0435}, \u{0447}\u{0442}\u{043e}\u{0431}\u{044b} \u{043e}\u{0431}\u{043d}\u{043e}\u{0432}\u{0438}\u{0442}\u{044c} \u{0430}\u{0432}\u{0442}\u{043e}\u{0440}\u{0438}\u{0437}\u{0430}\u{0446}\u{0438}\u{044e}")
                        .font(.caption2)
                }
                Spacer()
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(16)
            .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .disabled(isCheckingSession)
    }

    private func restoreSession() {
        isCheckingSession = true
        Task {
            // Сначала пробуем тихо восстановить
            if let s = await manager.probeSession(), s.user != nil {
                manager.didExplicitLogout = false
                UserDefaults.standard.set(false, forKey: "lkDidExplicitLogout")
                UserDefaults.standard.set(false, forKey: "lkSessionExpired")
                await manager.checkSession()
            } else {
                // Не удалось — открываем окно входа
                showLogin = true
            }
            isCheckingSession = false
        }
    }

    // MARK: - Сетка меню (стиль Fitness — большие карточки)

    private var menuGrid: some View {
        VStack(spacing: 16) {
            // — Учёба —
            sectionLabel("Учёба")

            // Зачётная книжка (широкая — на всю ширину)
            fitnessNavCard(title: "Зачётная книжка",
                           icon: "book.closed.fill", color: .blue) {
                LKGradebookView()
            }

            HStack(spacing: 12) {
                fitnessNavCard(title: "Профиль",
                               icon: "person.crop.circle.fill", color: .indigo) {
                    LKProfileDetailsView()
                }
                fitnessNavCard(title: "Студенческий \nбилет",
                               icon: "creditcard.fill", color: .mint) {
                    LKStudentCardView()
                }
            }

            HStack(spacing: 12) {
                fitnessNavCard(title: "Уведомления",
                               icon: "bell.fill", color: .red) {
                    LKNotificationsView()
                }
                fitnessNavCard(title: "Учебный план",
                                 icon: "book.text.fill", color: .orange) {
                    LKStudyPlanView()
                }
            }

            HStack(spacing: 12) {
                fitnessNavCard(title: "Мои работы",
                                 icon: "doc.text.fill", color: .purple) {
                    LKMyWorksView()
                }
                fitnessNavCard(title: "Приказы",
                               icon: "doc.richtext.fill", color: .cyan) {
                    LKOrdersView()
                }
            }

            // — Приложение —
            sectionLabel("Приложение")

            fitnessNavCard(title: "Полная версия кабинета",
                           icon: "safari.fill", color: .blue, subtitle: "lk.fa.ru") {
                LkWebView()
            }

            fitnessNavCard(title: "Настройки",
                           icon: "gearshape.fill", color: .gray) {
                SettingsView(viewModel: scheduleVM)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Компоненты карточек

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
    }

    /// Навигационная карточка (с переходом)
    @ViewBuilder
    private func fitnessNavCard<D: View>(
        title: String, icon: String, color: Color,
        subtitle: String? = nil,
        @ViewBuilder destination: () -> D
    ) -> some View {
        NavigationLink(destination: destination()) {
            fitnessCardBody(title: title, icon: icon, color: color, subtitle: subtitle)
        }
        .buttonStyle(.plain)
    }

    /// Карточка-заглушка
    private func fitnessPlaceholderCard(
        title: String, icon: String, color: Color, subtitle: String = "\u{0421}\u{043a}\u{043e}\u{0440}\u{043e}"
    ) -> some View {
        fitnessCardBody(title: title, icon: icon, color: color, subtitle: subtitle)
            .opacity(0.6)
    }

    /// Общий корпус карточки: название слева сверху, иконка справа снизу
    private func fitnessCardBody(
        title: String, icon: String, color: Color, subtitle: String? = nil
    ) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.primary)
                if let sub = subtitle {
                    Text(sub)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)

            if iconColorMode != "none" {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(resolvedIconColor(for: color))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(16)
            }
        }
        .frame(minHeight: 100)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// Цвет иконки в зависимости от настройки
    private func resolvedIconColor(for defaultColor: Color) -> Color {
        iconColorMode == "accent" ? .accentColor : defaultColor
    }

    // MARK: - Кнопка выхода

    private var logoutButton: some View {
        Button(role: .destructive) {
            Task { await manager.logout() }
        } label: {
            HStack {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 17, weight: .medium))
                Text("\u{0412}\u{044b}\u{0439}\u{0442}\u{0438} \u{0438}\u{0437} \u{0430}\u{043a}\u{043a}\u{0430}\u{0443}\u{043d}\u{0442}\u{0430}")
                    .font(.body)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    // MARK: - Не авторизован

    private var loggedOutView: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Шапка с маскотом и кнопкой входа
                VStack(spacing: 16) {
                    Image("MascotAstronaut")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 140)
                        .accessibilityHidden(true)

                    VStack(spacing: 6) {
                        Text("Профиль Финансового университета")
                            .font(.title3.bold())
                            .multilineTextAlignment(.center)
                        Text("Войдите, чтобы видеть зачётку, почту и объявления")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)

                    Button {
                        trySilentLogin()
                    } label: {
                        HStack {
                            if isCheckingSession {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                Label("Войти", systemImage: "arrow.right.circle.fill")
                            }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal, 24)
                    .disabled(isCheckingSession)
                }
                .padding(.top, 16)

                // Раздел: настройки
                VStack(alignment: .leading, spacing: 12) {
                    Text("Настройки")
                        .font(.headline)
                        .padding(.horizontal, 20)

                    VStack(spacing: 10) {
                        NavigationLink {
                            SettingsView(viewModel: scheduleVM)
                        } label: {
                            settingsRow(icon: "gearshape.fill", iconColor: .gray, title: "Настройки приложения", subtitle: "Тема, акцент, окно информации, уведомления")
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            WidgetGuideView(viewModel: scheduleVM)
                        } label: {
                            settingsRow(icon: "square.grid.2x2.fill", iconColor: .blue, title: "Виджеты", subtitle: "Как добавить расписание на главный экран")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                }

                // Раздел: о приложении
                VStack(alignment: .leading, spacing: 12) {
                    Text("О приложении")
                        .font(.headline)
                        .padding(.horizontal, 20)

                    VStack(spacing: 10) {
                        settingsRow(
                            icon: "info.circle.fill",
                            iconColor: .blue,
                            title: "О приложении",
                            subtitle: "Версия \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")"
                        )

                        Link(destination: URL(string: "https://www.fa.ru")!) {
                            settingsRow(icon: "globe", iconColor: .green, title: "Сайт университета", subtitle: "www.fa.ru")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                }

                Spacer(minLength: 24)
            }
        }
    }

    private func settingsRow(icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            // Иконка без подложки
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(iconColor)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func trySilentLogin() {
        isCheckingSession = true
        Task {
            if let s = await manager.probeSession(), s.user != nil {
                manager.didExplicitLogout = false
                UserDefaults.standard.set(false, forKey: "lkDidExplicitLogout")
                await manager.checkSession()
            } else {
                showLogin = true
            }
            isCheckingSession = false
        }
    }
}

// MARK: - Детали профиля (расширенные: копирование, тех. данные, доп. информация)

struct LKProfileDetailsView: View {
    @ObservedObject var manager = LKManager.shared
    @State private var copiedKey: String?
    @State private var isLoadingExtended = false
    @State private var extendedData: [String: String]?
    @AppStorage("accentColor") private var accentRaw = "faTeal"
    private var accent: Color { AccentColors.color(accentRaw) }

    var body: some View {
        List {
            if let s = manager.session {
                // Основная информация
                Section("Основная информация") {
                    if let name = s.fullName, !name.isEmpty {
                        copyRow("ФИО", value: name, key: "name")
                    }
                    if let group = s.studentGroup, !group.isEmpty {
                        copyRow("Группа", value: group, key: "group")
                    }
                    if let login = s.extendedUserData?.login, !login.isEmpty {
                        copyRow("Логин", value: login, key: "login")
                    }
                    let email = s.extendedUserData?.email ?? s.user?.email ?? ""
                    if !email.isEmpty {
                        copyRow("Email", value: email, key: "email")
                    }
                }

                // Дополнительные данные из Bitrix-профиля (если загружены)
                if let p = manager.bitrixProfile {
                    Section("Образование") {
                        if let level = p.eduLevel, !level.isEmpty {
                            copyRow("Уровень", value: level, key: "eduLevel")
                        }
                        if let form = p.eduForm, !form.isEmpty {
                            copyRow("Форма обучения", value: form, key: "eduForm")
                        }
                        if let course = p.eduCourse {
                            copyRow("Курс", value: "\(course)", key: "course")
                        }
                        if let status = p.eduStatus, !status.isEmpty {
                            copyRow("Статус", value: status, key: "eduStatus")
                        }
                        if let bookNum = p.eduMarkBookNum, !bookNum.isEmpty {
                            copyRow("Номер зачётки", value: bookNum, key: "bookNum")
                        }
                    }

                    Section("Программа") {
                        if let faculty = p.faculty?.title, !faculty.isEmpty {
                            copyRow("Факультет", value: faculty, key: "faculty")
                        }
                        if let dir = p.eduDirection?.title, !dir.isEmpty {
                            copyRow("Направление", value: dir, key: "direction")
                        }
                        if let dirCode = p.eduDirection?.title, !dirCode.isEmpty,
                           let code = p.eduDirection?.id {
                            copyRow("Код направления", value: "\(code)", key: "dirCode")
                        }
                        if let spec = p.eduSpecialization?.title, !spec.isEmpty {
                            copyRow("Профиль", value: spec, key: "specialization")
                        }
                        if let group = p.eduGroup?.title, !group.isEmpty {
                            copyRow("Группа", value: group, key: "groupBitrix")
                        }
                        if let qual = p.eduQualification?.title, !qual.isEmpty {
                            copyRow("Квалификация", value: qual, key: "qualification")
                        }
                    }

                    Section("Контакты") {
                        if let phone = p.phone, !phone.isEmpty {
                            copyRow("Телефон", value: phone, key: "phone")
                        }
                        if let mobile = p.mobile, !mobile.isEmpty {
                            copyRow("Мобильный", value: mobile, key: "mobile")
                        }
                        if let personalEmail = p.personalEmail, !personalEmail.isEmpty {
                            copyRow("Личный email", value: personalEmail, key: "personalEmail")
                        }
                        if let personalMobile = p.personalMobile, !personalMobile.isEmpty {
                            copyRow("Личный телефон", value: personalMobile, key: "personalMobile")
                        }
                        if let bd = p.birthdate, !bd.isEmpty {
                            copyRow("Дата рождения", value: formatBirthdate(bd), key: "birthdate")
                        }
                    }
                }

                // Образовательная программа (загружается дополнительно)
                Section("Доп. данные") {
                    if let ext = extendedData {
                        let displayOrder = ["Программа", "Код программы", "Факультет", "Курс", "Рейтинг", "Группа"]
                        let sorted = ext.keys.sorted { a, b in
                            (displayOrder.firstIndex(of: a) ?? 99) < (displayOrder.firstIndex(of: b) ?? 99)
                        }
                        if sorted.isEmpty {
                            Text("Данные не найдены").foregroundColor(.secondary)
                        } else {
                            ForEach(sorted, id: \.self) { key in
                                if let val = ext[key], !val.isEmpty {
                                    copyRow(key, value: val, key: key)
                                }
                            }
                        }
                    } else {
                        Button {
                            Task { await fetchExtendedData() }
                        } label: {
                            HStack(spacing: 8) {
                                if isLoadingExtended {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.down.circle")
                                        .foregroundColor(accent)
                                }
                                Text(isLoadingExtended ? "Загрузка..." : "Загрузить данные")
                                    .foregroundColor(accent)
                            }
                        }
                    }
                }

                // Рейтинг PGAS
                Section("Рейтинг") {
                    LKRatingCompactView()
                }

                // Студенческий билет (дублируется здесь для удобства)
                Section("Документы") {
                    NavigationLink {
                        LKStudentCardView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "creditcard.fill")
                                .font(.title3)
                                .foregroundColor(accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Студенческий билет")
                                    .font(.body)
                                Text("PDF · открыть")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                }

                // Технические данные
                Section("Технические данные") {
                    copyRow("ID пользователя", value: s.userId ?? "—", key: "userId")
                    if let netId = s.extendedUserData?.id, !netId.isEmpty {
                        copyRow("ID сети", value: netId, key: "netId")
                    }
                    if let exp = s.expires {
                        copyRow("Сессия до",
                             value: String(exp.prefix(19).replacingOccurrences(of: "T", with: " ")),
                             key: "expires")
                    }
                    if let lang = s.extendedUserData?.preferredLanguage, !lang.isEmpty {
                        copyRow("Язык", value: lang, key: "lang")
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Профиль")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            // Загружаем доп. данные автоматически, если профиля Bitrix ещё нет
            if manager.bitrixProfile == nil, manager.state == .loggedIn {
                Task { await fetchExtendedData() }
            }
        }
    }

    /// Форматирует дату рождения из YYYY-MM-DD в DD.MM.YYYY
    private func formatBirthdate(_ s: String) -> String {
        let parts = s.split(separator: "-")
        if parts.count == 3 {
            return "\(parts[2]).\(parts[1]).\(parts[0])"
        }
        return s
    }

    // MARK: - Копируемая строка

    private func copyRow(_ title: String, value: String, key: String) -> some View {
        Button {
            copyToClipboard(value)
            copiedKey = key
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { copiedKey = nil }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(value)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                Spacer()
                if copiedKey == key {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 16))
                        .transition(.scale)
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14))
                        .foregroundColor(accent.opacity(0.7))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func copyToClipboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    // MARK: - Загрузка доп. данных (ОП, рейтинг и т.д.)

    private func fetchExtendedData() async {
        isLoadingExtended = true

        let cookies = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                cont.resume(returning: cookies)
            }
        }
        let faCookies = cookies.filter { $0.domain.contains("fa.ru") }
        guard !faCookies.isEmpty else {
            isLoadingExtended = false
            return
        }
        // Гарантируем наличие Bitrix-сессии для org.fa.ru endpoints.
        await NativeAuthManager.ensureBitrixSession()
        // ВАЖНО: для org.fa.ru — только cookies домена org.fa.ru.
        // Все fa.ru cookies (включая KEYCLOAK_IDENTITY ~2KB) дают 8KB+ → nginx 400.
        // Для lk.fa.ru endpoints это тоже безопасно — они просто не получат свои cookies,
        // но там сессия через WKWebView, а не через этот запрос.
        let orgCookies = faCookies.filter { $0.domain.contains("org.fa.ru") }
        let headerFields = HTTPCookie.requestHeaderFields(with: orgCookies)

        let urlCandidates = [
            "https://org.fa.ru/bitrix/vuz/api/student/profile",
            "https://lk.fa.ru/api/user/profile",
            "https://org.fa.ru/bitrix/vuz/api/profile"
        ]

        for urlString in urlCandidates {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            // Cookie хедер уже добавлен через headerFields — не используем
            // httpShouldHandleCookies, чтобы URLSession не подменял его своим.
            for (name, value) in headerFields {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            request.setValue("8.135.3", forHTTPHeaderField: "App-Version")
            request.setValue("browser-bitrix", forHTTPHeaderField: "App-Key")
            request.setValue("https://lk.fa.ru", forHTTPHeaderField: "Referer")

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else { continue }

            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let labelMap: [String: String] = [
                    "UF_EDUC_PROGRAMM": "\u{041f}\u{0440}\u{043e}\u{0433}\u{0440}\u{0430}\u{043c}\u{043c}\u{0430}",
                    "UF_EDUC_PROGRAMM_CODE": "\u{041a}\u{043e}\u{0434} \u{043f}\u{0440}\u{043e}\u{0433}\u{0440}\u{0430}\u{043c}\u{043c}\u{044b}",
                    "UF_FACULTY": "\u{0424}\u{0430}\u{043a}\u{0443}\u{043b}\u{044c}\u{0442}\u{0435}\u{0442}",
                    "UF_COURSE": "\u{041a}\u{0443}\u{0440}\u{0441}",
                    "UF_RATING": "\u{0420}\u{0435}\u{0439}\u{0442}\u{0438}\u{043d}\u{0433}",
                    "RATING": "\u{0420}\u{0435}\u{0439}\u{0442}\u{0438}\u{043d}\u{0433}",
                    "FACULTY": "\u{0424}\u{0430}\u{043a}\u{0443}\u{043b}\u{044c}\u{0442}\u{0435}\u{0442}",
                    "COURSE": "\u{041a}\u{0443}\u{0440}\u{0441}",
                    "GROUP": "\u{0413}\u{0440}\u{0443}\u{043f}\u{043f}\u{0430}",
                    "PROGRAM": "\u{041f}\u{0440}\u{043e}\u{0433}\u{0440}\u{0430}\u{043c}\u{043c}\u{0430}",
                    "PROGRAM_CODE": "\u{041a}\u{043e}\u{0434} \u{043f}\u{0440}\u{043e}\u{0433}\u{0440}\u{0430}\u{043c}\u{043c}\u{044b}"
                ]

                var result: [String: String] = [:]
                for (key, value) in dict {
                    let label = labelMap[key] ?? key
                    let str: String?
                    if let s = value as? String { str = s }
                    else if let i = value as? Int { str = String(i) }
                    else { str = nil }
                    if let s = str, !s.isEmpty {
                        result[label] = s
                    }
                }

                if !result.isEmpty {
                    self.extendedData = result
                    break
                }
            }
        }

        if extendedData == nil {
            // Если ни один эндпоинт не ответил — покажем пустые поля
            self.extendedData = [:]
        }
        isLoadingExtended = false
    }
}

// MARK: - Успеваемость (заглушка)

struct LKPerformanceView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 56)).foregroundColor(.secondary.opacity(0.5))
            Text("\u{0420}\u{0430}\u{0437}\u{0434}\u{0435}\u{043b} \u{0432} \u{0440}\u{0430}\u{0437}\u{0440}\u{0430}\u{0431}\u{043e}\u{0442}\u{043a}\u{0435}")
                .font(.title3.bold()).foregroundColor(.secondary)
            Text("\u{0417}\u{0434}\u{0435}\u{0441}\u{044c} \u{0431}\u{0443}\u{0434}\u{0435}\u{0442} \u{043f}\u{043e}\u{0434}\u{0440}\u{043e}\u{0431}\u{043d}\u{0430}\u{044f} \u{0441}\u{0442}\u{0430}\u{0442}\u{0438}\u{0441}\u{0442}\u{0438}\u{043a}\u{0430} \u{0443}\u{0441}\u{043f}\u{0435}\u{0432}\u{0430}\u{0435}\u{043c}\u{043e}\u{0441}\u{0442}\u{0438}")
                .font(.subheadline).foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("\u{0423}\u{0441}\u{043f}\u{0435}\u{0432}\u{0430}\u{0435}\u{043c}\u{043e}\u{0441}\u{0442}\u{044c}")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Окно входа

struct LKLoginView: View {
    @ObservedObject var manager = LKManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if checking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\u{041f}\u{0440}\u{043e}\u{0432}\u{0435}\u{0440}\u{044f}\u{0435}\u{043c} \u{0432}\u{0445}\u{043e}\u{0434}...").font(.footnote).foregroundColor(.secondary)
                    }.padding(.vertical, 8)
                }
                LKAuthWebView(
                    onMaybeLoggedIn: {
                        Task {
                            checking = true
                            if let s = await manager.probeSession(), s.user != nil {
                                manager.didExplicitLogout = false
                                UserDefaults.standard.set(false, forKey: "lkDidExplicitLogout")
                                await manager.checkSession()
                                dismiss()
                            } else {
                                checking = false
                            }
                        }
                    }
                )
            }
            .navigationTitle("\u{0412}\u{0445}\u{043e}\u{0434}")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("\u{041e}\u{0442}\u{043c}\u{0435}\u{043d}\u{0430}") { dismiss() }
                }
            }
        }
    }
}

// MARK: - WebView авторизации

#if canImport(UIKit)
struct LKAuthWebView: UIViewRepresentable {
    let onMaybeLoggedIn: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://lk.fa.ru")!))
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onMaybeLoggedIn: onMaybeLoggedIn) }

    class Coordinator: NSObject, WKNavigationDelegate {
        let onMaybeLoggedIn: () -> Void
        private var hasCalled = false
        init(onMaybeLoggedIn: @escaping () -> Void) { self.onMaybeLoggedIn = onMaybeLoggedIn }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !hasCalled else { return }
            let urlStr = webView.url?.absoluteString.lowercased() ?? ""
            let likelyLoggedIn = !urlStr.contains("login") && !urlStr.contains("auth") && !urlStr.contains("register")
            let delay: TimeInterval = likelyLoggedIn ? 0.4 : 1.2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !self.hasCalled else { return }
                self.onMaybeLoggedIn()
            }
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            guard !hasCalled else { return }
            let from = webView.url?.absoluteString.lowercased() ?? ""
            if from.contains("login") || from.contains("auth") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard !self.hasCalled else { return }
                    self.onMaybeLoggedIn()
                }
            }
        }
    }
}
#else
struct LKAuthWebView: NSViewRepresentable {
    let onMaybeLoggedIn: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://lk.fa.ru")!))
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onMaybeLoggedIn: onMaybeLoggedIn) }

    class Coordinator: NSObject, WKNavigationDelegate {
        let onMaybeLoggedIn: () -> Void
        private var hasCalled = false
        init(onMaybeLoggedIn: @escaping () -> Void) { self.onMaybeLoggedIn = onMaybeLoggedIn }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !hasCalled else { return }
            let urlStr = webView.url?.absoluteString.lowercased() ?? ""
            let likelyLoggedIn = !urlStr.contains("login") && !urlStr.contains("auth") && !urlStr.contains("register")
            let delay: TimeInterval = likelyLoggedIn ? 0.4 : 1.2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !self.hasCalled else { return }
                self.onMaybeLoggedIn()
            }
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            guard !hasCalled else { return }
            let from = webView.url?.absoluteString.lowercased() ?? ""
            if from.contains("login") || from.contains("auth") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard !self.hasCalled else { return }
                    self.onMaybeLoggedIn()
                }
            }
        }
    }
}
#endif
