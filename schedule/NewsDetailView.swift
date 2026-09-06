import SwiftUI
import Combine
import SafariServices

// ======================================================================
// NewsDetailView.swift — Нативный предпросмотр новости (sheet)
// Унифицирован со стилем страницы расписания:
// 1. Непрозрачный фон (Palette.background)
// 2. Toolbar с кнопками в углах (xmark слева, share/safari справа)
// 3. Тот же визуальный язык, что у LessonDetailContainer
// ======================================================================

struct NewsDetailView: View {
    let item: NewsItem
    var transparentBackground: Bool = false
    @StateObject private var viewModel: NewsDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingLink: URL?

    init(item: NewsItem, transparentBackground: Bool = false) {
        self.item = item
        self.transparentBackground = transparentBackground
        self._viewModel = StateObject(wrappedValue: NewsDetailViewModel(item: item))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Главное изображение (если есть)
                if let article = viewModel.article,
                   let imageURL = article.imageURL,
                   let url = URL(string: imageURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity)
                                .frame(height: 220)
                                .clipped()
                        case .failure:
                            Color.clear.frame(height: 0)
                        default:
                            Color(.secondarySystemGroupedBackground)
                                .frame(height: 220)
                                .overlay(ProgressView())
                        }
                    }
                    .padding(.bottom, 16)
                }

                // Заголовок и мета
                if let article = viewModel.article {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(article.title)
                            .font(.title2.bold())
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 8) {
                            if !article.date.isEmpty {
                                Label(article.date, systemImage: "calendar")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let tag = item.displayTag {
                                Text(tag)
                                    .font(.caption2.weight(.medium))
                                    .foregroundColor(.accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                    // Кнопка «Открыть на сайте»
                    Button {
                        openInSafari(urlString: article.sourceURL)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "safari")
                            Text("Открыть на сайте")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                    Divider()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)

                    // Блоки контента
                    if article.blocks.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary.opacity(0.4))
                            Text("Содержимое новости недоступно для предпросмотра.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                            Button {
                                openInSafari(urlString: item.fullLinkURL)
                            } label: {
                                Label("Открыть на сайте", systemImage: "safari")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                    } else {
                        ForEach(article.blocks) { block in
                            blockView(block)
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .background {
            if transparentBackground {
                Color.clear
            } else {
                Palette.background.ignoresSafeArea()
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
            }
            if let article = viewModel.article {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: URL(string: article.sourceURL) ?? URL(string: "https://www.fa.ru")!) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openURL(URL(string: article.sourceURL)!)
                    } label: {
                        Image(systemName: "safari")
                    }
                }
            }
        }
        .task {
            await viewModel.load()
        }
        // Подтверждение перехода по ссылке — alert по центру, читаемо
        .alert(
            "Переход по ссылке",
            isPresented: Binding(
                get: { pendingLink != nil },
                set: { if !$0 { pendingLink = nil } }
            ),
            presenting: pendingLink
        ) { url in
            // "Открыть" — заполненная (default), "Отмена" — прозрачная (cancel)
            Button("Открыть", role: .none) {
                openURL(url)
                pendingLink = nil
            }
            Button("Отмена", role: .cancel) {
                pendingLink = nil
            }
        } message: { url in
            Text(url.absoluteString)
        }
    }

    // MARK: - Рендер блоков

    @ViewBuilder
    private func blockView(_ block: ArticleBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text)
                .font(.body)
                .foregroundColor(.primary)
                .lineSpacing(4)
                .padding(.bottom, 16)
                .multilineTextAlignment(.leading)

        case .richParagraph(let segments):
            richParagraphView(segments)
                .padding(.bottom, 16)

        case .image(let urlString):
            if let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.vertical, 8)
                    case .failure:
                        emptyImagePlaceholder
                    default:
                        Color(.secondarySystemGroupedBackground)
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(ProgressView())
                            .padding(.vertical, 8)
                    }
                }
            }

        case .gallery(let urls):
            GalleryView(imageURLs: urls)
                .padding(.vertical, 8)

        case .heading(let text, let level):
            Text(text)
                .font({
                    switch level {
                    case 1: return Font.title2.bold()
                    case 2: return Font.title3.bold()
                    default: return Font.headline
                    }
                }())
                .foregroundColor(.primary)
                .padding(.top, 20)
                .padding(.bottom, 10)
                .multilineTextAlignment(.leading)

        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.accentColor)
                            .frame(width: 20, alignment: .leading)
                        Text(item)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.bottom, 16)

        case .quote(let text):
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                Text(text)
                    .font(.subheadline.italic())
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .padding(.bottom, 16)

        case .divider:
            Divider()
                .padding(.vertical, 16)
        }
    }

    // MARK: - Абзац со ссылками

    @ViewBuilder
    private func richParagraphView(_ segments: [TextSegment]) -> some View {
        // Собираем AttributedString с ссылками
        let attrString = segments.reduce(into: AttributedString()) { result, seg in
            var segAttr = AttributedString(seg.text)
            if let urlString = seg.linkURL, let url = URL(string: urlString) {
                segAttr.link = url
                segAttr.foregroundColor = .accentColor
                segAttr.underlineStyle = .single
            } else {
                segAttr.foregroundColor = .primary
            }
            result += segAttr
        }

        Text(attrString)
            .font(.body)
            .lineSpacing(4)
            .multilineTextAlignment(.leading)
            .environment(\.openURL, OpenURLAction { url in
                pendingLink = url
                return .handled
            })
    }

    // MARK: - Состояния

    private var emptyImagePlaceholder: some View {
        Color(.secondarySystemGroupedBackground)
            .frame(height: 100)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary.opacity(0.3))
            )
            .padding(.vertical, 8)
    }

    // MARK: - Открытие ссылок

    private func openURL(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    private func openInSafari(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        openURL(url)
    }

    private func openInSafariURL(_ url: URL) {
        openURL(url)
    }
}

// ======================================================================
// ViewModel для предпросмотра статьи
// ======================================================================

@MainActor
class NewsDetailViewModel: ObservableObject {
    @Published var article: NewsArticle?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let item: NewsItem

    init(item: NewsItem) {
        self.item = item
    }

    func load() async {
        isLoading = true
        article = await NewsManager.shared.fetchArticle(item)
        if article == nil {
            errorMessage = "Не удалось загрузить содержимое статьи"
        }
        isLoading = false
    }
}

// MARK: - Галерея фотографий (слайдер)
struct GalleryView: View {
    let imageURLs: [String]
    @State private var currentIndex = 0

    var body: some View {
        VStack(spacing: 8) {
            TabView(selection: $currentIndex) {
                ForEach(Array(imageURLs.enumerated()), id: \.offset) { index, urlString in
                    if let url = URL(string: urlString) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            case .failure:
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(.tertiarySystemGroupedBackground))
                                    .overlay(
                                        Image(systemName: "photo")
                                            .font(.largeTitle)
                                            .foregroundColor(.secondary.opacity(0.3))
                                    )
                                    .frame(height: 200)
                            default:
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(.secondarySystemGroupedBackground))
                                    .overlay(ProgressView())
                                    .frame(height: 200)
                            }
                        }
                        .tag(index)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: imageURLs.count > 1 ? .automatic : .never))
            .frame(height: 280)

            // Счётчик фото
            if imageURLs.count > 1 {
                HStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.caption)
                    Text("\(currentIndex + 1) / \(imageURLs.count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                .foregroundColor(.secondary)
            }
        }
    }
}
