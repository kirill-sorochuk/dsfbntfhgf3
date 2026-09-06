import Foundation
import Combine
import SwiftSoup

// MARK: - Модели

struct NewsItem: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let date: String
    let tag: String?
    let imageURL: String?
    let link: String
    let section: NewsSection
    let faculty: Faculty?

    init(id: String, title: String, date: String, tag: String?,
         imageURL: String?, link: String, section: NewsSection, faculty: Faculty? = nil) {
        self.id = id
        self.title = title
        self.date = date
        self.tag = tag
        self.imageURL = imageURL
        self.link = link
        self.section = section
        self.faculty = faculty
    }

    var displayDate: String {
        let trimmed = date.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
    }
    var displayTag: String? { tag?.trimmingCharacters(in: .whitespaces).isEmpty == false ? tag : nil }

    var fullImageURL: String? {
        guard let imageURL, !imageURL.isEmpty else { return nil }
        if imageURL.hasPrefix("http") { return imageURL }
        if imageURL.hasPrefix("//") { return "https:\(imageURL)" }
        return "https://www.fa.ru\(imageURL)"
    }

    var fullLinkURL: String {
        if link.hasPrefix("http") { return link }
        return "https://www.fa.ru\(link)"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: NewsItem, rhs: NewsItem) -> Bool { lhs.id == rhs.id }
}

// MARK: - Сегмент текста (для абзацев со ссылками)

struct TextSegment: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let linkURL: String?   // nil = обычный текст
}

// MARK: - Статья для предпросмотра

struct NewsArticle: Identifiable {
    let id: String
    let title: String
    let date: String
    let imageURL: String?
    let blocks: [ArticleBlock]
    let sourceURL: String
}

enum ArticleBlock: Identifiable {
    case paragraph(String)
    case richParagraph([TextSegment])
    case image(String)
    case gallery([String])
    case heading(String, level: Int)
    case list([String], ordered: Bool)
    case quote(String)
    case divider

    var id: String {
        switch self {
        case .paragraph(let t): return "p_\(t.prefix(20))"
        case .richParagraph(let segs): return "rp_\(segs.first?.text.prefix(20) ?? "")"
        case .image(let u): return "img_\(u)"
        case .gallery(let urls): return "gal_\(urls.count)_\(urls.first?.prefix(10) ?? "")"
        case .heading(let t, let l): return "h\(l)_\(t.prefix(20))"
        case .list(let items, let o): return "\(o ? "ol" : "ul")_\(items.count)"
        case .quote(let t): return "q_\(t.prefix(20))"
        case .divider: return "divider"
        }
    }
}

// MARK: - Формат отображения

enum NewsDisplayFormat: String, CaseIterable {
    case list = "list"
    case grid = "grid"
    case big = "big"

    var label: String {
        switch self {
        case .list: return "Список"
        case .grid: return "Умная плитка"
        case .big: return "Крупные"
        }
    }

    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        case .big: return "rectangle.grid.1x2"
        }
    }
}

// MARK: - Секции новостей

enum NewsSection: String, CaseIterable, Identifiable, Codable, Hashable {
    case university = "university"
    case science = "science"
    case sport = "sport"
    case faculties = "faculties"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .university: return "Университет"
        case .science: return "Студенческая наука"
        case .sport: return "Спорт"
        case .faculties: return "Факультеты"
        }
    }

    var icon: String {
        switch self {
        case .university: return "building.columns"
        case .science: return "atom"
        case .sport: return "trophy"
        case .faculties: return "building.2.crop.circle"
        }
    }

    var pageURL: String {
        switch self {
        case .university:     return "https://www.fa.ru/university/press-center/"
        case .science:        return "https://www.fa.ru/for-students/student-science/nso/news/"
        case .sport:          return "https://www.fa.ru/university/structure/education/sk/news/"
        case .faculties:      return ""
        }
    }

    var ajaxBaseURL: String {
        "https://www.fa.ru/ajax/news-tab.php"
    }

    var cacheKey: String { "news_\(rawValue)" }
    var pageKey: String { "news_\(rawValue)_page" }
    var blockKey: String { "news_\(rawValue)_block" }
}

// MARK: - Факультеты

enum Faculty: String, CaseIterable, Identifiable, Codable, Hashable {
    case itabd = "itabd"
    case vsu   = "vsu"
    case snmk  = "snmk"
    case ff    = "ff"
    case eib   = "eib"
    case ui    = "ui"
    case naba  = "naba"
    case meo   = "meo"

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .itabd: return "ИТиАБД"
        case .vsu:   return "ВШУ"
        case .snmk:  return "СНиМК"
        case .ff:    return "ФинФак"
        case .eib:   return "ФЭБ"
        case .ui:    return "ЮрФак"
        case .naba:  return "НАБ"
        case .meo:   return "МЭО"
        }
    }

    var fullTitle: String {
        switch self {
        case .itabd: return "ИТ и АБД"
        case .vsu:   return "Высшая школа управления"
        case .snmk:  return "Социология и политология"
        case .ff:    return "Финансовый факультет"
        case .eib:   return "Факультет экономики и бизнеса"
        case .ui:    return "Юридический факультет"
        case .naba:  return "Налоги и аудит"
        case .meo:   return "Международные экономические отношения"
        }
    }

    var pageURL: String {
        "https://www.fa.ru/university/structure/scientific-educational-departments/\(rawValue)/"
    }

    var cacheKey: String { "news_fac_\(rawValue)" }
    var pageKey: String { "news_fac_\(rawValue)_page" }
    var blockKey: String { "news_fac_\(rawValue)_block" }
}

// MARK: - NewsManager

@MainActor
class NewsManager: ObservableObject {
    static let shared = NewsManager()

    // --- Секции ---
    @Published var items: [NewsSection: [NewsItem]] = [:]
    @Published var isLoading: [NewsSection: Bool] = [:]
    @Published var isLoadingMore: [NewsSection: Bool] = [:]
    @Published var error: [NewsSection: String?] = [:]
    @Published var selectedSection: NewsSection = .university
    @Published var hasMore: [NewsSection: Bool] = [:]

    // --- Факультеты ---
    @Published var selectedFaculty: Faculty?
    @Published var facultyItems: [Faculty: [NewsItem]] = [:]
    @Published var facultyIsLoading: [Faculty: Bool] = [:]
    @Published var facultyIsLoadingMore: [Faculty: Bool] = [:]
    @Published var facultyError: [Faculty: String?] = [:]
    @Published var facultyHasMore: [Faculty: Bool] = [:]

    // --- Кеш ---
    private var articleCache: [String: NewsArticle] = [:]
    private let cacheDir = FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask
    )[0].appendingPathComponent("NewsCache", isDirectory: true)
    private let defaults = UserDefaults.standard

    // --- Сессия ---
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.httpShouldSetCookies = false
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "ru"
        ]
        return URLSession(configuration: config)
    }()

    // MARK: - Закреплённый / последний факультет

    var pinnedFaculty: Faculty? {
        get {
            guard let raw = defaults.string(forKey: "news_pinned_faculty") else { return nil }
            return Faculty(rawValue: raw)
        }
        set {
            if let v = newValue {
                defaults.set(v.rawValue, forKey: "news_pinned_faculty")
            } else {
                defaults.removeObject(forKey: "news_pinned_faculty")
            }
            objectWillChange.send()
        }
    }

    var lastViewedFaculty: Faculty? {
        get {
            guard let raw = defaults.string(forKey: "news_last_faculty") else { return nil }
            return Faculty(rawValue: raw)
        }
        set {
            if let v = newValue {
                defaults.set(v.rawValue, forKey: "news_last_faculty")
            } else {
                defaults.removeObject(forKey: "news_last_faculty")
            }
        }
    }

    /// Задать факультет студента (вызвать из ЛК после загрузки профиля)
    func setStudentFaculty(_ faculty: Faculty) {
        defaults.set(faculty.rawValue, forKey: "news_student_faculty")
    }

    private var studentFaculty: Faculty? {
        guard let raw = defaults.string(forKey: "news_student_faculty") else { return nil }
        return Faculty(rawValue: raw)
    }

    /// Показывать подсказку по факультетам?
    var showFacultyHint: Bool {
        get { !defaults.bool(forKey: "news_fac_hint_shown") }
        set { defaults.set(!newValue, forKey: "news_fac_hint_shown") }
    }

    /// Факультеты для отображения: закреплённый первый, потом остальные
    var sortedFaculties: [Faculty] {
        var all = Faculty.allCases
        if let pinned = pinnedFaculty {
            all.removeAll { $0 == pinned }
            all.insert(pinned, at: 0)
        }
        return all
    }

    private init() {
        for section in NewsSection.allCases where section != .faculties {
            loadCached(section)
            isLoading[section] = false
            isLoadingMore[section] = false
            error[section] = nil
            hasMore[section] = true
        }
        for fac in Faculty.allCases {
            loadCachedFaculty(fac)
            facultyIsLoading[fac] = false
            facultyIsLoadingMore[fac] = false
            facultyError[fac] = nil
            facultyHasMore[fac] = true
        }
    }

    // MARK: - Публичный API (секции)

    func loadIfNeeded(_ section: NewsSection) {
        if section == .faculties {
            selectDefaultFaculty()
            return
        }
        guard items[section]?.isEmpty ?? true else { return }
        loadNews(section)
    }

    func refresh(_ section: NewsSection) {
        if section == .faculties {
            if let fac = selectedFaculty { refreshFaculty(fac) }
            return
        }
        loadNews(section)
    }

    func loadMore(_ section: NewsSection) {
        guard !(isLoadingMore[section] ?? false), hasMore[section] ?? true else { return }
        Task { await loadNextPage(section) }
    }

    // MARK: - Публичный API (факультеты)

    func selectFaculty(_ faculty: Faculty) {
        selectedFaculty = faculty
        lastViewedFaculty = faculty
        loadFacultyIfNeeded(faculty)
    }

    func loadFacultyIfNeeded(_ faculty: Faculty) {
        guard facultyItems[faculty]?.isEmpty ?? true else { return }
        loadFacultyNews(faculty)
    }

    func refreshFaculty(_ faculty: Faculty) {
        loadFacultyNews(faculty)
    }

    func loadMoreFaculty(_ faculty: Faculty) {
        guard !(facultyIsLoadingMore[faculty] ?? false),
              facultyHasMore[faculty] ?? true else { return }
        Task { await loadFacultyNextPage(faculty) }
    }

    func togglePinFaculty(_ faculty: Faculty) {
        if pinnedFaculty == faculty {
            pinnedFaculty = nil
        } else {
            pinnedFaculty = faculty
        }
    }

    private func selectDefaultFaculty() {
        if selectedFaculty != nil { return } // уже выбран
        if pinnedFaculty != nil {
            selectFaculty(pinnedFaculty!)
        } else if lastViewedFaculty != nil {
            selectFaculty(lastViewedFaculty!)
        } else if studentFaculty != nil {
            selectFaculty(studentFaculty!)
        } else {
            selectFaculty(Faculty.allCases[0])
        }
    }

    // MARK: - Загрузка статей

    func fetchArticle(_ item: NewsItem) async -> NewsArticle? {
        if let cached = articleCache[item.id] { return cached }
        guard let url = URL(string: item.fullLinkURL) else { return nil }
        do {
            let (data, _) = try await session.data(for: URLRequest(url: url))
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            let doc = try SwiftSoup.parse(html)
            let article = parseArticle(doc, item: item)
            articleCache[item.id] = article
            return article
        } catch {
            print("[NEWS] Article fetch error: \(error)")
            return nil
        }
    }

    // MARK: - Загрузка первой страницы (секции)

    private func loadNews(_ section: NewsSection) {
        guard !(isLoading[section] ?? false), section != .faculties else { return }
        isLoading[section] = true
        error[section] = nil

        Task {
            do {
                var request = URLRequest(url: URL(string: section.pageURL)!)
                request.httpMethod = "GET"
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let html = String(data: data, encoding: .utf8) else {
                    throw NewsError.invalidResponse
                }
                let doc = try SwiftSoup.parse(html)
                let parsed = parseNewsCards(doc, section: section, faculty: nil)
                if let blockID = extractBlockID(doc) {
                    defaults.set(blockID, forKey: section.blockKey)
                }
                if !parsed.isEmpty {
                    items[section] = parsed
                    defaults.set(1, forKey: section.pageKey)
                    hasMore[section] = true
                    saveToCache(section, items: parsed)
                } else {
                    let fallbackBlock = defaults.string(forKey: section.blockKey) ?? "1"
                    let ajaxItems = try await fetchAjaxPage(section: section, page: 1, block: fallbackBlock, faculty: nil)
                    if !ajaxItems.isEmpty {
                        items[section] = ajaxItems
                        defaults.set(1, forKey: section.pageKey)
                        hasMore[section] = true
                        saveToCache(section, items: ajaxItems)
                    }
                }
                if items[section]?.isEmpty ?? true {
                    error[section] = "Не удалось загрузить новости"
                }
            } catch let caughtError {
                if items[section]?.isEmpty ?? true {
                    error[section] = (caughtError as NSError).localizedDescription
                }
                print("[NEWS] \(section.title): \(caughtError)")
            }
            isLoading[section] = false
        }
    }

    // MARK: - Загрузка первой страницы (факультеты)

    private func loadFacultyNews(_ faculty: Faculty) {
        guard !(facultyIsLoading[faculty] ?? false) else { return }
        facultyIsLoading[faculty] = true
        facultyError[faculty] = nil

        Task {
            do {
                var request = URLRequest(url: URL(string: faculty.pageURL)!)
                request.httpMethod = "GET"
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let html = String(data: data, encoding: .utf8) else {
                    throw NewsError.invalidResponse
                }
                let doc = try SwiftSoup.parse(html)
                let parsed = parseNewsCards(doc, section: .faculties, faculty: faculty)
                if let blockID = extractBlockID(doc) {
                    defaults.set(blockID, forKey: faculty.blockKey)
                }
                if !parsed.isEmpty {
                    facultyItems[faculty] = parsed
                    defaults.set(1, forKey: faculty.pageKey)
                    facultyHasMore[faculty] = true
                    saveToCacheFaculty(faculty, items: parsed)
                } else {
                    let fallbackBlock = defaults.string(forKey: faculty.blockKey) ?? "1"
                    let ajaxItems = try await fetchAjaxPage(section: .faculties, page: 1, block: fallbackBlock, faculty: faculty)
                    if !ajaxItems.isEmpty {
                        facultyItems[faculty] = ajaxItems
                        defaults.set(1, forKey: faculty.pageKey)
                        facultyHasMore[faculty] = true
                        saveToCacheFaculty(faculty, items: ajaxItems)
                    }
                }
                if facultyItems[faculty]?.isEmpty ?? true {
                    facultyError[faculty] = "Не удалось загрузить новости"
                }
            } catch let caughtError {
                if facultyItems[faculty]?.isEmpty ?? true {
                    facultyError[faculty] = (caughtError as NSError).localizedDescription
                }
                print("[NEWS] Faculty \(faculty.shortTitle): \(caughtError)")
            }
            facultyIsLoading[faculty] = false
        }
    }

    // MARK: - Пагинация (секции)

    private func loadNextPage(_ section: NewsSection) async {
        isLoadingMore[section] = true
        let nextPage = defaults.integer(forKey: section.pageKey) + 1
        let blockID = defaults.string(forKey: section.blockKey) ?? "1"
        do {
            let newItems = try await fetchAjaxPage(section: section, page: nextPage, block: blockID, faculty: nil)
            appendPageItems(section: section, newItems: newItems, nextPage: nextPage, faculty: nil)
        } catch let caughtError {
            print("[NEWS] Pagination error: \((caughtError as NSError).localizedDescription)")
        }
        isLoadingMore[section] = false
    }

    // MARK: - Пагинация (факультеты)

    private func loadFacultyNextPage(_ faculty: Faculty) async {
        facultyIsLoadingMore[faculty] = true
        let nextPage = defaults.integer(forKey: faculty.pageKey) + 1
        let blockID = defaults.string(forKey: faculty.blockKey) ?? "1"
        do {
            let newItems = try await fetchAjaxPage(section: .faculties, page: nextPage, block: blockID, faculty: faculty)
            appendPageItems(section: .faculties, newItems: newItems, nextPage: nextPage, faculty: faculty)
        } catch let caughtError {
            print("[NEWS] Faculty pagination error: \((caughtError as NSError).localizedDescription)")
        }
        facultyIsLoadingMore[faculty] = false
    }

    /// Общая логика добавления страницы
    private func appendPageItems(section: NewsSection, newItems: [NewsItem], nextPage: Int, faculty: Faculty?) {
        let existing = faculty.map { facultyItems[$0] ?? [] } ?? items[section] ?? []
        guard !newItems.isEmpty else {
            if let f = faculty { facultyHasMore[f] = false } else { hasMore[section] = false }
            return
        }
        let existingIDs = Set(existing.map { $0.id })
        let unique = newItems.filter { !existingIDs.contains($0.id) }
        guard !unique.isEmpty else {
            if let f = faculty { facultyHasMore[f] = false } else { hasMore[section] = false }
            return
        }
        var updated = existing
        updated.append(contentsOf: unique)
        if let f = faculty {
            facultyItems[f] = updated
            defaults.set(nextPage, forKey: f.pageKey)
            saveToCacheFaculty(f, items: updated)
        } else {
            items[section] = updated
            defaults.set(nextPage, forKey: section.pageKey)
            saveToCache(section, items: updated)
        }
    }

    // MARK: - AJAX запрос

    private func fetchAjaxPage(section: NewsSection, page: Int, block: String, faculty: Faculty?) async throws -> [NewsItem] {
        let refererURL = faculty?.pageURL ?? section.pageURL
        var components = URLComponents(string: section.ajaxBaseURL)!
        components.queryItems = [
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "block", value: block),
            URLQueryItem(name: "bigPage", value: "true")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("https://www.fa.ru/", forHTTPHeaderField: "Referer")
        request.setValue("true", forHTTPHeaderField: "HX-Request")
        if !refererURL.isEmpty {
            request.setValue(refererURL, forHTTPHeaderField: "HX-Current-URL")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw NewsError.invalidResponse
        }
        let doc = try SwiftSoup.parse(html)
        return parseNewsCards(doc, section: section, faculty: faculty)
    }

    // MARK: - Парсинг карточек

    private func parseNewsCards(_ doc: Document, section: NewsSection, faculty: Faculty?) -> [NewsItem] {
        let articles = (try? doc.select("article.news-card")) ?? Elements()
        var result: [NewsItem] = []
        for article in articles.array() {
            let link = (try? article.select("a.news-card__link").first()?.attr("href")) ?? ""
            guard !link.isEmpty else { continue }
            // Заголовок может быть в <h2> или <h4> с классом news-card__title
            let title = ((try? article.select(".news-card__title").first()?.text()) ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            let date = extractDate(from: article)
            let tag = (try? article.select("span.ui-tag").first()?.text())
            let imageURL = extractImageURL(from: article)
            let id = link.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "-", with: "_").trimmingCharacters(in: .whitespaces)
            let processedTag = tag?.trimmingCharacters(in: .whitespaces)
            result.append(NewsItem(
                id: id, title: decodeHTMLEntities(title), date: decodeHTMLEntities(date),
                tag: processedTag.map { decodeHTMLEntities($0) },
                imageURL: imageURL, link: link,
                section: section, faculty: faculty
            ))
        }
        return result
    }

    // MARK: - Извлечение даты

    private func extractDate(from article: Element) -> String {
        let selectors = [
            "time.news-card__date",
            "span.news-card__date",
            ".news-card__date",
            "time",
            ".news-card__meta .date",
            ".news-date",
            ".date"
        ]
        for selector in selectors {
            if let el = (try? article.select(selector)).flatMap({ $0.first() }) {
                let text = ((try? el.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
                let dt = ((try? el.attr("datetime")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !dt.isEmpty { return dt }
            }
        }
        return ""
    }

    // MARK: - Извлечение URL изображения

    private func extractImageURL(from article: Element) -> String? {
        let imgSelectors = [".news-card__img img", ".news-card__image img", ".news-card picture img", "article.news-card img"]
        for selector in imgSelectors {
            guard let img = (try? article.select(selector)).flatMap({ $0.first() }) else { continue }
            for attr in ["src", "data-src", "data-lazy-src", "data-original"] {
                let val = (try? img.attr(attr)) ?? ""
                let trimmed = val.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
            }
            if let source = (try? article.select("picture source")).flatMap({ $0.first() }) {
                let srcset = (try? source.attr("srcset")) ?? ""
                let firstURL = srcset.split(separator: ",").first?.split(separator: " ").first.map(String.init) ?? ""
                if !firstURL.isEmpty { return firstURL }
            }
        }
        if let container = (try? article.select(".news-card__img")).flatMap({ $0.first() }) {
            let style = (try? container.attr("style")) ?? ""
            if let range = style.range(of: "url(") {
                var urlStr = String(style[range.upperBound...])
                if let endIdx = urlStr.firstIndex(of: ")") {
                    urlStr = String(urlStr[..<endIdx]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    if !urlStr.isEmpty { return urlStr }
                }
            }
        }
        return nil
    }

    // MARK: - Парсинг полной статьи
    // Структура fa.ru:
    //   h1.app-head__title — заголовок
    //   span.article-head__date — дата
    //   section.app-section._is-slim._gutter-md .app-section__content .text-content — тело
    //   Изображения могут быть внутри <p> (inline) или отдельными <img>

    private func parseArticle(_ doc: Document, item: NewsItem) -> NewsArticle {
        // Заголовок: приоритет h1.app-head__title, потом любой h1
        let title: String = {
            if let t = (try? doc.select("h1.app-head__title").first()?.text())?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return t
            }
            if let t = (try? doc.select("h1").first()?.text())?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return t
            }
            return item.title
        }()

        // Дата: приоритет span.article-head__date
        let date: String = {
            let dateSelectors = [
                "span.article-head__date",
                ".article-head__date",
                ".news-detail__date",
                ".news-date",
                ".detail__date",
                "time",
                ".date"
            ]
            for sel in dateSelectors {
                if let el = (try? doc.select(sel)).flatMap({ $0.first() }) {
                    let text = ((try? el.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { return text }
                    let dt = ((try? el.attr("datetime")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !dt.isEmpty { return dt }
                }
            }
            return item.displayDate
        }()

        // Главное изображение: ищем ТОЛЬКО в теле статьи
        let heroImageURL: String? = {
            let heroSelectors = [
                "section.app-section._is-slim .app-section__content .text-content img",
                "section.app-section._is-slim .app-section__content img",
                "section.app-section._is-slim .text-content img"
            ]
            for sel in heroSelectors {
                if let img = (try? doc.select(sel)).flatMap({ $0.first() }) {
                    let src = resolveImageURL((try? img.attr("src")) ?? "") ?? resolveImageURL((try? img.attr("data-src")) ?? "")
                    if src != nil { return src }
                }
            }
            return item.fullImageURL
        }()

        // Тело статьи: приоритет .text-content внутри app-section
        let contentSelectors = [
            "section.app-section._is-slim .app-section__content .text-content",
            "section.app-section .app-section__content .text-content",
            ".app-section__content .text-content",
            ".text-content",
            ".news-detail__text",
            ".detail__text",
            ".news-detail__body",
            ".news-content",
            ".article-content",
            ".detail-text"
        ]
        var contentElement: Element?
        for selector in contentSelectors {
            if let el = (try? doc.select(selector)).flatMap({ $0.first() }) {
                contentElement = el
                break
            }
        }
        let blocks = contentElement.map { parseContentBlocks($0) } ?? []
        return NewsArticle(id: item.id, title: title,
            date: date, imageURL: heroImageURL,
            blocks: blocks, sourceURL: item.fullLinkURL)
    }

    // MARK: - Блоки контента

    private func parseContentBlocks(_ element: Element) -> [ArticleBlock] {
        var blocks: [ArticleBlock] = []
        let children = element.children().array()
        for child in children {
            let tagName = child.tagName()
            switch tagName {
            case "p":
                // Сначала извлекаем изображения (могут быть inline внутри <p>)
                let imgs = ((try? child.select("img")) ?? Elements()).array()
                for img in imgs {
                    if let src = resolveImageURL((try? img.attr("src")) ?? "") ?? resolveImageURL((try? img.attr("data-src")) ?? "") {
                        blocks.append(.image(src))
                    }
                }
                // Парсим сегменты текста со ссылками
                let segments = parseTextSegments(from: child)
                if !segments.isEmpty {
                    let splitSegments = splitSegmentsByDoubleNewline(segments)
                    for subSegments in splitSegments {
                        if !subSegments.isEmpty {
                            let hasLinks = subSegments.contains { $0.linkURL != nil }
                            if hasLinks {
                                // Декодируем HTML-сущности в каждом сегменте
                                let decodedSegments = subSegments.map { seg in
                                    TextSegment(text: decodeHTMLEntities(seg.text), linkURL: seg.linkURL)
                                }
                                blocks.append(.richParagraph(decodedSegments))
                            } else {
                                let combinedText = subSegments.map { $0.text }.joined()
                                let trimmed = combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    blocks.append(.paragraph(decodeHTMLEntities(trimmed)))
                                }
                            }
                        }
                    }
                }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let text = ((try? child.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { break }
                let level = Int(tagName.filter { $0.isNumber }) ?? 2
                blocks.append(.heading(decodeHTMLEntities(text), level: level))
            case "img":
                if let src = resolveImageURL((try? child.attr("src")) ?? "") ?? resolveImageURL((try? child.attr("data-src")) ?? "") {
                    blocks.append(.image(src))
                }
            case "ul":
                let li = parseListItems(child)
                if !li.isEmpty { blocks.append(.list(li, ordered: false)) }
            case "ol":
                let li = parseListItems(child)
                if !li.isEmpty { blocks.append(.list(li, ordered: true)) }
            case "blockquote":
                let text = ((try? child.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { blocks.append(.quote(decodeHTMLEntities(text))) }
            case "hr":
                blocks.append(.divider)
            case "figure":
                if let img = (try? child.select("img")).flatMap({ $0.first() }),
                   let src = resolveImageURL((try? img.attr("src")) ?? "") ?? resolveImageURL((try? img.attr("data-src")) ?? "") {
                    blocks.append(.image(src))
                }
                let capText = (try? child.select("figcaption").first()?.text()) ?? ""
                let t = capText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { blocks.append(.paragraph(t)) }
            case "div":
                let isGal = child.hasClass("gallery") || child.hasClass("slider") ||
                            child.hasClass("news-detail__gallery") || child.hasClass("photogallery")
                if isGal {
                    // Галерея — собираем все изображения в один блок
                    let imgs = ((try? child.select("img")) ?? Elements()).array()
                    var galleryURLs: [String] = []
                    for img in imgs {
                        if let src = resolveImageURL((try? img.attr("src")) ?? "") ?? resolveImageURL((try? img.attr("data-src")) ?? "") {
                            galleryURLs.append(src)
                        }
                    }
                    if !galleryURLs.isEmpty {
                        // Если 1 фото — обычный image, если 2+ — gallery
                        if galleryURLs.count == 1 {
                            blocks.append(.image(galleryURLs[0]))
                        } else {
                            blocks.append(.gallery(galleryURLs))
                        }
                    }
                } else if let img = (try? child.select("img")).flatMap({ $0.first() }),
                          let src = resolveImageURL((try? img.attr("src")) ?? "") ?? resolveImageURL((try? img.attr("data-src")) ?? "") {
                    blocks.append(.image(src))
                } else {
                    let text = ((try? child.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { blocks.append(.paragraph(text)) }
                }
            default:
                if tagName != "script" && tagName != "style" && tagName != "nav" {
                    let text = ((try? child.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { blocks.append(.paragraph(text)) }
                }
            }
        }
        return blocks
    }

    private func parseListItems(_ el: Element) -> [String] {
        let items = ((try? el.select("li")) ?? Elements()).array()
        return items.compactMap { (try? $0.text())?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { decodeHTMLEntities($0) }
    }

    // MARK: - Парсинг сегментов текста со ссылками
    // childNodes недоступен (internal в SwiftSoup), поэтому парсим HTML-строку

    private func parseTextSegments(from element: Element) -> [TextSegment] {
        let links = (try? element.select("a")) ?? Elements()

        // Нет ссылок — возвращаем просто текст
        if links.isEmpty() {
            let text = ((try? element.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return [TextSegment(text: text, linkURL: nil)]
            }
            return []
        }

        // Есть ссылки — парсим HTML для сохранения порядка текст/ссылка
        var html = ""
        do { html = try element.html() } catch { return [] }

        // Нормализуем <br> в \n
        html = html.replacingOccurrences(of: "<br>", with: "\n")
                   .replacingOccurrences(of: "<br/>", with: "\n")
                   .replacingOccurrences(of: "<br />", with: "\n")

        var segments: [TextSegment] = []
        var currentText = ""
        var i = html.startIndex

        while i < html.endIndex {
            if html[i] == "<" {
                guard let closeIdx = html[i...].firstIndex(of: ">") else { break }
                let tagContent = String(html[html.index(after: i)..<closeIdx])

                if tagContent.lowercased().hasPrefix("a ") || tagContent == "a" {
                    // Flush text before link — сохраняем пробелы в конце
                    if !currentText.isEmpty {
                        // Не обрезаем пробелы — они важны для разделения текста и ссылки
                        let trimmed = currentText.trimmingCharacters(in: .newlines)
                        if !trimmed.trimmingCharacters(in: .whitespaces).isEmpty {
                            segments.append(TextSegment(text: trimmed, linkURL: nil))
                        }
                        currentText = ""
                    }

                    // Extract href
                    var href = ""
                    if let r = tagContent.range(of: "href=\"") {
                        let s = r.upperBound
                        if let e = tagContent[s...].firstIndex(of: "\"") {
                            href = String(tagContent[s..<e])
                        }
                    } else if let r = tagContent.range(of: "href='") {
                        let s = r.upperBound
                        if let e = tagContent[s...].firstIndex(of: "'") {
                            href = String(tagContent[s..<e])
                        }
                    }

                    // Find </a>
                    let afterTag = html.index(after: closeIdx)
                    if let closeA = html[afterTag...].range(of: "</a>", options: .caseInsensitive) {
                        let rawLinkText = String(html[afterTag..<closeA.lowerBound])
                        let linkText = stripHTMLTags(from: rawLinkText).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !linkText.isEmpty {
                            let resolved = href.isEmpty ? nil : resolveLinkURL(href)
                            // Добавляем пробел до и после ссылки, если его нет
                            if let lastSeg = segments.last, !lastSeg.text.hasSuffix(" ") && !lastSeg.text.isEmpty {
                                segments[segments.count - 1] = TextSegment(text: lastSeg.text + " ", linkURL: lastSeg.linkURL)
                            }
                            segments.append(TextSegment(text: linkText, linkURL: resolved))
                            // Помечаем, что после ссылки нужен пробел
                            currentText = " "
                        }
                        i = closeA.upperBound
                        continue
                    }
                }
                // Для других тегов (b, i, strong, span) — просто пропускаем тег, текст остаётся
                i = html.index(after: closeIdx)
            } else {
                currentText.append(html[i])
                i = html.index(after: i)
            }
        }

        // Flush remaining text
        if !currentText.isEmpty {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(TextSegment(text: trimmed, linkURL: nil))
            }
        }

        return segments
    }

    /// Удаляет HTML-теги из строки, оставляя только текст
    private func stripHTMLTags(from html: String) -> String {
        var result = ""
        var insideTag = false
        for ch in html {
            if ch == "<" { insideTag = true }
            else if ch == ">" { insideTag = false }
            else if !insideTag { result.append(ch) }
        }
        return result
    }

    /// Разбивает сегменты по двойному переводу строки (\n\n от <br><br>)
    private func splitSegmentsByDoubleNewline(_ segments: [TextSegment]) -> [[TextSegment]] {
        var result: [[TextSegment]] = []
        var current: [TextSegment] = []

        for seg in segments {
            if seg.text == "\n" {
                // Проверяем, есть ли уже \n в конце current
                if current.last?.text == "\n" {
                    // Двойной \n — разбиваем
                    current.removeLast() // убираем первый \n
                    if !current.isEmpty {
                        result.append(current)
                        current = []
                    }
                } else {
                    current.append(seg)
                }
            } else {
                current.append(seg)
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private func resolveLinkURL(_ href: String) -> String? {
        let t = href.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("http") { return t }
        if t.hasPrefix("//") { return "https:\(t)" }
        if t.hasPrefix("/") { return "https://www.fa.ru\(t)" }
        if t.hasPrefix("mailto:") || t.hasPrefix("tel:") { return t }
        return "https://www.fa.ru/\(t)"
    }

    private func resolveImageURL(_ src: String) -> String? {
        let t = src.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("http") { return t }
        if t.hasPrefix("//") { return "https:\(t)" }
        if t.hasPrefix("/") { return "https://www.fa.ru\(t)" }
        return "https://www.fa.ru/\(t)"
    }

    // MARK: - Декодирование HTML-сущностей (&nbsp;, &amp;, &laquo; и т.д.)

    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        // &nbsp; → неразрывный пробел
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&#160;", with: " ")
        // Кавычки
        result = result.replacingOccurrences(of: "&laquo;", with: "«")
        result = result.replacingOccurrences(of: "&raquo;", with: "»")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#8222;", with: "„")
        result = result.replacingOccurrences(of: "&#8220;", with: "“")
        // Амперсанд
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        // Тире
        result = result.replacingOccurrences(of: "&mdash;", with: "—")
        result = result.replacingOccurrences(of: "&ndash;", with: "–")
        result = result.replacingOccurrences(of: "&#8212;", with: "—")
        result = result.replacingOccurrences(of: "&#8211;", with: "–")
        // Апострофы
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&rsquo;", with: "'")
        result = result.replacingOccurrences(of: "&lsquo;", with: "‘")
        // Прочие
        result = result.replacingOccurrences(of: "&hellip;", with: "…")
        result = result.replacingOccurrences(of: "&copy;", with: "©")
        result = result.replacingOccurrences(of: "&reg;", with: "®")
        result = result.replacingOccurrences(of: "&trade;", with: "™")
        result = result.replacingOccurrences(of: "&deg;", with: "°")
        result = result.replacingOccurrences(of: "&sect;", with: "§")
        result = result.replacingOccurrences(of: "&para;", with: "¶")
        result = result.replacingOccurrences(of: "&middot;", with: "·")
        result = result.replacingOccurrences(of: "&bull;", with: "•")
        result = result.replacingOccurrences(of: "&dagger;", with: "†")
        result = result.replacingOccurrences(of: "&Dagger;", with: "‡")
        result = result.replacingOccurrences(of: "&permil;", with: "‰")
        result = result.replacingOccurrences(of: "&prime;", with: "′")
        result = result.replacingOccurrences(of: "&Prime;", with: "″")
        result = result.replacingOccurrences(of: "&lsaquo;", with: "‹")
        result = result.replacingOccurrences(of: "&rsaquo;", with: "›")
        result = result.replacingOccurrences(of: "&times;", with: "×")
        result = result.replacingOccurrences(of: "&divide;", with: "÷")
        result = result.replacingOccurrences(of: "&minus;", with: "−")
        result = result.replacingOccurrences(of: "&plus;", with: "+")
        result = result.replacingOccurrences(of: "&asymp;", with: "≈")
        result = result.replacingOccurrences(of: "&ne;", with: "≠")
        result = result.replacingOccurrences(of: "&le;", with: "≤")
        result = result.replacingOccurrences(of: "&ge;", with: "≥")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        return result
    }

    private func extractBlockID(_ doc: Document) -> String? {
        guard let btn = (try? doc.select("[data-hx-get]")).flatMap({ $0.first() }) else { return nil }
        let hxGet = (try? btn.attr("data-hx-get")) ?? ""
        guard let url = URLComponents(string: hxGet),
              let blockItem = url.queryItems?.first(where: { $0.name == "block" }) else { return nil }
        return blockItem.value
    }

    // MARK: - Кеширование (секции)

    private func saveToCache(_ section: NewsSection, items: [NewsItem]) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: cacheDir.appendingPathComponent("\(section.cacheKey).json"))
        }
    }

    private func loadCached(_ section: NewsSection) {
        let url = cacheDir.appendingPathComponent("\(section.cacheKey).json")
        guard let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode([NewsItem].self, from: data),
              !cached.isEmpty else { return }
        items[section] = cached
        hasMore[section] = true
    }

    // MARK: - Кеширование (факультеты)

    private func saveToCacheFaculty(_ faculty: Faculty, items: [NewsItem]) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: cacheDir.appendingPathComponent("\(faculty.cacheKey).json"))
        }
    }

    private func loadCachedFaculty(_ faculty: Faculty) {
        let url = cacheDir.appendingPathComponent("\(faculty.cacheKey).json")
        guard let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode([NewsItem].self, from: data),
              !cached.isEmpty else { return }
        facultyItems[faculty] = cached
        facultyHasMore[faculty] = true
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDir)
        articleCache.removeAll()
        for section in NewsSection.allCases {
            items[section] = []
            defaults.removeObject(forKey: section.pageKey)
            defaults.removeObject(forKey: section.blockKey)
        }
        for fac in Faculty.allCases {
            facultyItems[fac] = []
            defaults.removeObject(forKey: fac.pageKey)
            defaults.removeObject(forKey: fac.blockKey)
        }
    }

    enum NewsError: LocalizedError {
        case invalidResponse
        var errorDescription: String? { "Некорректный ответ сервера" }
    }
}   
