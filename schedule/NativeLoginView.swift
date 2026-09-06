// ======================================================================
// NativeLoginView.swift — Нативная авторизация в стиле iOS
// ======================================================================

import SwiftUI

// MARK: - Shake Effect (ViewModifier)

struct ShakeViewModifier: ViewModifier {
    let isShaking: Bool
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .onChange(of: isShaking) { _, newValue in
                guard newValue else { return }
                withAnimation(.spring(duration: 0.4, bounce: 0.3)) {
                    offset = -12
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                        offset = 12
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.spring(duration: 0.2)) {
                        offset = -6
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    withAnimation(.spring(duration: 0.2)) {
                        offset = 0
                    }
                }
            }
    }
}

extension View {
    func shake(_ isShaking: Bool) -> some View {
        modifier(ShakeViewModifier(isShaking: isShaking))
    }
}

// MARK: - Main View

struct NativeLoginView: View {
    @StateObject private var auth = NativeAuthManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedField: Field?
    @State private var isSubmitting: Bool = false
    @State private var wasOnOTP: Bool = false
    @State private var shakeTrigger: Bool = false
    @AppStorage("rememberMe") private var rememberMe = false
    @State private var previousRememberState = false

    var onAuthSuccess: (() -> Void)?

    enum Field {
        case username, password, otp
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 20)

                        logoSection
                            .padding(.bottom, 28)

                        if auth.step == .waitingForOTP || auth.step == .sendingOTP {
                            otpSection
                        } else {
                            loginSection
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(Circle())
                    }
                }
            }
        }
        .onChange(of: auth.step) { _, newStep in
            handleStepChange(newStep)
        }
        .task {
            previousRememberState = rememberMe
            // Сохраняем текущие креды до reset внутри startAuth
            let savedUsername = KeychainHelper.loadString(key: "savedUsername")
            let savedPassword = KeychainHelper.loadString(key: "savedPassword")

            auth.onAuthSuccess = { _ in
                onAuthSuccess?()
            }
            await auth.startAuth()

            // Восстанавливаем креды после reset() внутри startAuth
            if rememberMe {
                if let u = savedUsername { auth.username = u }
                if let p = savedPassword { auth.password = p }
            }
        }
        .onChange(of: auth.errorMessage) { _, newError in
            if newError != nil {
                shakeTrigger = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    shakeTrigger = false
                }
            }
        }
    }

    // MARK: - Логотип

    private var logoSection: some View {
        VStack(spacing: 12) {
            if let uiImage = UIImage(named: "finLogo") {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 56)
            } else {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.1))
                        .frame(width: 72, height: 72)

                    Image(systemName: "lock.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }

            Text("Вход в личный кабинет")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Секция логина (нативный iOS стиль)

    private var loginSection: some View {
        VStack(spacing: 0) {
            // Ошибка (над формой)
            if let error = auth.errorMessage {
                errorBanner(error)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Форма
            VStack(spacing: 0) {
                // Логин
                HStack {
                    Image(systemName: "person")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)

                    TextField("Логин", text: $auth.username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()
                    .padding(.leading, 40)

                // Пароль
                HStack {
                    Image(systemName: "lock")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)

                    if auth.isPasswordVisible {
                        TextField("Пароль", text: $auth.password)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.asciiCapable)
                            .focused($focusedField, equals: .password)
                            .submitLabel(.go)
                            .onSubmit {
                                submitCredentials()
                            }
                    } else {
                        SecureField("Пароль", text: $auth.password)
                            .textContentType(.password)
                            .focused($focusedField, equals: .password)
                            .submitLabel(.go)
                            .onSubmit {
                                submitCredentials()
                            }
                    }

                    Button {
                        auth.isPasswordVisible.toggle()
                    } label: {
                        Image(systemName: auth.isPasswordVisible ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 15))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shake(shakeTrigger)

            // Запомнить меня
            Toggle(isOn: $rememberMe) {
                Text("Запомнить меня")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .tint(.accentColor)
            .padding(.top, 12)
            .padding(.leading, 4)

            // Кнопка входа
            loginButton
                .padding(.top, 20)
        }
    }

    // Кнопка входа
    private var loginButton: some View {
        Button {
            submitCredentials()
        } label: {
            SwiftUI.Group {
                if auth.isLoading && (auth.step == .sendingCredentials || auth.step == .loadingForm) {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Войти")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                isLoginButtonEnabled
                    ? Color.accentColor
                    : Color.accentColor.opacity(0.4)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!isLoginButtonEnabled || isSubmitting)
    }

    // MARK: - Секция OTP (нативный стиль с 6 квадратиками)

    private var otpSection: some View {
        VStack(spacing: 0) {
            // Иконка и текст
            VStack(spacing: 8) {
                Image(systemName: "message.badge")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)

                Text("Введите код подтверждения")
                    .font(.headline)

                Text("Код отправлен в МАКС")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 24)

            // Ошибка
            if let error = auth.errorMessage {
                errorBanner(error)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // 6 квадратиков для кода
            otpCodeBoxes
                .padding(.bottom, 16)

            // Скрытый TextField для ввода
            TextField("", text: $auth.otpCode)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .focused($focusedField, equals: .otp)
                .submitLabel(.go)
                .onSubmit {
                    if auth.otpCode.count >= 6 {
                        submitOTP()
                    }
                }
                .onChange(of: auth.otpCode) { _, newValue in
                    let filtered = newValue.filter { $0.isNumber }.prefix(6)
                    if filtered != newValue {
                        auth.otpCode = String(filtered)
                    }
                    // Автоматическая отправка при 6 символах
                    if auth.otpCode.count == 6 && !isSubmitting {
                        submitOTP()
                    }
                }
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)

            // Кнопка подтвердить
            otpButton
                .padding(.top, 8)

            // Таймер и resend
            if auth.resendCountdown > 0 || auth.canResend {
                VStack(spacing: 12) {
                    if auth.resendCountdown > 0 {
                        Text("Повторная отправка через \(auth.resendCountdown) сек")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        resendButton(title: "МАКС", icon: "message", channel: "max")
                        resendButton(title: "E-mail", icon: "envelope", channel: "email")
                    }
                }
                .padding(.top, 20)
            }

            // Кнопка «Ввести другой аккаунт»
            Button {
                auth.otpCode = ""
                auth.errorMessage = nil
                auth.step = .idle
            } label: {
                Text("Ввести другой аккаунт")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)
        }
    }

    // 6 квадратиков для OTP кода
    private var otpCodeBoxes: some View {
        HStack(spacing: 10) {
            ForEach(0..<6, id: \.self) { index in
                otpBox(index: index)
            }
        }
        .onTapGesture {
            focusedField = .otp
        }
    }

    private func otpBox(index: Int) -> some View {
        let digit = auth.otpCode.count > index
            ? String(auth.otpCode.dropFirst(index).prefix(1))
            : ""
        let isActive = auth.otpCode.count == index
        let isFilled = digit != ""

        return ZStack {
            // Фоновый квадрат
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(width: 46, height: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isActive ? Color.accentColor : Color(.separator).opacity(0.6),
                            lineWidth: isActive ? 2 : 1
                        )
                )

            // Цифра или курсор
            if isFilled {
                Text(digit)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            } else if isActive {
                // Мигающий курсор
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 28)
                    .opacity(1)
            }
        }
        .shake(shakeTrigger)
    }

    // Кнопка подтвердить OTP
    private var otpButton: some View {
        Button {
            submitOTP()
        } label: {
            SwiftUI.Group {
                if auth.isLoading && auth.step == .sendingOTP {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Подтвердить")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                isOTPButtonEnabled
                    ? Color.accentColor
                    : Color.accentColor.opacity(0.4)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!isOTPButtonEnabled || isSubmitting)
    }

    // MARK: - Компоненты

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 13))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.red)
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func resendButton(title: String, icon: String, channel: String) -> some View {
        Button {
            Task {
                await auth.resendCode(channel: channel)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(title)
                    .font(.subheadline)
            }
            .foregroundStyle(auth.canResend ? .accentColor : Color(.quaternaryLabel))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(!auth.canResend || auth.isLoading)
    }

    // MARK: - Логика кнопок

    private var isLoginButtonEnabled: Bool {
        !auth.username.trimmingCharacters(in: .whitespaces).isEmpty
            && !auth.password.isEmpty
            && !auth.isLoading
    }

    /// Кнопка «Подтвердить» активна только при 6 символах
    private var isOTPButtonEnabled: Bool {
        auth.otpCode.trimmingCharacters(in: .whitespaces).count == 6
            && !auth.isLoading
            && auth.step == .waitingForOTP
    }

    // MARK: - Действия

    private func submitCredentials() {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            await auth.submitCredentials()
            isSubmitting = false
        }
    }

    private func submitOTP() {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            await auth.submitOTP()
            isSubmitting = false
        }
    }

    // MARK: - Обработка смены шага

    private func handleStepChange(_ newStep: NativeAuthStep) {
        switch newStep {
        case .waitingForOTP:
            isSubmitting = false
            wasOnOTP = true
            focusedField = .otp
        case .success:
            // НЕ dismiss здесь — ждём onAuthSuccess от вызывающей стороны
            break
        case .error:
            isSubmitting = false
        case .idle:
            isSubmitting = false
            if wasOnOTP {
                // Полный сброс формы при возврате к логину
                auth.username = ""
                auth.password = ""
                auth.reset()
                wasOnOTP = false
            }
        default:
            break
        }
    }
}
