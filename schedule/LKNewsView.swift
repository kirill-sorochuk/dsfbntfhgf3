import SwiftUI

// ======================================================================
// LKNewsView.swift — Новости с прозрачной шапкой (Telegram-style)
// Изменения:
// 1. Меню секций — safeAreaInset (фиксированная панель, контент не перекрывает)
// 2. Убраны фильтры по тегам
// 3. Умная плитка — маленькие новости всегда по 2 в ряду
// 4. Новости без фото — корректно отображаются
// 5. Заголовок «Новости» — inline, по центру
// 6. Кнопка настроек — слева в навбаре
// 7. Панель — без подложки, только капсулы
// ======================================================================

// MARK: - Блоки раскладки для умной плитки

private enum RenderSection {
    case hero(NewsItem)
    case wide(NewsItem, isLeft: Bool)
    case compactPair(NewsItem, NewsItem)
}

// MARK: - Стеклянный фон для капсул меню новостей
struct NewsCapsuleBackground: View {
    let isSelected: Bool

    var body: some View {
        if isSelected {
            Capsule().fill(Color.accentColor)
        } else {
            #if os(iOS)
            if #available(iOS 26.0, *) {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .glassEffect(.regular, in: Capsule())
            } else {
                Capsule().fill(Color(.tertiarySystemFill))
            }
            #else
            Capsule().fill(Color(.tertiarySystemFill))
            #endif
        }
    }
}

// MARK: - Стиль листа деталей новости (iPad — фикс. высота)

struct NewsDetailSheetStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            content
                .presentationDetents([.height(620)])
                .presentationDragIndicator(.hidden)
        } else {
            content
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #else
        content
        #endif
    }
}

// MARK: - Главный экран

struct LKNewsView: View {
    @StateObject private var manager = NewsManager.shared
    @EnvironmentObject private var scheduleVM: ScheduleViewModel
    @AppStorage("newsDisplayFormat") private var displayFormat: NewsDisplayFormat = .list
    @AppStorage("detailPresentation") private var detailPresentation = "sheet"
    @State private var selectedArticle: NewsItem? = nil
    @State private var showFacultyHint = false
    @State private var hintOpacity: Double = 0
    @State private var pinnedSectionsTrigger: Int = 0  // Триггер обновления при закреплении

    private var isFacultiesMode: Bool { manager.selectedSection == .faculties }

    private var effectiveStyle: String {
        #if os(iOS)
        return detailPresentation
        #else
        return detailPresentation == "sheet" ? "sheet" : "centered"
        #endif
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Меню секций (фиксированно сверху)
            sectionMenu

            // Меню факультетов (если активен режим факультетов)
            if isFacultiesMode {
                facultyBar
            }

            // Контент новостей (занимает оставшееся место)
            newsContent
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Новости")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    SettingsView(viewModel: scheduleVM)
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                newsToolbarMenu
            }
        }
        .onAppear {
            manager.loadIfNeeded(manager.selectedSection)
            showFacultyHintIfNeeded()
        }
        .onChange(of: manager.selectedSection) { _, newValue in
            if newValue == .faculties {
                showFacultyHintIfNeeded()
            }
        }
        .refreshable {
            await Task { manager.refresh(manager.selectedSection) }.value
        }
        // Детали новости: sheet
        .sheet(item: effectiveStyle == "sheet" ? $selectedArticle : .constant(nil)) { item in
            NavigationStack {
                NewsDetailView(item: item, transparentBackground: false)
            }
            .modifier(NewsDetailSheetStyle())
            .presentationBackground(Palette.background)
        }
        // Детали новости: fullscreen
        #if os(iOS)
        .fullScreenCover(item: effectiveStyle == "fullscreen" ? $selectedArticle : .constant(nil)) { item in
            NavigationStack {
                NewsDetailView(item: item, transparentBackground: false)
            }
        }
        #endif
        // Детали новости: centered
        .overlay {
            if effectiveStyle == "centered", let item = selectedArticle {
                ZStack {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                selectedArticle = nil
                            }
                        }
                    NavigationStack {
                        NewsDetailView(item: item, transparentBackground: true)
                    }
                    .frame(maxWidth: 560, maxHeight: 640)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 30, y: 12)
                    .padding(24)
                }
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: selectedArticle?.id)
    }

    // MARK: - Меню секций (прозрачный фон, с возможностью закрепления)

    /// Порядок секций (закреплённые первыми)
    private var orderedSections: [NewsSection] {
        var sections = NewsSection.allCases
        // Закреплённые — первыми
        let pinnedRaw = UserDefaults.standard.stringArray(forKey: "news_pinned_sections") ?? []
        let pinned = sections.filter { pinnedRaw.contains($0.rawValue) }
        let unpinned = sections.filter { !pinnedRaw.contains($0.rawValue) }
        return pinned + unpinned
    }

    private func togglePin(_ section: NewsSection) {
        var pinned = UserDefaults.standard.stringArray(forKey: "news_pinned_sections") ?? []
        if pinned.contains(section.rawValue) {
            pinned.removeAll { $0 == section.rawValue }
        } else {
            pinned.append(section.rawValue)
        }
        UserDefaults.standard.set(pinned, forKey: "news_pinned_sections")
        // Триггер обновления UI
        pinnedSectionsTrigger += 1
    }

    private func isPinned(_ section: NewsSection) -> Bool {
        let pinned = UserDefaults.standard.stringArray(forKey: "news_pinned_sections") ?? []
        return pinned.contains(section.rawValue)
    }

    private var sectionMenu: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(orderedSections) { section in
                    let isSelected = manager.selectedSection == section
                    let pinned = isPinned(section)
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            manager.selectedSection = section
                        }
                        manager.loadIfNeeded(section)
                    } label: {
                        HStack(spacing: 6) {
                            if pinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(isSelected ? .white : .accentColor)
                            }
                            Image(systemName: section.icon)
                                .font(.system(size: 13, weight: .medium))
                            Text(section.title)
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            NewsCapsuleBackground(isSelected: isSelected)
                        )
                        .foregroundColor(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                togglePin(section)
                            }
                        } label: {
                            Label(
                                pinned ? "Открепить" : "Закрепить",
                                systemImage: pinned ? "pin.slash" : "pin"
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Меню тулбара (только формат)

    private var newsToolbarMenu: some View {
        Menu {
            Section("Формат") {
                ForEach(NewsDisplayFormat.allCases, id: \.rawValue) { format in
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { displayFormat = format }
                    } label: {
                        if format == displayFormat {
                            Label(format.label, systemImage: format.icon)
                            Image(systemName: "checkmark")
                        } else {
                            Label(format.label, systemImage: format.icon)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.accentColor)
        }
    }

    // MARK: - Подсказка факультетов

    private func showFacultyHintIfNeeded() {
        guard manager.showFacultyHint, isFacultiesMode else { return }
        withAnimation(.easeIn(duration: 0.3).delay(0.5)) {
            showFacultyHint = true
            hintOpacity = 1
        }
        withAnimation(.easeOut(duration: 0.4).delay(4.0)) {
            hintOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            showFacultyHint = false
            manager.showFacultyHint = false
        }
    }

    // MARK: - Тулбар факультетов

    private var facultyBar: some View {
        ZStack(alignment: .top) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(manager.sortedFaculties) { faculty in
                        let isPinned = manager.pinnedFaculty == faculty
                        let isSelected = manager.selectedFaculty == faculty
                        Button {
                            manager.selectFaculty(faculty)
                        } label: {
                            HStack(spacing: 5) {
                                if isPinned {
                                    Image(systemName: "pin.fill")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(isSelected ? .white : .accentColor)
                                }
                                Text(faculty.shortTitle)
                                    .font(.subheadline.weight(.medium))
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                NewsCapsuleBackground(isSelected: isSelected)
                            )
                            .foregroundColor(isSelected ? .white : .primary)
                            .overlay(
                                Capsule()
                                    .stroke(
                                        isSelected ? Color.clear :
                                            (isPinned ? Color.accentColor.opacity(0.5) : Color.clear),
                                        lineWidth: isPinned && !isSelected ? 1.5 : 0
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    manager.togglePinFaculty(faculty)
                                }
                            }
                        )
                        .contextMenu {
                            Button {
                                withAnimation { manager.togglePinFaculty(faculty) }
                            } label: {
                                Label(
                                    isPinned ? "Открепить" : "Закрепить",
                                    systemImage: isPinned ? "pin.slash" : "pin"
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
            }

            if showFacultyHint {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap").font(.system(size: 13))
                    Text("Двойной тап или удержание для закрепления")
                        .font(.caption2.weight(.medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.darkGray).opacity(0.85), in: Capsule())
                .padding(.bottom, 6)
                .opacity(hintOpacity)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Контент

    @ViewBuilder
    private var newsContent: some View {
        if isFacultiesMode {
            facultyContent
        } else {
            sectionContent
        }
    }

    // MARK: - Контент секций

    @ViewBuilder
    private var sectionContent: some View {
        let section = manager.selectedSection
        let newsItems = manager.items[section] ?? []
        let loading = manager.isLoading[section] ?? false
        let loadingMore = manager.isLoadingMore[section] ?? false
        let errMsg = manager.error[section]
        let canLoadMore = manager.hasMore[section] ?? true

        if loading && newsItems.isEmpty {
            fullScreenLoading
        } else if newsItems.isEmpty, let errStr = errMsg, let msg = errStr, !msg.isEmpty {
            errorView(msg)
        } else if newsItems.isEmpty {
            emptyView
        } else if displayFormat == .list {
            newsList(items: newsItems, loadingMore: loadingMore, canLoadMore: canLoadMore, section: section, faculty: nil)
        } else if displayFormat == .big {
            bigNews(items: newsItems, loadingMore: loadingMore, canLoadMore: canLoadMore, section: section, faculty: nil)
        } else {
            smartGrid(items: newsItems, loadingMore: loadingMore, canLoadMore: canLoadMore, section: section, faculty: nil)
        }
    }

    // MARK: - Контент факультетов

    @ViewBuilder
    private var facultyContent: some View {
        if let faculty = manager.selectedFaculty {
            let newsItems = manager.facultyItems[faculty] ?? []
            let loading = manager.facultyIsLoading[faculty] ?? false
            let loadingMore = manager.facultyIsLoadingMore[faculty] ?? false
            let errMsg = manager.facultyError[faculty]
            let canLoadMore = manager.facultyHasMore[faculty] ?? true

            if loading && newsItems.isEmpty {
                fullScreenLoading
            } else if newsItems.isEmpty, let errStr = errMsg, let msg = errStr, !msg.isEmpty {
                errorView(msg)
            } else if newsItems.isEmpty {
                emptyView
            } else if displayFormat == .list {
                newsList(items: newsItems, loadingMore: loadingMore, canLoadMore: canLoadMore, section: .faculties, faculty: faculty)
            } else if displayFormat == .big {
                bigNews(items: newsItems, loadingMore: loadingMore, canLoadMore: canLoadMore, section: .faculties, faculty: faculty)
            } else {
                smartGrid(items: newsItems, loadingMore: loadingMore, canLoadMore: canLoadMore, section: .faculties, faculty: faculty)
            }
        } else {
            VStack(spacing: 16) {
                Spacer()
                Image("MascotDirection")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 110)
                    .accessibilityHidden(true)
                Text("Выберите факультет")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - Состояния

    private var fullScreenLoading: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Загрузка новостей...").font(.subheadline).foregroundColor(.secondary)
            Spacer()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "wifi.exclamationmark").font(.system(size: 48)).foregroundColor(.secondary.opacity(0.5))
            Text(message).font(.subheadline).foregroundColor(.secondary)
            Button("Повторить") { manager.refresh(manager.selectedSection) }
                .font(.subheadline.bold()).foregroundColor(.accentColor)
            Spacer()
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image("MascotBook")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 100)
                .accessibilityHidden(true)
            Text("Новостей пока нет").font(.title3.bold()).foregroundColor(.secondary)
            Spacer()
        }
    }

    // MARK: - Режим «Список»

    private func newsList(items: [NewsItem], loadingMore: Bool, canLoadMore: Bool, section: NewsSection, faculty: Faculty?) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(items) { item in
                    Button { selectedArticle = item } label: { NewsRowView(item: item) }
                        .buttonStyle(.plain)
                }
                if canLoadMore {
                    bottomLoader(loadingMore: loadingMore) {
                        if let f = faculty { manager.loadMoreFaculty(f) }
                        else { manager.loadMore(section) }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Режим «Крупные»

    private func bigNews(items: [NewsItem], loadingMore: Bool, canLoadMore: Bool, section: NewsSection, faculty: Faculty?) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(items) { item in
                    Button { selectedArticle = item } label: { HeroNewsCard(item: item) }
                        .buttonStyle(.plain)
                }
                if canLoadMore {
                    bottomLoader(loadingMore: loadingMore) {
                        if let f = faculty { manager.loadMoreFaculty(f) }
                        else { manager.loadMore(section) }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Режим «Умная плитка»

    private func smartGrid(items: [NewsItem], loadingMore: Bool, canLoadMore: Bool, section: NewsSection, faculty: Faculty?) -> some View {
        let sections = buildRenderSections(from: items)

        return ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<sections.count, id: \.self) { index in
                    renderSection(sections[index])
                }
                if canLoadMore {
                    bottomLoader(loadingMore: loadingMore) {
                        if let f = faculty { manager.loadMoreFaculty(f) }
                        else { manager.loadMore(section) }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func renderSection(_ section: RenderSection) -> some View {
        switch section {
        case .hero(let item):
            Button { selectedArticle = item } label: { HeroNewsCard(item: item) }
                .buttonStyle(.plain)

        case .wide(let item, let isLeft):
            Button { selectedArticle = item } label: { SideImageTile(item: item, isLeft: isLeft) }
                .buttonStyle(.plain)

        case .compactPair(let first, let second):
            HStack(spacing: 12) {
                Button { selectedArticle = first } label: { CompactTile(item: first) }
                    .buttonStyle(.plain)
                Button { selectedArticle = second } label: { CompactTile(item: second) }
                    .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Построитель раскладки

    private func buildRenderSections(from items: [NewsItem]) -> [RenderSection] {
        var sections: [RenderSection] = []
        var compactBuffer: [NewsItem] = []
        var wideIsLeft = true

        func flushCompact() {
            guard !compactBuffer.isEmpty else { return }
            if compactBuffer.count % 2 == 1 {
                let orphan = compactBuffer.removeLast()
                sections.append(.wide(orphan, isLeft: wideIsLeft))
                wideIsLeft.toggle()
            }
            var idx = 0
            while idx < compactBuffer.count {
                sections.append(.compactPair(compactBuffer[idx], compactBuffer[idx + 1]))
                idx += 2
            }
            compactBuffer.removeAll()
        }

        for (i, item) in items.enumerated() {
            let cyclePos = i % 7

            if cyclePos == 0 {
                flushCompact()
                sections.append(.hero(item))
                continue
            }

            if item.hasImage && (cyclePos == 1 || cyclePos == 2 || cyclePos == 5) {
                flushCompact()
                sections.append(.wide(item, isLeft: wideIsLeft))
                wideIsLeft.toggle()
                continue
            }

            compactBuffer.append(item)
        }
        flushCompact()

        return sections
    }

    // MARK: - Загрузка ещё

    @ViewBuilder
    private func bottomLoader(loadingMore: Bool, action: @escaping () -> Void) -> some View {
        if loadingMore {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Загрузка...").font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20)
            .onAppear { action() }
        } else {
            Button { action() } label: {
                Text("Показать ещё").font(.subheadline.weight(.medium)).foregroundColor(.accentColor)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }
}

// ======================================================================
// Hero-карточка
// ======================================================================

private struct HeroNewsCard: View {
    let item: NewsItem

    var body: some View {
        VStack(spacing: 0) {
            if item.hasImage {
                heroImage
                    .frame(height: 200)
                    .clipped()
            } else {
                heroTextHeader
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.title3.bold())
                    .foregroundColor(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 8) {
                    if !item.displayDate.isEmpty {
                        Text(item.displayDate)
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
                    Spacer()
                }
            }
            .padding(14)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var heroImage: some View {
        if let urlString = item.fullImageURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    heroPlaceholder
                default:
                    heroPlaceholder
                        .overlay(ProgressView())
                }
            }
        } else {
            heroPlaceholder
        }
    }

    private var heroTextHeader: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.2), Color.accentColor.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "doc.text.fill")
                .font(.system(size: 40))
                .foregroundColor(.accentColor.opacity(0.3))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 80)
    }

    private var heroPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.12), Color.accentColor.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "newspaper.fill")
                .font(.system(size: 40))
                .foregroundColor(.accentColor.opacity(0.2))
        }
    }
}

// ======================================================================
// Широкая карточка
// ======================================================================

private struct SideImageTile: View {
    let item: NewsItem
    let isLeft: Bool

    var body: some View {
        if item.hasImage {
            HStack(spacing: 0) {
                if isLeft {
                    imageSide
                    textSide
                } else {
                    textSide
                    imageSide
                }
            }
            .frame(height: 130)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        } else {
            textSide
                .frame(height: 130)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private var imageSide: some View {
        if let urlString = item.fullImageURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    Color(.tertiarySystemGroupedBackground)
                        .overlay(Image(systemName: "photo").font(.system(size: 24)).foregroundColor(.secondary.opacity(0.25)))
                default:
                    Color(.secondarySystemGroupedBackground).overlay(ProgressView())
                }
            }
            .frame(width: 140, height: 130)
            .clipped()
        } else {
            Color(.tertiarySystemGroupedBackground)
                .frame(width: 140, height: 130)
                .overlay(
                    Image(systemName: "newspaper.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.accentColor.opacity(0.2))
                )
        }
    }

    private var textSide: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.primary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if !item.displayDate.isEmpty {
                    Text(item.displayDate)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let tag = item.displayTag {
                    Text(tag)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// ======================================================================
// Компактная плитка
// ======================================================================

private struct CompactTile: View {
    let item: NewsItem

    var body: some View {
        VStack(spacing: 0) {
            if item.hasImage {
                compactImage
                    .frame(height: 80)
                    .clipped()
            } else {
                compactPlaceholder
                    .frame(height: 56)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.caption.weight(.bold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !item.displayDate.isEmpty {
                    Text(item.displayDate)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let tag = item.displayTag {
                    Text(tag)
                        .font(.system(size: 10).weight(.medium))
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(10)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var compactImage: some View {
        if let urlString = item.fullImageURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    Color(.tertiarySystemGroupedBackground)
                default:
                    Color(.secondarySystemGroupedBackground).overlay(ProgressView())
                }
            }
        } else {
            Color(.tertiarySystemGroupedBackground)
        }
    }

    private var compactPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.12), Color.accentColor.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "doc.text.fill")
                .font(.system(size: 20))
                .foregroundColor(.accentColor.opacity(0.3))
        }
    }
}

// ======================================================================
// Строка списка
// ======================================================================

struct NewsRowView: View {
    let item: NewsItem
    private let imgSize: CGFloat = 72

    private var imageURL: URL? {
        item.fullImageURL.flatMap { URL(string: $0) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                if item.hasImage {
                    Color(.tertiarySystemGroupedBackground)
                } else {
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.12), Color.accentColor.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                if let url = imageURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: imgSize, height: imgSize)
                                .clipped()
                        case .failure:
                            Image(systemName: "newspaper.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.secondary.opacity(0.2))
                        default:
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                } else {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.accentColor.opacity(0.3))
                }
            }
            .frame(width: imgSize, height: imgSize)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if !item.displayDate.isEmpty {
                        Text(item.displayDate)
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
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// ======================================================================
// Хелпер
// ======================================================================

private extension NewsItem {
    var hasImage: Bool { fullImageURL != nil }
}
