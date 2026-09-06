// ======================================================================
// NativeAuthManager.swift — NextAuth OAuth2 + PKCE flow + Bitrix SSO
// ======================================================================
//
// ФЛОУ АВТОРИЗАЦИИ (lk.fa.ru — NextAuth + Keycloak):
//   1. GET  lk.fa.ru/elk/api/auth/signin/keycloak          -> CSRF cookie
//   2. POST lk.fa.ru/elk/api/auth/signin/keycloak          -> JSON с Keycloak URL (state + PKCE)
//   3. GET  Keycloak auth URL (с state + code_challenge)   -> HTML форма логина
//   4. POST Keycloak login form (username + password)      -> OTP форма
//   5. POST Keycloak OTP form (otp)                        -> 302 с code на callback
//   6. GET  lk.fa.ru/.../callback/keycloak?code=...&state=... -> 302 на lk.fa.ru (сессия!)
//   7. GET  lk.fa.ru/elk/api/auth/session                  -> данные пользователя
//
// BITRIX SSO HANDSHAKE (org.fa.ru — собственная Bitrix-сессия, БЕЗ JWT):
//   B1. GET  https://org.fa.ru/                             -> PHPSESSID
//   B2. GET  /bitrix/vuz/sso/link?backurl=%2F               -> JSON {auth_url}
//        (client_id=orgfaru-client, redirect_uri=/bitrix/vuz/sso/callback)
//   B3. GET  auth_url на Keycloak (SSO через KEYCLOAK_IDENTITY) -> 302 с code
//   B4. GET  /bitrix/vuz/sso/callback?code=XXX&state=YYY    -> Bitrix создаёт BX_ORG_FA_RU_* cookies
//   B5. GET  /app/profile/home                              -> метаданные (GUEST_ID, TZ, LAST_VISIT)
//
// ВАЖНО: JWT для org.fa.ru больше НЕ НУЖЕН — Bitrix использует собственную сессию.
// Все запросы к /bitrix/vuz/api/* работают ТОЛЬКО на cookies (как браузер).
// ОТКРЫТИЕ v9: client_id=orgfaru-client (не elk-front) — найден через /bitrix/vuz/sso/link.
// ======================================================================

import Foundation
import Combine
import WebKit
import CommonCrypto

// MARK: - Логирование

private func authLog(_ items: Any..., separator: String = " ") {
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss.SSS"
    let time = fmt.string(from: Date())
    let msg = items.map { "\($0)" }.joined(separator: separator)
    print("\(time) [AUTH] \(msg)")
}

private func bitrixLog(_ items: Any..., separator: String = " ") {
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss.SSS"
    let time = fmt.string(from: Date())
    let msg = items.map { "\($0)" }.joined(separator: separator)
    print("\(time) [bitrixSSO] \(msg)")
}

// MARK: - Состояния авторизации

enum NativeAuthStep: Equatable {
    case idle
    case loadingForm
    case sendingCredentials
    case waitingForOTP
    case sendingOTP
    case exchangingToken
    case fetchingSession
    case success
    case error(String)

    static func == (lhs: NativeAuthStep, rhs: NativeAuthStep) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.loadingForm, .loadingForm),
             (.sendingCredentials, .sendingCredentials),
             (.waitingForOTP, .waitingForOTP),
             (.sendingOTP, .sendingOTP),
             (.exchangingToken, .exchangingToken),
             (.fetchingSession, .fetchingSession),
             (.success, .success):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Результат авторизации

struct AuthResult {
    let sessionCookies: [HTTPCookie]
    let csrfToken: String?
    let sessionData: Data?
    let userId: String?
    let userName: String?
    let accessToken: String?   // JWT для org.fa.ru
    let refreshToken: String?
    let tokenExpiresIn: TimeInterval?
}

// MARK: - Делегат: блокировка 302

private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - PKCE Helper

private enum PKCEHelper {
    /// Генерирует code_verifier (43-128 символов URL-safe)
    static func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64URLEncodedString()
    }

    /// Генерирует code_challenge = BASE64URL(SHA256(code_verifier))
    static func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .ascii) else { return "" }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        return self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Менеджер авторизации

@MainActor
class NativeAuthManager: ObservableObject {

    static let shared = NativeAuthManager()

    // MARK: Published — UI

    @Published var step: NativeAuthStep = .idle
    @Published var username: String = ""
    @Published var password: String = ""
    @Published var otpCode: String = ""
    @Published var errorMessage: String? = nil
    @Published var serverErrorHTML: String? = nil
    @Published var canResend: Bool = false
    @Published var resendCountdown: Int = 0
    @Published var isPasswordVisible: Bool = false
    @Published var isLoading: Bool = false

    var onAuthSuccess: ((AuthResult) -> Void)?

    // MARK: Private — Сессия

    private var urlSession: URLSession? = nil
    private let redirectDelegate = RedirectBlockingDelegate()
    private var isSubmitting: Bool = false

    // MARK: Private — Данные форм

    private var loginFormAction: String? = nil
    private var loginHiddenFields: [String: String] = [:]
    private var otpFormAction: String? = nil
    private var otpHiddenFields: [String: String] = [:]
    private var otpInputName: String = "otp"

    // MARK: Private — Callback URL от Keycloak (для NextAuth)

    private var keycloakCallbackURL: String? = nil

    // MARK: Private — PKCE для SSO (получение JWT)

    private var ssoCodeVerifier: String? = nil

    // MARK: Private — Таймер

    private var countdownTimer: Timer? = nil

    // MARK: Private — Константы

    private let authBase = "https://auth.fa.ru"
    private let lkBase = "https://lk.fa.ru"
    private let callbackBase = "https://lk.fa.ru/elk/api/auth/callback/keycloak"
    private let sessionURL = "https://lk.fa.ru/elk/api/auth/session"
    private let signinURL = "https://lk.fa.ru/elk/api/auth/signin/keycloak"
    private let clientId = "elk-front"

    // MARK: Private — Константы Bitrix SSO (org.fa.ru)
    //
    // Bitrix использует СОБСТВЕННУЮ сессию (BX_ORG_FA_RU_*) — не JWT.
    // Создаётся через SSO-handshake: /bitrix/vuz/sso/link -> auth_url -> callback.
    // JWT с client_id=elk-front технически невалиден для org.fa.ru
    // (aud=account, allowed-origins=lk.fa.ru), поэтому не используем его.

    private let bitrixBase = "https://org.fa.ru"
    private let bitrixSSOLinkURL = "https://org.fa.ru/bitrix/vuz/sso/link"
    private let bitrixSSOCallbackURL = "https://org.fa.ru/bitrix/vuz/sso/callback"

    /// Флаг: был ли уже выполнен успешный Bitrix SSO handshake.
    /// Используется ensureBitrixSession() чтобы не повторять handshake при каждом запросе.
    private static let bitrixSSODoneKey = "bitrixSSODone"

    /// Task текущего handshake — позволяет дождаться его завершения параллельным вызывающим.
    private var bitrixSSOTask: Task<Bool, Never>? = nil

    private init() {}

    // =================================================================
    // MARK: - HTTP Сессия
    // =================================================================

    private func makeSession() -> URLSession {
        if let existing = urlSession { return existing }
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: redirectDelegate, delegateQueue: nil)
        urlSession = session
        authLog("URLSession создана")
        return session
    }

    private func destroySession() {
        urlSession?.invalidateAndCancel()
        urlSession = nil
        authLog("URLSession уничтожена")
    }

    // =================================================================
    // MARK: - Шаг 0: Инициация через NextAuth signin
    // =================================================================

    func startAuth() async {
        guard !isSubmitting else {
            authLog("startAuth: заблокировано")
            return
        }
        reset()
        isSubmitting = true
        step = .loadingForm
        isLoading = true
        authLog("=== НАЧАЛО АВТОРИЗАЦИИ (NextAuth flow) ===")

        // 0a: GET signin endpoint -> CSRF cookie
        authLog("Шаг 0a: GET", signinURL)
        guard let signinURL = URL(string: self.signinURL) else {
            finishWithError("Неверный URL")
            return
        }

        do {
            let (_, response) = try await makeSession().data(from: signinURL)
            let http = response as? HTTPURLResponse
            authLog("Шаг 0a: статус", http?.statusCode ?? 0)
            authLog("Куки после 0a:", cookieSummary())
        } catch {
            authLog("Шаг 0a ошибка:", error.localizedDescription)
        }

        // 0b: POST signin с CSRF -> JSON с Keycloak URL
        let csrfToken = extractCSRFFromCookie()
        guard let csrf = csrfToken else {
            finishWithError("CSRF токен не получен")
            return
        }
        authLog("Шаг 0b: POST signin с CSRF")
        authLog("CSRF:", csrf.prefix(20) + "...")

        guard let postURL = URL(string: self.signinURL) else {
            finishWithError("Неверный URL")
            return
        }

        var request = URLRequest(url: postURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(lkBase, forHTTPHeaderField: "Origin")
        request.setValue(self.signinURL, forHTTPHeaderField: "Referer")
        let bodyString = "csrfToken=\(csrf.urlEncoded)&callbackUrl=\(lkBase.urlEncoded)&json=true"
        request.httpBody = bodyString.data(using: .utf8)

        do {
            let (data, response) = try await makeSession().data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            authLog("Шаг 0b: статус", statusCode)
            authLog("Куки после 0b:", cookieSummary())

            // Парсим JSON -> извлекаем Keycloak auth URL
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let authURL = json["url"] as? String else {
                authLog("Шаг 0b: нет JSON/url в ответе")
                authLog("Тело:", body.prefix(500))
                finishWithError("Ошибка инициализации авторизации")
                return
            }

            authLog("Keycloak auth URL получен (NextAuth state + PKCE)")
            isSubmitting = false
            await loadKeycloakLoginForm(authURL: authURL)
            return

        } catch {
            isSubmitting = false
            finishWithError("Ошибка подключения к серверу")
        }
    }

    // =================================================================
    // MARK: - Шаг 1: Загрузка формы логина Keycloak
    // =================================================================

    private func loadKeycloakLoginForm(authURL: String) async {
        authLog("Шаг 1: GET Keycloak auth form")
        guard let url = URL(string: authURL) else {
            finishWithError("Неверный URL")
            return
        }

        do {
            let (data, response) = try await makeSession().data(from: url)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let html = String(data: data, encoding: .utf8) ?? ""
            authLog("Шаг 1: статус", statusCode, "HTML", html.count, "симв")

            // Следуем за редиректами
            if let http = response as? HTTPURLResponse,
               (http.statusCode == 301 || http.statusCode == 302),
               let location = http.value(forHTTPHeaderField: "Location") {
                let absURL = resolveURL(location)
                authLog("Шаг 1: 302 ->", absURL.prefix(100))
                await loadKeycloakLoginForm(authURL: absURL)
                return
            }

            if statusCode == 200 {
                parseLoginForm(html: html)
                return
            }

            finishWithError("Ошибка загрузки формы (\(statusCode))")
        } catch {
            finishWithError("Не удалось подключиться к серверу")
        }
    }

    private func parseLoginForm(html: String) {
        let hasLogin = html.contains("id=\"kc-form-login\"")
        let hasOTP = (html.contains("kc-otp-form") || html.contains("id=\"kc-otp-login-form\"")) && !hasLogin

        if hasLogin {
            loginFormAction = extractFormAction(from: html)
            loginHiddenFields = extractHiddenFields(from: html)
            authLog("Форма логина: action =", loginFormAction ?? "nil")
            authLog("Hidden fields:", loginHiddenFields.keys.joined(separator: ", "))
            step = .idle
            isLoading = false
        } else if hasOTP {
            authLog("Сразу OTP-форма")
            parseAndStoreOTPForm(html: html)
            step = .waitingForOTP
            isLoading = false
            startResendCountdown()
        } else {
            authLog("Форма не распознана")
            finishWithError("Не удалось загрузить форму входа")
        }
    }

    // =================================================================
    // MARK: - Шаг 2: Отправка логина и пароля
    // =================================================================

    func submitCredentials() async {
        guard !isSubmitting else { return }
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
            finishWithError("Введите логин")
            return
        }
        guard !password.isEmpty else {
            finishWithError("Введите пароль")
            return
        }
        guard let actionURL = loginFormAction else {
            finishWithError("Форма не загружена")
            return
        }

        isSubmitting = true
        step = .sendingCredentials
        errorMessage = nil
        serverErrorHTML = nil
        isLoading = true

        let fullURL = resolveURL(actionURL)
        guard let url = URL(string: fullURL) else {
            finishWithError("Неверный URL")
            return
        }

        var body = loginHiddenFields
        body["username"] = username.trimmingCharacters(in: .whitespaces)
        body["password"] = password
        body["credentialId"] = ""
        let bodyString = body.map { "\($0.key)=\($0.value.urlEncoded)" }.joined(separator: "&")

        authLog("=== ШАГ 2: ПОСТАВКА ЛОГИНА/ПАРОЛЯ ===")
        authLog("POST", fullURL)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyString.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(lkBase, forHTTPHeaderField: "Origin")
        request.setValue(lkBase, forHTTPHeaderField: "Referer")

        do {
            let (data, response) = try await makeSession().data(for: request)
            isSubmitting = false
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let html = String(data: data, encoding: .utf8) ?? ""
            authLog("Шаг 2: статус", statusCode)

            if let http = response as? HTTPURLResponse,
               (http.statusCode == 301 || http.statusCode == 302),
               let location = http.value(forHTTPHeaderField: "Location") {
                authLog("302 -> пароль верный:", location.prefix(120))

                if location.contains("callback/keycloak") {
                    // Сохраняем callback URL — передаём в NextAuth
                    keycloakCallbackURL = location
                    await performNextAuthCallback(callbackURL: location)
                    return
                }
                await followAndParseOTPForm(location: location)
                return
            }

            if statusCode == 200 {
                if html.contains("kc-otp-form") || html.contains("id=\"kc-otp-login-form\"") {
                    parseAndStoreOTPForm(html: html)
                    step = .waitingForOTP
                    isLoading = false
                    startResendCountdown()
                    return
                }
                // Обновляем форму
                if let newAction = extractFormAction(from: html), !newAction.isEmpty {
                    loginFormAction = newAction
                }
                let newFields = extractHiddenFields(from: html)
                if !newFields.isEmpty { loginHiddenFields = newFields }
                if let err = extractErrorMessage(from: html) {
                    serverErrorHTML = html
                    finishWithError(err)
                    return
                }
                serverErrorHTML = html
                finishWithError("Неверный логин или пароль")
                return
            }

            finishWithError("Ошибка сервера (\(statusCode))")
        } catch {
            isSubmitting = false
            finishWithError("Не удалось подключиться к серверу")
        }
    }

    // =================================================================
    // MARK: - Шаг 3: Загрузка OTP-формы
    // =================================================================

    private func followAndParseOTPForm(location: String) async {
        let absURL = resolveURL(location)
        guard let url = URL(string: absURL) else {
            finishWithError("Неверный URL")
            return
        }
        authLog("Загрузка OTP-формы:", absURL)

        do {
            let (data, response) = try await makeSession().data(from: url)
            let html = String(data: data, encoding: .utf8) ?? ""

            if let http = response as? HTTPURLResponse,
               (http.statusCode == 301 || http.statusCode == 302),
               let loc = http.value(forHTTPHeaderField: "Location") {
                if loc.contains("callback/keycloak") {
                    keycloakCallbackURL = loc
                    await performNextAuthCallback(callbackURL: loc)
                    return
                }
                await followAndParseOTPForm(location: loc)
                return
            }

            if (response as? HTTPURLResponse)?.statusCode == 200 {
                parseAndStoreOTPForm(html: html)
                step = .waitingForOTP
                isLoading = false
                startResendCountdown()
                return
            }

            finishWithError("Ошибка загрузки формы кода")
        } catch {
            finishWithError("Не удалось подключиться к серверу")
        }
    }

    private func parseAndStoreOTPForm(html: String) {
        otpFormAction = extractFormAction(from: html)
        otpHiddenFields = extractHiddenFields(from: html)
        otpInputName = extractOTPInputName(from: html)
        authLog("OTP форма: action =", otpFormAction ?? "nil")
        authLog("OTP hidden:", otpHiddenFields.keys.joined(separator: ", "))
        authLog("OTP input name:", otpInputName)
    }

    // =================================================================
    // MARK: - Шаг 4: Отправка OTP
    // =================================================================

    func submitOTP() async {
        let code = otpCode.trimmingCharacters(in: .whitespaces)
        guard code.count >= 4 else {
            errorMessage = "Введите код подтверждения"
            return
        }
        guard !isSubmitting else { return }
        guard let actionURL = otpFormAction else {
            finishWithError("Форма не загружена")
            return
        }

        isSubmitting = true
        step = .sendingOTP
        errorMessage = nil
        serverErrorHTML = nil
        isLoading = true

        let fullURL = resolveURL(actionURL)
        guard let url = URL(string: fullURL) else {
            finishWithError("Неверный URL")
            return
        }

        var body = otpHiddenFields
        body[otpInputName] = code
        let bodyString = body.map { "\($0.key)=\($0.value.urlEncoded)" }.joined(separator: "&")

        authLog("=== ШАГ 4: ОТПРАВКА OTP ===")
        authLog("POST", fullURL)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyString.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(lkBase, forHTTPHeaderField: "Origin")
        request.setValue(lkBase, forHTTPHeaderField: "Referer")

        do {
            let (data, response) = try await makeSession().data(for: request)
            isSubmitting = false
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let html = String(data: data, encoding: .utf8) ?? ""
            authLog("OTP: статус", statusCode)

            if let http = response as? HTTPURLResponse,
               (http.statusCode == 301 || http.statusCode == 302),
               let location = http.value(forHTTPHeaderField: "Location") {
                authLog("OTP верный! 302 ->", location.prefix(120))

                if location.contains("callback/keycloak") {
                    keycloakCallbackURL = location
                    await performNextAuthCallback(callbackURL: location)
                    return
                }
                await followOTPRedirect(location: location)
                return
            }

            if statusCode == 200 {
                if let newAction = extractFormAction(from: html), !newAction.isEmpty { otpFormAction = newAction }
                let newFields = extractHiddenFields(from: html)
                if !newFields.isEmpty { otpHiddenFields = newFields }
                let newName = extractOTPInputName(from: html)
                if !newName.isEmpty { otpInputName = newName }

                if let err = extractErrorMessage(from: html) {
                    step = .waitingForOTP
                    errorMessage = err
                    otpCode = ""
                    isLoading = false
                    return
                }
                step = .waitingForOTP
                errorMessage = "Неверный код подтверждения"
                otpCode = ""
                isLoading = false
                return
            }

            step = .waitingForOTP
            errorMessage = "Ошибка сервера (\(statusCode))"
            otpCode = ""
            isLoading = false
        } catch {
            isSubmitting = false
            step = .waitingForOTP
            errorMessage = "Не удалось подключиться к серверу"
            otpCode = ""
            isLoading = false
        }
    }

    private func followOTPRedirect(location: String) async {
        let absURL = resolveURL(location)
        guard let url = URL(string: absURL) else { return }
        do {
            let (_, response) = try await makeSession().data(from: url)
            if let http = response as? HTTPURLResponse,
               (http.statusCode == 301 || http.statusCode == 302),
               let loc = http.value(forHTTPHeaderField: "Location") {
                if loc.contains("callback/keycloak") {
                    keycloakCallbackURL = loc
                    await performNextAuthCallback(callbackURL: loc)
                    return
                }
                await followOTPRedirect(location: loc)
            }
        } catch {
            finishWithError("Ошибка: \(error.localizedDescription)")
        }
    }

    // =================================================================
    // MARK: - Шаг 5: NextAuth Callback (КЛЮЧЕВОЙ!)
    // =================================================================
    ///
    /// Keycloak редиректит на callback с code + state.
    /// NextAuth проверяет state, сам обменивает code на токены,
    /// создаёт сессию и устанавливает cookies session-token.0/.1.
    ///
    /// МЫ НЕ обмениваем code сами — NextAuth делает это.

    private func performNextAuthCallback(callbackURL: String) async {
        authLog("=== ШАГ 5: NextAuth Callback ===")
        step = .exchangingToken
        let absURL = resolveURL(callbackURL)
        guard let url = URL(string: absURL) else {
            finishWithError("Неверный URL")
            return
        }
        authLog("GET", absURL.prefix(120))
        authLog("Куки:", cookieSummary())

        do {
            let (_, response) = try await makeSession().data(from: url)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            authLog("Callback: статус", statusCode)
            authLog("Куки после callback:", cookieSummary())

            if let http = response as? HTTPURLResponse,
               (http.statusCode == 301 || http.statusCode == 302),
               let location = http.value(forHTTPHeaderField: "Location") {
                if location.lowercased().contains("error") {
                    authLog("NextAuth вернул ошибку:", location)
                    finishWithError("Ошибка авторизации (callback error)")
                    return
                }
                authLog("Callback редирект ->", location.prefix(80))
                // Проверяем session-token cookies
                let hasSession = (HTTPCookieStorage.shared.cookies ?? [])
                    .contains { $0.name.contains("session-token") }
                if hasSession {
                    authLog("Session cookies созданы!")
                } else {
                    authLog("WARNING: session-token cookies не найдены после callback")
                }
                // Получаем JWT через SSO, затем проверяем сессию
                await fetchJWTAndSession()
                return
            }

            if statusCode == 200 {
                await fetchJWTAndSession()
                return
            }

            finishWithError("Ошибка callback (\(statusCode))")
        } catch {
            finishWithError("Ошибка: \(error.localizedDescription)")
        }
    }

    // =================================================================
    // MARK: - Шаг 6: Завершение авторизации (без JWT)
    // =================================================================
    ///
    /// Раньше: здесь получали JWT через SSO+PKCE для org.fa.ru API.
    /// Сейчас: JWT НЕ НУЖЕН — Bitrix (org.fa.ru) использует собственную
    /// сессионную авторизацию (BX_ORG_FA_RU_*) через /bitrix/vuz/sso/*.
    /// JWT от client_id=elk-front всё равно невалиден для org.fa.ru
    /// (aud=account, allowed-origins=lk.fa.ru).
    ///
    /// Bitrix SSO-handshake запускается позже из fetchSessionAndFinish()
    /// после подтверждения сессии lk.fa.ru.
    private func fetchJWTAndSession() async {
        authLog("=== ШАГ 6: Пропуск JWT (Bitrix использует собственную сессию) ===")
        // JWT не нужен — Bitrix SSO handshake будет вызван из fetchSessionAndFinish()
        await fetchSessionAndFinish(accessToken: nil, refreshToken: nil, expiresIn: nil)
    }

    // =================================================================
    // MARK: - Шаг 7: Проверка сессии и завершение
    // =================================================================

    private func fetchSessionAndFinish(
        accessToken: String?,
        refreshToken: String?,
        expiresIn: Double?
    ) async {
        step = .fetchingSession
        authLog("=== ШАГ 7: Проверка сессии ===")

        guard let url = URL(string: sessionURL) else {
            finishWithError("Неверный URL")
            return
        }

        authLog("GET", sessionURL)
        authLog("Куки:", cookieSummary())

        do {
            let (data, response) = try await makeSession().data(from: url)
            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? 0
            authLog("Session: статус", statusCode)

            if statusCode == 200 {
                var userId: String? = nil
                var userName: String? = nil

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    userId = (json["user"] as? [String: Any])?["id"] as? String
                        ?? json["userId"] as? String
                    userName = (json["user"] as? [String: Any])?["name"] as? String
                    authLog("Пользователь: id=\(userId ?? "?"), name=\(userName ?? "?")")

                    if let user = json["user"] as? [String: Any], user.isEmpty == false {
                        // Сессия валидна
                        let allCookies = HTTPCookieStorage.shared.cookies ?? []
                        let wkStore = WKWebsiteDataStore.default().httpCookieStore
                        for cookie in allCookies { await wkStore.setCookie(cookie) }
                        authLog("Куки -> WKWebView (\(allCookies.count) шт)")

                        if accessToken != nil {
                            KeychainHelper.save(key: "orgFaAccessToken", string: accessToken!)
                            if var exp = expiresIn {
                                KeychainHelper.save(key: "orgFaTokenExpires", data: Data(bytes: &exp, count: MemoryLayout.size(ofValue: exp)))
                            }
                        }

                        // Сохраняем креды если "Запомнить меня"
                        if UserDefaults.standard.bool(forKey: "rememberMe") {
                            KeychainHelper.save(key: "savedUsername", string: username)
                            KeychainHelper.save(key: "savedPassword", string: password)
                        }

                        authLog("=== АВТОРИЗАЦИЯ УСПЕШНА ===")

                        // Запускаем Bitrix SSO handshake (fire-and-forget).
                        // Он установит BX_ORG_FA_RU_* cookies для org.fa.ru API.
                        // fetchBitrix* методы вызовут ensureBitrixSession() и дождутся
                        // завершения, если оно ещё идёт.
                        Task { [weak self] in
                            guard let self else { return }
                            let ok = await self.bitrixSSOHandshake()
                            authLog("Bitrix SSO: \(ok ? "OK" : "FAILED")")
                        }

                        let result = AuthResult(
                            sessionCookies: allCookies,
                            csrfToken: extractCSRFFromCookie(),
                            sessionData: data,
                            userId: userId,
                            userName: userName,
                            accessToken: accessToken,
                            refreshToken: refreshToken,
                            tokenExpiresIn: expiresIn.map { TimeInterval($0) }
                        )

                        step = .success
                        isSubmitting = false
                        isLoading = false
                        onAuthSuccess?(result)
                        return
                    }
                }

                // Пустая сессия
                authLog("Пустая сессия")
                finishWithError("Не удалось создать сессию")
                return
            }

            finishWithError("Ошибка сессии (\(statusCode))")
        } catch {
            finishWithError("Ошибка: \(error.localizedDescription)")
        }
    }

    // =================================================================
    // MARK: - Обновление JWT access_token — БОЛЬШЕ НЕ ИСПОЛЬЗУЕТСЯ
    // =================================================================
    ///
    /// Bitrix (org.fa.ru) использует собственную сессию (BX_ORG_FA_RU_*),
    /// поэтому JWT не нужен. Метод оставлен как заглушка для обратной
    /// совместимости со старым кодом, который мог его вызывать.
    /// Всегда возвращает nil. Используйте bitrixSSOHandshake() для
    /// обновления Bitrix-сессии.
    func refreshAccessToken() async -> String? {
        authLog("refreshAccessToken: deprecated — Bitrix использует собственную сессию")
        return nil
    }

    /// Возвращает текущий access_token для org.fa.ru — БОЛЬШЕ НЕ ИСПОЛЬЗУЕТСЯ.
    /// Всегда возвращает nil. Bitrix-сессия устанавливается через SSO-handshake.
    static func getOrgAccessToken() async -> String? {
        return nil
    }

    // =================================================================
    // MARK: - Повторная отправка кода
    // =================================================================

    func resendCode(channel: String) async {
        guard !isSubmitting else { return }
        guard canResend else { return }
        guard let actionURL = otpFormAction else {
            errorMessage = "Форма не загружена"
            return
        }

        isSubmitting = true
        isLoading = true
        errorMessage = nil

        let fullURL = resolveURL(actionURL)
        guard let url = URL(string: fullURL) else {
            isSubmitting = false
            isLoading = false
            return
        }

        var body = otpHiddenFields
        body["action"] = "resend_\(channel)"
        let bodyString = body.map { "\($0.key)=\($0.value.urlEncoded)" }.joined(separator: "&")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyString.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(lkBase, forHTTPHeaderField: "Origin")
        request.setValue(lkBase, forHTTPHeaderField: "Referer")

        do {
            let (data, response) = try await makeSession().data(for: request)
            isSubmitting = false
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let html = String(data: data, encoding: .utf8) ?? ""

            if statusCode == 200 {
                if let na = extractFormAction(from: html), !na.isEmpty { otpFormAction = na }
                let nf = extractHiddenFields(from: html)
                if !nf.isEmpty { otpHiddenFields = nf }
                let nn = extractOTPInputName(from: html)
                if !nn.isEmpty { otpInputName = nn }
            }
            if statusCode == 301 || statusCode == 302,
               let loc = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") {
                let absLoc = resolveURL(loc)
                if let followURL = URL(string: absLoc) {
                    let (fData, _) = try await makeSession().data(from: followURL)
                    let fHTML = String(data: fData, encoding: .utf8) ?? ""
                    if let na = extractFormAction(from: fHTML), !na.isEmpty { otpFormAction = na }
                    let nf = extractHiddenFields(from: fHTML)
                    if !nf.isEmpty { otpHiddenFields = nf }
                    let nn = extractOTPInputName(from: fHTML)
                    if !nn.isEmpty { otpInputName = nn }
                }
            }

            errorMessage = nil
            otpCode = ""
            startResendCountdown()
        } catch {
            isSubmitting = false
            errorMessage = "Не удалось отправить код"
        }
        isLoading = false
    }

    // =================================================================
    // MARK: - Таймер
    // =================================================================

    private func startResendCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        resendCountdown = 30
        canResend = false

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.resendCountdown -= 1
                if self.resendCountdown <= 0 {
                    self.canResend = true
                    self.countdownTimer?.invalidate()
                    self.countdownTimer = nil
                }
            }
        }
    }

    // =================================================================
    // MARK: - Парсинг HTML
    // =================================================================

    private func extractFormAction(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<form[^>]*action=\"([^\"]+)\"[^>]*>", options: [.caseInsensitive]) else { return nil }
        let fullRange = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: fullRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range]).htmlDecoded
    }

    private func extractHiddenFields(from html: String) -> [String: String] {
        var fields: [String: String] = [:]
        guard let regex = try? NSRegularExpression(pattern: "<input[^>]*type=\"hidden\"[^>]*>", options: [.caseInsensitive]) else { return fields }
        let fullRange = NSRange(html.startIndex..., in: html)
        regex.enumerateMatches(in: html, range: fullRange) { match, _, _ in
            guard let matchRange = match?.range,
                  let inputRange = Range(matchRange, in: html) else { return }
            let tag = String(html[inputRange])
            if let name = extractAttr("name", from: tag),
               let value = extractAttr("value", from: tag) {
                fields[name] = value
            }
        }
        return fields
    }

    private func extractOTPInputName(from html: String) -> String {
        let knownNames = ["otp", "otc", "totp", "authenticatorCode", "code"]
        for name in knownNames {
            if html.contains("name=\"\(name)\"") { return name }
        }
        let patterns = [
            "<input[^>]*type=\"(text|number|tel)\"[^>]*name=\"([^\"]+)\"[^>]*>",
            "<input[^>]*name=\"([^\"]+)\"[^>]*type=\"(text|number|tel)\"[^>]*>"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let fullRange = NSRange(html.startIndex..., in: html)
            guard let match = regex.firstMatch(in: html, range: fullRange) else { continue }
            let idx = (match.numberOfRanges > 2) ? 2 : 1
            if idx < match.numberOfRanges,
               let range = Range(match.range(at: idx), in: html) {
                return String(html[range])
            }
        }
        return "otp"
    }

    private func extractAttr(_ name: String, from tag: String) -> String? {
        let p = name + "=\"([^\"]*)\""
        guard let range = tag.range(of: p, options: .regularExpression) else { return nil }
        var val = String(tag[range])
        val = val.replacingOccurrences(of: name + "=\"", with: "")
        val = val.replacingOccurrences(of: "\"", with: "")
        return val
    }

    private func extractErrorMessage(from html: String) -> String? {
        let patterns = [
            "id=\"kc-error-message\"[^>]*>[^<]*<[^>]*>([^<]+)",
            "class=\"[^\"]*kc-feedback-error[^\"]*\"[^>]*>[^<]*<[^>]*>([^<]+)",
            "pf-v5-c-alert__title[^>]*>([^<]+)",
            "class=\"[^\"]*alert-error[^\"]*\"[^>]*>([^<]+)"
        ]
        for pattern in patterns {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [])
                let fullRange = NSRange(html.startIndex..., in: html)
                guard let match = regex.firstMatch(in: html, range: fullRange) else { continue }
                let captureRange = (match.numberOfRanges > 1) ? match.range(at: 1) : match.range
                guard let range = Range(captureRange, in: html) else { continue }
                var content = String(html[range])
                content = content.replacingOccurrences(of: ">", with: "")
                content = content.replacingOccurrences(of: "<", with: "")
                content = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if content.count >= 3 { return content }
            } catch { continue }
        }
        return nil
    }

    private func extractCode(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString) else { return nil }
        return components.queryItems?.first(where: { $0.name == "code" })?.value
    }

    private func extractCSRFFromCookie() -> String? {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        guard let csrfCookie = cookies.first(where: { $0.name.contains("csrf") && $0.name.contains("next-auth") }) else {
            return nil
        }
        let value = csrfCookie.value
        return value.components(separatedBy: "%7C").first
            ?? value.components(separatedBy: "|").first
    }

    // =================================================================
    // MARK: - Утилиты
    // =================================================================

    private func resolveURL(_ string: String) -> String {
        string.hasPrefix("http") ? string : authBase + string
    }

    private func finishWithError(_ message: String) {
        isSubmitting = false
        isLoading = false
        step = .error(message)
        errorMessage = message
        authLog("ОШИБКА:", message)
    }

    private func cookieSummary() -> String {
        let cookies = (HTTPCookieStorage.shared.cookies ?? []).filter { $0.domain.contains("fa.ru") }
        return cookies
            .map { "\($0.name)=\($0.value.prefix(15))..." }
            .joined(separator: "; ")
    }

    // =================================================================
    // MARK: - Сброс
    // =================================================================

    func reset() {
        step = .idle
        errorMessage = nil
        serverErrorHTML = nil
        otpCode = ""
        loginFormAction = nil
        loginHiddenFields = [:]
        otpFormAction = nil
        otpHiddenFields = [:]
        otpInputName = "otp"
        isSubmitting = false
        keycloakCallbackURL = nil
        ssoCodeVerifier = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        resendCountdown = 0
        canResend = false
        isLoading = false

        if let cookies = HTTPCookieStorage.shared.cookies {
            for cookie in cookies where cookie.domain.contains("fa.ru") {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
        destroySession()
    }

    // =================================================================
    // MARK: - Заголовки для org.fa.ru (БЕЗ JWT — только cookies)
    // =================================================================
    ///
    /// Bitrix использует собственную сессию (BX_ORG_FA_RU_* cookies).
    /// Authorization: Bearer НЕ НУЖЕН и даже вреден (токен от elk-front
    /// невалиден для org.fa.ru — aud=account, allowed-origins=lk.fa.ru).
    ///
    /// App-Version обновлён до 8.135.3 — сервер требует актуальную версию.
    func getCookieHeader() -> String {
        let cookies = (HTTPCookieStorage.shared.cookies ?? []).filter { $0.domain.contains("fa.ru") }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// Заголовки для org.fa.ru API — только cookies, БЕЗ Bearer token.
    /// Bitrix-сессия устанавливается через bitrixSSOHandshake().
    /// ВАЖНО: используем ТОЛЬКО cookies домена org.fa.ru (BX_ORG_FA_RU_*,
    /// PHPSESSID, vuzportalfinun_session). Все fa.ru cookies (включая
    /// KEYCLOAK_IDENTITY ~2KB JWT) дают 8KB+ Cookie хедер → nginx 400
    /// "Request Header Or Cookie Too Large".
    static func orgFaHeaders() async -> [String: String] {
        var headers = [
            "App-Version": "8.135.3",
            "App-Key": "browser-bitrix",
            "App-Locale": "ru",
            "App-TimezoneOffset": "-180",
            "Accept": "application/json"
        ]
        // JWT Bearer больше не добавляем — Bitrix использует cookies-only сессию.
        // Синхронизируем куки из WKWebView (если WebView их обновил).
        await syncCookiesFromWKWebViewIfNeeded()
        // Берём ТОЛЬКО cookies домена org.fa.ru — не все fa.ru.
        let cookies = (HTTPCookieStorage.shared.cookies ?? [])
            .filter { $0.domain.contains("org.fa.ru") }
        let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        if !cookieHeader.isEmpty {
            headers["Cookie"] = cookieHeader
        }
        return headers
    }

    /// Синхронизирует куки из WKWebView в HTTPCookieStorage (тихо, без ошибок).
    private static func syncCookiesFromWKWebViewIfNeeded() async {
        let wkCookies: [HTTPCookie] = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                cont.resume(returning: cookies.filter { $0.domain.contains("fa.ru") })
            }
        }
        for cookie in wkCookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }
}

// MARK: - Bitrix SSO Handshake (org.fa.ru)

extension NativeAuthManager {

    // =================================================================
    // MARK: - Bitrix SSO Handshake (5 шагов)
    // =================================================================
    ///
    /// Воспроизводит JS-поведение из /local/auth/sso-init.php:
    ///   1) GET /                                        -> PHPSESSID, guest session
    ///   2) GET /bitrix/vuz/sso/link?backurl=%2F         -> JSON {auth_url}
    ///   3) GET auth_url (Keycloak SSO via KEYCLOAK_IDENTITY) -> 302 с code
    ///   4) GET /bitrix/vuz/sso/callback?code=...&state=... -> BX_ORG_FA_RU_* cookies
    ///   5) GET /app/profile/home                        -> метаданные (GUEST_ID, TZ)
    ///
    /// После этого все запросы к /bitrix/vuz/api/* работают ТОЛЬКО на cookies.
    /// JWT НЕ нужен — Bitrix использует собственную сессию.
    ///
    /// Подробности см. в /home/z/my-project/download/lk_auth_diagnostic_v9.py (step5b).
    func bitrixSSOHandshake() async -> Bool {
        bitrixLog("=== Bitrix SSO Handshake (5 шагов) ===")

        let session = makeSession()

        // --- Шаг B1: GET / — получаем PHPSESSID ---
        bitrixLog("[1/5]: GET https://org.fa.ru/")
        guard let url1 = URL(string: "https://org.fa.ru/") else {
            bitrixLog("[1/5]: неверный URL")
            return false
        }
        do {
            var req1 = URLRequest(url: url1)
            req1.httpShouldHandleCookies = true
            let (_, resp1) = try await session.data(for: req1)
            let status1 = (resp1 as? HTTPURLResponse)?.statusCode ?? 0
            bitrixLog("[1/5]: статус \(status1)")
        } catch {
            bitrixLog("[1/5]: ошибка — \(error.localizedDescription)")
            return false
        }

        // --- Шаг B2: GET /bitrix/vuz/sso/link?backurl=%2F — JSON {auth_url} ---
        bitrixLog("[2/5]: GET /bitrix/vuz/sso/link?backurl=%2F")
        guard var comps = URLComponents(string: bitrixSSOLinkURL) else {
            bitrixLog("[2/5]: неверный URL")
            return false
        }
        comps.queryItems = [URLQueryItem(name: "backurl", value: "/")]
        guard let url2 = comps.url else {
            bitrixLog("[2/5]: не удалось построить URL")
            return false
        }
        var authURL: String? = nil
        do {
            var req2 = URLRequest(url: url2)
            req2.httpShouldHandleCookies = true
            req2.setValue("*/*", forHTTPHeaderField: "Accept")
            req2.setValue("https://org.fa.ru/local/auth/sso-init.php?backurl=%2F",
                          forHTTPHeaderField: "Referer")
            let (data2, resp2) = try await session.data(for: req2)
            let status2 = (resp2 as? HTTPURLResponse)?.statusCode ?? 0
            bitrixLog("[2/5]: статус \(status2)")

            if status2 != 200 {
                bitrixLog("[2/5]: ожидался 200")
                return false
            }
            if let json = try? JSONSerialization.jsonObject(with: data2) as? [String: Any],
               let url = json["auth_url"] as? String, !url.isEmpty {
                authURL = url
                bitrixLog("[2/5]: auth_url получен: \(url.prefix(120))...")
            } else {
                let body = String(data: data2, encoding: .utf8) ?? ""
                bitrixLog("[2/5]: auth_url не найден в JSON. Тело: \(body.prefix(200))")
                return false
            }
        } catch {
            bitrixLog("[2/5]: ошибка — \(error.localizedDescription)")
            return false
        }

        guard let authURLString = authURL, let url3 = URL(string: authURLString) else {
            bitrixLog("[3/5]: неверный auth_url")
            return false
        }

        // --- Шаг B3: GET auth_url на Keycloak (SSO) ---
        // Keycloak должен видеть KEYCLOAK_IDENTITY cookie и сразу дать 302 на callback.
        // makeSession() использует RedirectBlockingDelegate — 302 будет перехвачен,
        // и мы сможем извлечь Location с code=...&state=...
        bitrixLog("[3/5]: GET Keycloak auth_url (SSO)")
        var code: String? = nil
        var state: String? = nil
        do {
            var req3 = URLRequest(url: url3)
            req3.httpShouldHandleCookies = true
            let (_, resp3) = try await session.data(for: req3)
            let http3 = resp3 as? HTTPURLResponse
            let status3 = http3?.statusCode ?? 0
            bitrixLog("[3/5]: статус \(status3)")

            if status3 == 302 || status3 == 301,
               let location = http3?.value(forHTTPHeaderField: "Location") {
                bitrixLog("[3/5]: Location -> \(location.prefix(120))...")
                if let comps = URLComponents(string: location) {
                    code = comps.queryItems?.first(where: { $0.name == "code" })?.value
                    state = comps.queryItems?.first(where: { $0.name == "state" })?.value
                }
                if let c = code {
                    bitrixLog("[3/5]: code получен: \(c.prefix(15))...")
                } else {
                    bitrixLog("[3/5]: code НЕ найден в Location")
                    return false
                }
            } else {
                bitrixLog("[3/5]: ожидался 302 от Keycloak, получен \(status3)")
                return false
            }
        } catch {
            bitrixLog("[3/5]: ошибка — \(error.localizedDescription)")
            return false
        }

        guard let code = code, let state = state else {
            bitrixLog("[4/5]: code/state отсутствуют")
            return false
        }

        // --- Шаг B4: GET /bitrix/vuz/sso/callback?code=...&state=... ---
        // Bitrix обменивает code на JWT (через orgfaru-client), создаёт пользователя
        // в своей БД и выставляет BX_ORG_FA_RU_* cookies.
        let callbackURL = "\(bitrixSSOCallbackURL)?code=\(code.urlEncoded)&state=\(state.urlEncoded)"
        bitrixLog("[4/5]: GET \(callbackURL.prefix(80))...")
        guard let url4 = URL(string: callbackURL) else {
            bitrixLog("[4/5]: неверный URL")
            return false
        }
        do {
            // Здесь РАЗРЕШАЕМ редиректы — Bitrix может редиректить обратно на /.
            // Используем временную URLSession без RedirectBlockingDelegate.
            let cfg = URLSessionConfiguration.default
            cfg.httpCookieStorage = HTTPCookieStorage.shared
            cfg.httpShouldSetCookies = true
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 60
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            let followSession = URLSession(configuration: cfg)
            defer { followSession.finishTasksAndInvalidate() }

            var req4 = URLRequest(url: url4)
            req4.httpShouldHandleCookies = true
            req4.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                          forHTTPHeaderField: "Accept")
            req4.setValue("https://auth.fa.ru/", forHTTPHeaderField: "Referer")
            let (_, resp4) = try await followSession.data(for: req4)
            let status4 = (resp4 as? HTTPURLResponse)?.statusCode ?? 0
            bitrixLog("[4/5]: статус \(status4)")
        } catch {
            bitrixLog("[4/5]: ошибка — \(error.localizedDescription)")
            return false
        }

        // --- Шаг B5: GET /app/profile/home — догружаем метаданные ---
        bitrixLog("[5/5]: GET /app/profile/home")
        guard let url5 = URL(string: "https://org.fa.ru/app/profile/home") else {
            bitrixLog("[5/5]: неверный URL")
            // Не критично — BX cookies уже должны быть установлены
            return markBitrixSSODone()
        }
        do {
            var req5 = URLRequest(url: url5)
            req5.httpShouldHandleCookies = true
            let (_, resp5) = try await session.data(for: req5)
            let status5 = (resp5 as? HTTPURLResponse)?.statusCode ?? 0
            bitrixLog("[5/5]: статус \(status5)")
        } catch {
            bitrixLog("[5/5]: ошибка — \(error.localizedDescription)")
            // Не критично
        }

        // Проверяем, что BX_ORG_FA_RU_* cookies установлены
        let bxCount = (HTTPCookieStorage.shared.cookies ?? [])
            .filter { $0.name.hasPrefix("BX_ORG_FA_RU") }
            .count
        bitrixLog("SUCCESS — получено \(bxCount) BX_ORG_FA_RU cookies")
        if bxCount == 0 {
            bitrixLog("WARNING: BX_ORG_FA_RU cookies не найдены — Bitrix-сессия не создана")
            return false
        }

        // Синхронизируем свежие cookies в WKWebView
        await syncBitrixCookiesToWKWebView()
        return markBitrixSSODone()
    }

    /// Гарантирует, что Bitrix-сессия установлена: либо возвращает сразу,
    /// если уже была, либо запускает handshake и ждёт его завершения.
    /// Все fetchBitrix* методы должны вызывать это перед запросом к /bitrix/vuz/api/*.
    static func ensureBitrixSession() async {
        // Если handshake уже выполнен — проверим, что BX cookies реально есть
        if UserDefaults.standard.bool(forKey: "bitrixSSODone") {
            let hasBx = (HTTPCookieStorage.shared.cookies ?? [])
                .contains { $0.name.hasPrefix("BX_ORG_FA_RU") }
            if hasBx { return }
            // Если cookies исчезли (сессия истекла) — запустим handshake заново
            bitrixLog("ensureBitrixSession: bitrixSSODone=true, но BX cookies нет — перезапускаем handshake")
        }

        // Если handshake уже идёт — дождёмся его
        if let task = shared.bitrixSSOTask {
            _ = await task.value
            return
        }

        // Запускаем новый handshake
        let task = Task<Bool, Never> { [weak shared = NativeAuthManager.shared] in
            guard let shared else { return false }
            return await shared.bitrixSSOHandshake()
        }
        shared.bitrixSSOTask = task
        let ok = await task.value
        shared.bitrixSSOTask = nil
        if !ok {
            bitrixLog("ensureBitrixSession: handshake не удался — запросы к org.fa.ru могут вернуть 401")
        }
    }

    /// Сбрасывает флаг Bitrix SSO (для retry при 401 от org.fa.ru).
    static func resetBitrixSSO() {
        UserDefaults.standard.set(false, forKey: "bitrixSSODone")
    }

    @discardableResult
    private func markBitrixSSODone() -> Bool {
        UserDefaults.standard.set(true, forKey: "bitrixSSODone")
        return true
    }

    /// Синхронизирует BX_ORG_FA_RU_* cookies в WKWebView store.
    private func syncBitrixCookiesToWKWebView() async {
        let allCookies = HTTPCookieStorage.shared.cookies ?? []
        let wkStore = WKWebsiteDataStore.default().httpCookieStore
        let faCount = allCookies.filter { $0.domain.contains("fa.ru") }.count
        for cookie in allCookies where cookie.domain.contains("fa.ru") {
            await wkStore.setCookie(cookie)
        }
        bitrixLog("cookies -> WKWebView (\(faCount) шт)")
    }
}

// MARK: - HTML Decode

private extension String {
    var htmlDecoded: String {
        var s = self
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);", options: []) {
            let ns = s as NSString
            let results = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            for result in results.reversed() {
                if let range = Range(result.range, in: s),
                   let numRange = Range(result.range(at: 1), in: s),
                   let code = Int(s[numRange]),
                   let scalar = Unicode.Scalar(code) {
                    s.replaceSubrange(range, with: String(Character(scalar)))
                }
            }
        }
        return s
    }
}

// MARK: - URL Encode

extension String {
    var urlEncoded: String {
        self.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
