import SwiftUI

// MARK: - Заставка с анимацией «fa.schedule»

struct LKSplashView: View {
    let onFinished: () -> Void
    let preload: () async -> Void

    @State private var typedCount = 0
    @State private var showPrefix = false
    @State private var fadeOut = false
    @State private var dataLoaded = false
    @State private var animationDone = false
    @State private var cursorVisible = true

    // Читаем акцентный цвет напрямую из UserDefaults (AppStorage ещё не инициализирован на splash)
    private var splashAccent: Color {
        let raw = UserDefaults.standard.string(forKey: "accentColor") ?? "faTeal"
        return AccentColors.color(raw)
    }

    private let word = "schedule"
    private let typeInterval: TimeInterval = 0.08

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            VStack(spacing: 24) {
                // Анимация маскота (видео)
                LoopingVideoView(videoName: "splash_cat")
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .scaleEffect(showPrefix ? 1.0 : 0.6)
                    .opacity(showPrefix ? 1 : 0)
                    .accessibilityHidden(true)

                HStack(spacing: 0) {
                    // «fa.» — прилетает слева со spring в акцентном цвете
                    Text("fa.")
                        .font(.system(size: 40, weight: .black, design: .rounded))
                        .foregroundColor(splashAccent)
                        .offset(x: showPrefix ? 0 : -200)
                        .opacity(showPrefix ? 1 : 0)
                        .scaleEffect(showPrefix ? 1.0 : 0.5)

                    // «schedule» — печатается по буквам
                    Text(String(word.prefix(typedCount)))
                        .font(.system(size: 40, weight: .black, design: .rounded))
                        .foregroundColor(.primary)

                    // Мигающий курсор
                    if typedCount <= word.count {
                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: 2.5, height: 30)
                            .offset(y: -2)
                            .opacity(cursorVisible ? 1 : 0)
                    }
                }
                // Компенсация: пока «fa.» скрыто, сдвигаем влево,
                // чтобы «schedule» (с курсором) было строго по центру экрана.
                // Когда «fa.» появляется, offset уходит в 0 — «fa.schedule» по центру.
                .offset(x: showPrefix ? 0 : -35)
            }
        }
        .opacity(fadeOut ? 0 : 1)
        .animation(.easeOut(duration: 0.35), value: fadeOut)
        .onAppear { startSequence() }
        .onChange(of: dataLoaded) { _, loaded in
            if loaded && animationDone { finish() }
        }
        .onChange(of: animationDone) { _, done in
            if done && dataLoaded { finish() }
        }
    }

    // MARK: - Последовательность

    private func startSequence() {
        Task {
            await preload()
            dataLoaded = true
        }

        startCursorBlink()

        var count = 0
        Timer.scheduledTimer(withTimeInterval: typeInterval, repeats: true) { timer in
            count += 1
            typedCount = count

            if count >= word.count {
                timer.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    animatePrefix()
                }
            }
        }
    }

    private func startCursorBlink() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            cursorVisible.toggle()
        }
    }

    private func animatePrefix() {
        cursorVisible = false
        withAnimation(.spring(response: 0.55, dampingFraction: 0.62, blendDuration: 0.2)) {
            showPrefix = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            animationDone = true
        }
    }

    private func finish() {
        withAnimation(.easeOut(duration: 0.3)) {
            fadeOut = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            onFinished()
        }
    }
}
