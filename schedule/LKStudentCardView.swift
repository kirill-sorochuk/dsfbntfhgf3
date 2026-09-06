import SwiftUI
import UIKit
import PDFKit

// MARK: - Студенческий билет

struct LKStudentCardView: View {
    @ObservedObject var manager = LKManager.shared
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var isPresenting = false
    @State private var savedBrightness: CGFloat = 0.5

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Загрузка студенческого билета...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else if let error = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.orange.opacity(0.7))
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Повторить") {
                        errorMessage = nil
                        Task { await loadCard() }
                    }
                    .font(.subheadline.bold())
                    .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 40)
            } else if let cardData = manager.studentCardData,
                      let pdfURL = saveToTemp(cardData) {
                // PDF загружен — показываем превью в горизонтальном A5
                VStack(spacing: 24) {
                    // Превью PDF — горизонтальная ориентация (A5 landscape)
                    // A5 landscape: ~595×420 pt (половина A4 landscape).
                    // aspectRatio заставляет PDF保持在 альбомной ориентации.
                    PDFPreviewView(url: pdfURL)
                        .aspectRatio(1.414, contentMode: .fit)  // A5 landscape ratio
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                        .padding(.horizontal, 20)

                    // Кнопки
                    VStack(spacing: 12) {
                        // Кнопка «Предъявить» (основная) — разворачивает в горизонтальный вид + яркость
                        Button {
                            presentCard()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "creditcard.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                Text("Предъявить")
                                    .font(.headline)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .padding(.horizontal, 20)

                        // Кнопка «Поделиться» (остаётся как было)
                        Button {
                            shareCard(url: pdfURL)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.up")
                                Text("Поделиться")
                                    .font(.subheadline.weight(.medium))
                            }
                            .foregroundColor(.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.top, 16)
            } else {
                // Нет данных — кнопка загрузки
                VStack(spacing: 16) {
                    Image(systemName: "creditcard")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Студенческий билет не загружен")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button("Загрузить") {
                        Task { await loadCard() }
                    }
                    .font(.subheadline.bold())
                    .foregroundColor(.accentColor)
                }
            }
        }
        .navigationTitle("Студенческий билет")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    manager.clearStudentCardCache()
                    Task { await loadCard() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        #endif
        .fullScreenCover(isPresented: $isPresenting) {
            StudentCardPresentView(onDismiss: {
                restoreBrightness()
                isPresenting = false
            })
        }
        .task {
            // Если данные уже есть — не загружаем повторно
            if manager.studentCardData == nil {
                await loadCard()
            }
        }
    }

    // MARK: - Загрузка

    private func loadCard() async {
        isLoading = true
        errorMessage = nil
        await LKManager.shared.fetchStudentCard()
        if manager.studentCardData == nil {
            errorMessage = "Не удалось загрузить студенческий билет. Проверьте подключение к интернету и авторизуйтесь в личном кабинете."
        }
        isLoading = false
    }

    // MARK: - Временный файл для PDF

    private func saveToTemp(_ data: Data) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("student_card_display.pdf")
        try? data.write(to: url)
        return url
    }

    // MARK: - Предъявление (полноэкранный режим + максимальная яркость)

    private func presentCard() {
        savedBrightness = UIScreen.main.brightness
        isPresenting = true
    }

    private func restoreBrightness() {
        UIScreen.main.brightness = savedBrightness
    }

    // MARK: - Поделиться (остаётся как было — UIActivityViewController)

    private func shareCard(url: URL) {
        #if os(iOS)
        let activityVC = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            topVC.present(activityVC, animated: true)
        }
        #endif
    }
}

// MARK: - Превью PDF (через PDFKit)

struct PDFPreviewView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = PDFDocument(url: url)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.backgroundColor = .white
        pdfView.isUserInteractionEnabled = false
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document == nil {
            uiView.document = PDFDocument(url: url)
        }
    }
}

// MARK: - Полноэкранный режим предъявления (горизонтальный + макс. яркость)

struct StudentCardPresentView: View {
    let onDismiss: () -> Void
    @State private var appear = false

    var body: some View {
        ZStack {
            // Белый фон (максимальная яркость для сканирования)
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                // Верхняя панель с кнопкой закрытия
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appear = false
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onDismiss()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.black.opacity(0.6))
                    }
                    Spacer()
                    Text("СТУДЕНЧЕСКИЙ БИЛЕТ")
                        .font(.caption.bold())
                        .foregroundColor(.black.opacity(0.4))
                        .tracking(1)
                    Spacer()
                    // Индикатор максимальной яркости (активной)
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.yellow)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()

                // PDF студенческого билета — горизонтальная ориентация
                if let cardData = LKManager.shared.studentCardData,
                   let pdfURL = saveToTemp(cardData) {
                    PDFPreviewView(url: pdfURL)
                        .aspectRatio(1.414, contentMode: .fit)  // A5 landscape
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                }

                Spacer()

                // Подсказка
                Text("Предъявите для проверки")
                    .font(.caption)
                    .foregroundColor(.black.opacity(0.3))
                    .padding(.bottom, 20)
            }
        }
        .statusBarHidden()
        .ignoresSafeArea()
        .onAppear {
            // Плавно увеличиваем яркость до максимума + фиксируем горизонтальную ориентацию
            withAnimation(.easeIn(duration: 0.5)) {
                UIScreen.main.brightness = 1.0
                appear = true
            }
            // Принудительно горизонтальная ориентация (landscape right)
            UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
        }
        .onDisappear {
            // Возвращаем портретную ориентацию
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
        }
    }

    private func saveToTemp(_ data: Data) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("student_card_present.pdf")
        try? data.write(to: url)
        return url
    }
}
