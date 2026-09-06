import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Русские склонения
extension Int {
    func pluralForm(one: String, few: String, many: String) -> String {
        let n = abs(self) % 100, n1 = abs(self) % 10
        if n >= 11 && n <= 14 { return many }
        if n1 == 1 { return one }
        if n1 >= 2 && n1 <= 4 { return few }
        return many
    }
}

// MARK: - Внешний вид (Liquid Glass — мгновенное применение)
final class Appearance: ObservableObject {
    @Published var liquidGlass: Bool {
        didSet { UserDefaults.standard.set(liquidGlass, forKey: "liquidGlass") }
    }
    init() {
        liquidGlass = UserDefaults.standard.object(forKey: "liquidGlass") as? Bool ?? true
    }
}

// MARK: - Палитра
enum Palette {
    static var background: Color {
        #if canImport(UIKit)
        // В светлой теме — #F3F3F3, в тёмной — системный
        return Color(UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor.systemGroupedBackground
            }
            return UIColor(red: 0xF3/255, green: 0xF3/255, blue: 0xF3/255, alpha: 1)
        })
        #else
        return Color(NSColor.windowBackgroundColor)
        #endif
    }
    static var card: Color {
        #if canImport(UIKit)
        return Color(UIColor.secondarySystemGroupedBackground)
        #else
        return Color(NSColor.controlBackgroundColor)
        #endif
    }
}

extension Color {
    // Светлый фон панели календаря (не зависит от темы приложения)
    static let panelLight: Color = {
        #if canImport(UIKit)
        return Color(UIColor.systemBackground)
        #else
        return Color(NSColor.windowBackgroundColor)
        #endif
    }()
}

enum AccentColors {
    // Основная палитра (приоритетные цвета университета)
    static let main: [(name: String, color: Color)] = [
        ("faTeal", Color(red: 0x01/255, green: 0x98/255, blue: 0xAF/255)),   // #0198AF
        ("faBlue", Color(red: 0x23/255, green: 0x3E/255, blue: 0x76/255)),   // #233E76
        ("faRed",  Color(red: 0xDD/255, green: 0x4B/255, blue: 0x42/255))    // #DD4B42
    ]

    // Дополнительные цвета
    static let additional: [(name: String, color: Color)] = [
        ("blue", .blue), ("purple", .purple), ("pink", .pink), ("red", .red),
        ("orange", .orange), ("yellow", .yellow), ("green", .green), ("mint", .mint),
        ("teal", .teal), ("cyan", .cyan), ("indigo", .indigo), ("brown", .brown)
    ]

    static let all: [(name: String, color: Color)] = main + additional

    static func color(_ name: String) -> Color {
        all.first { $0.name == name }?.color ?? main[0].color   // по умолчанию #0198AF
    }
}

struct CardBackground: ViewModifier {
    @EnvironmentObject private var appearance: Appearance
    
    func body(content: Content) -> some View {
        #if os(iOS)
        if appearance.liquidGlass, #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }
    
    private func fallback(_ content: Content) -> some View {
        content
            .background(Palette.card)
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Корень приложения
struct ContentView: View {
    @EnvironmentObject private var viewModel: ScheduleViewModel
    @EnvironmentObject private var appearance: Appearance
    
    var body: some View {
        NavigationStack {
            if let group = viewModel.selectedGroup {
                ScheduleMainView(viewModel: viewModel, group: group)
            } else {
                SearchView(viewModel: viewModel)
            }
        }
    }
}

// MARK: - Онбординг уведомлений
struct NotificationIntroView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 56))
                .foregroundColor(.blue)
            
            Text("Уведомления")
                .font(.title2.bold())
            
            VStack(alignment: .leading, spacing: 12) {
                Label("Новое занятие на ближайшие два дня", systemImage: "plus.circle.fill")
                Label("Появление расписания сессии — зачёты и экзамены", systemImage: "checkmark.seal.fill")
                Label("Никакой рекламы и лишних сообщений", systemImage: "shield.fill")
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            
            VStack(spacing: 10) {
                Button {
                    UserDefaults.standard.set(true, forKey: "notifIntroShown")
                    Task { _ = await NotificationManager.shared.request() }
                    dismiss()
                } label: {
                    Text("Включить уведомления")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
                Button("Позже") {
                    UserDefaults.standard.set(true, forKey: "notifIntroShown")
                    dismiss()
                }
            }
            .padding(.horizontal)
        }
        .padding(24)
        #if os(iOS)
        .presentationDetents([.height(400)])
        .presentationDragIndicator(.hidden)
        #endif
    }
}

// MARK: - Поиск (избранные + недавние со звёздочками + результаты)
struct SearchView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    @AppStorage("accentColor") private var accentRaw = "faTeal"
    private var accent: Color { AccentColors.color(accentRaw) }
    
    private var query: String {
        viewModel.searchQuery.trimmingCharacters(in: .whitespaces)
    }
    
    var body: some View {
        List {
            if query.count < 2 {
                if !viewModel.favorites.isEmpty {
                    Section("Избранные") {
                        ForEach(viewModel.favorites) { resultRow($0, showStar: false) }
                            .onDelete { viewModel.removeFavorites(at: $0) }
                    }
                }
                if !viewModel.searchHistory.isEmpty {
                    Section {
                        // Недавние — со звёздочкой: можно добавить в избранное
                        ForEach(viewModel.searchHistory) { resultRow($0, showStar: true) }
                    } header: {
                        HStack {
                            Text("Недавние")
                            Spacer()
                            Button("Очистить") { viewModel.clearHistory() }
                                .font(.caption)
                        }
                    }
                }
                if viewModel.favorites.isEmpty && viewModel.searchHistory.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)
                            Text("Найдите группу или преподавателя")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    }
                }
            } else {
                Section {
                    if viewModel.searchResults.isEmpty {
                        Text("Ничего не найдено").foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.searchResults) { resultRow($0, showStar: true) }
                    }
                } header: {
                    Text("Результаты (\(viewModel.searchResults.count))")
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
        .searchable(text: $viewModel.searchQuery, prompt: "Группа или преподаватель...")
        .onChange(of: viewModel.searchQuery) { _, _ in viewModel.searchGroups() }
        .navigationTitle("Поиск")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                NavigationLink { SettingsView(viewModel: viewModel) } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
    }
    
    private func resultRow(_ entity: Group, showStar: Bool) -> some View {
        Button {
            viewModel.selectGroup(entity)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill((entity.isLecturer ? Color.green : entity.isAuditorium ? Color.orange : accent).opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: entity.isLecturer ? "person.fill" : entity.isAuditorium ? "door.left.hand.open" : "person.3.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(entity.isLecturer ? .green : entity.isAuditorium ? .orange : accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.name).font(.headline).foregroundColor(.primary)
                    Text(entity.typeLabel).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if showStar {
                    Button {
                        viewModel.toggleFavorite(entity)
                    } label: {
                        Image(systemName: viewModel.isFavorite(entity) ? "star.fill" : "star")
                            .foregroundColor(viewModel.isFavorite(entity) ? .yellow : .secondary)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(Color.secondary.opacity(0.5))
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Главный экран расписания
struct ScheduleMainView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    let group: Group
    @State private var selectedLesson: LessonGroup?
    @State private var showCalendar = false
    @AppStorage("detailPresentation") private var detailPresentation = "sheet"
    @State private var calendarDate = Date()
    
    private var effectiveStyle: String {
        #if os(iOS)
        return detailPresentation
        #else
        return detailPresentation == "sheet" ? "sheet" : "centered"
        #endif
    }
    
    var body: some View {
        LessonsList(viewModel: viewModel) { selectedLesson = $0 }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    // Область свайпа для смены недели (выше кнопки обновить)
                    VStack(spacing: 0) {
                        WeekBar(viewModel: viewModel)
                        StatusLine(viewModel: viewModel)
                    }
                    .contentShape(Rectangle())
                    #if os(iOS)
                    .gesture(
                        DragGesture(minimumDistance: 40)
                            .onEnded { value in
                                let w = value.translation.width
                                let h = value.translation.height
                                guard abs(w) > 50, abs(w) > abs(h) * 1.5 else { return }
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                                    viewModel.changeWeekKeepingWeekday(by: w < 0 ? 1 : -1)
                                }
                            }
                    )
                    #endif

                    // VPN-баннер (inline, под кнопкой обновить)
                    VPNBannerView()
                }
            }
            .overlay(alignment: .top) {
                if let prev = viewModel.navigationStack.last {
                    BackPill(title: prev.name) {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
                            viewModel.goBack()
                        }
                    }
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // КАЛЕНДАРЬ: то же проверенное окно снизу, что и у информации о паре
            .sheet(isPresented: $showCalendar) {
            VStack(spacing: 16) {
                Color.clear.frame(height: 14)
                
                DatePicker("", selection: $calendarDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "ru_RU"))
                    .padding(.horizontal)
                
                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        viewModel.jump(to: calendarDate)
                    }
                    showCalendar = false
                } label: {
                    Text("Перейти")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: 480)
            #if os(iOS)
            .presentationDetents([.height(430)])
            .presentationDragIndicator(.hidden)
            #endif
            .presentationBackground(Palette.background)
        }
        .navigationTitle(group.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarLeading) {
                NavigationLink { SettingsView(viewModel: viewModel) } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { showCalendar = true }
                } label: { Image(systemName: "calendar") }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { viewModel.selectedGroup = nil } label: { Image(systemName: "magnifyingglass") }
            }
            #else
            ToolbarItem(placement: .automatic) {
                NavigationLink { SettingsView(viewModel: viewModel) } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { showCalendar = true }
                } label: { Image(systemName: "calendar") }
            }
            ToolbarItem(placement: .automatic) {
                Button { viewModel.selectedGroup = nil } label: { Image(systemName: "magnifyingglass") }
            }
            #endif
        }
        .onAppear {
            if viewModel.allLessons.isEmpty { viewModel.fetchSchedule() }
            #if os(iOS)
            viewModel.scheduleAppRefresh()
            #endif
        }
        #if os(iOS)
        .refreshable { viewModel.refreshSchedule() }
        #endif
        // Окно пары: лист
        .sheet(item: effectiveStyle == "sheet" ? $selectedLesson : .constant(nil)) { g in
            detailView(g, showClose: false)
                .modifier(LessonSheetStyle())
        }
        // Окно пары: весь экран
        #if os(iOS)
        .fullScreenCover(item: effectiveStyle == "fullscreen" ? $selectedLesson : .constant(nil)) { g in
            detailView(g, showClose: true)
        }
        #endif
        // Окно пары: по центру
        .overlay {
            if effectiveStyle == "centered", let g = selectedLesson {
                ZStack {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { selectedLesson = nil }
                        }
                    detailView(g, showClose: true)
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
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: selectedLesson?.id)
    }
    
    private func detailView(_ g: LessonGroup, showClose: Bool) -> some View {
        LessonDetailContainer(
            group: g,
            currentEntity: viewModel.selectedGroup,
            onNavigate: { entity in
                viewModel.navigateTo(entity)
                selectedLesson = nil
            },
            onClose: {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { selectedLesson = nil }
            },
            showCloseButton: showClose,
            transparentBackground: effectiveStyle == "centered"
        )
    }
}

// MARK: - Стиль листа деталей (iPad — фикс. высота без ползунка)
struct LessonSheetStyle: ViewModifier {
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

// MARK: - Плавающая кнопка «назад»
struct BackPill: View {
    let title: String
    let action: () -> Void
    @AppStorage("accentColor") private var accentRaw = "faTeal"
    private var accent: Color { AccentColors.color(accentRaw) }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 13, weight: .bold))
                Text("Назад к «\(title)»")
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }
}

// MARK: - Полоска дней (свайп по списку пар = смена недели)
struct WeekBar: View {
    @ObservedObject var viewModel: ScheduleViewModel
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { index in
                let date = Calendar.current.date(byAdding: .day, value: index, to: viewModel.weekStart)!
                DayButton(
                    date: date,
                    isSelected: viewModel.selectedDate.isInSameDay(as: date)
                ) {
                    viewModel.selectDate(date)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .id(viewModel.weekStart)
        .transition(.asymmetric(
            insertion: .move(edge: viewModel.lastWeekDirection).combined(with: .opacity),
            removal: .move(edge: viewModel.lastWeekDirection == .trailing ? .leading : .trailing).combined(with: .opacity)
        ))
    }
}

struct DayButton: View {
    let date: Date
    let isSelected: Bool
    let action: () -> Void
    @AppStorage("accentColor") private var accentRaw = "faTeal"
    private var accent: Color { AccentColors.color(accentRaw) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(date.format("EE").uppercased())
                    .font(.system(size: 11, weight: .medium))
                Text(date.format("d"))
                    .font(.system(size: 16, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(dayBackground)
            .foregroundColor(isSelected ? .white : .primary)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(date.isToday && !isSelected ? accent.opacity(0.7) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var dayBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 12)
                .fill(accent)
        } else {
            #if os(iOS)
            if #available(iOS 26.0, *) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.tertiarySystemFill))
            }
            #else
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.tertiarySystemFill))
            #endif
        }
    }
}

// MARK: - Строка статуса: дата | обновление | кнопка ⟳
struct StatusLine: View {
    @ObservedObject var viewModel: ScheduleViewModel
    
    private var updateText: String? {
        guard let t = viewModel.lastUpdateTime else { return nil }
        if Calendar.current.isDateInToday(t) { return "Обновлено в \(t.format("HH:mm"))" }
        return "Обновлено \(t.format("d MMM, HH:mm"))"
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Text(viewModel.selectedDate.format("d MMMM yyyy"))
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
            
            if viewModel.isLoading {
                Text("Загрузка...")
                    .font(.system(size: 12))
                    .foregroundColor(Color.secondary.opacity(0.7))
            } else if let text = updateText {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(Color.secondary.opacity(0.7))
                    .lineLimit(1)
            }
            
            Spacer()
            
            if viewModel.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    viewModel.refreshSchedule()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(StatusLineBackground())
        .padding(.horizontal)
        .padding(.bottom, 6)
    }
}

// MARK: - Стеклянный фон для StatusLine
struct StatusLineBackground: View {
    var body: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.tertiarySystemFill))
        }
        #else
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(.tertiarySystemFill))
        #endif
    }
}

// MARK: - Список пар (свайп = соседний день)
struct LessonsList: View {
    @ObservedObject var viewModel: ScheduleViewModel
    let onSelectLesson: (LessonGroup) -> Void
    
    private static func isCurrent(_ g: LessonGroup) -> Bool {
        guard let b = LessonSlot.minutes(g.beginLesson ?? ""),
              let e = LessonSlot.minutes(g.endLesson ?? ""),
              let n = LessonSlot.minutes(Date().format("HH:mm")) else { return false }
        return n >= b && n < e
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if !viewModel.navigationStack.isEmpty {
                    Color.clear.frame(height: 40)
                }
                
                if viewModel.lessonGroups.isEmpty && viewModel.isLoading && viewModel.allLessons.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Загружаем расписание...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 100)
                } else if viewModel.lessonGroups.isEmpty {
                    EmptyStateView()
                        .padding(.top, 60)
                } else {
                    let today = viewModel.selectedDate.isToday
                    let showGroups = viewModel.selectedGroup?.isLecturer == true

                    // Заглушка баннера уведомлений (появляется при определённых условиях)
                    // ScheduleNotificationBanner()

                    ForEach(Array(viewModel.lessonGroups.enumerated()), id: \.element.id) { index, group in
                        LessonCardView(group: group, isCurrent: today && Self.isCurrent(group), showGroups: showGroups)
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                            .onTapGesture { onSelectLesson(group) }
                        
                        if index < viewModel.lessonGroups.count - 1 {
                            BreakIndicatorView(
                                prevEnd: group.endLesson,
                                nextBegin: viewModel.lessonGroups[index + 1].beginLesson,
                                today: today
                            )
                        }
                    }
                }
            }
            .padding()
        }
        #if os(iOS)
        .simultaneousGesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    let w = value.translation.width
                    let h = value.translation.height
                    // Только горизонтальные свайпы = смена дня (±1)
                    guard abs(w) > 50, abs(w) > abs(h) * 1.5 else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        viewModel.changeDay(by: w < 0 ? 1 : -1)
                    }
                }
        )
        #endif
    }
}

// Тонкая полоска перерыва с текущим временем
struct BreakIndicatorView: View {
    let prevEnd: String?
    let nextBegin: String?
    let today: Bool
    
    private var inGap: Bool {
        guard today,
              let e = LessonSlot.minutes(prevEnd ?? ""),
              let b = LessonSlot.minutes(nextBegin ?? ""),
              let n = LessonSlot.minutes(Date().format("HH:mm")) else { return false }
        return n >= e && n < b
    }
    
    private var minutesLeft: Int {
        guard let b = LessonSlot.minutes(nextBegin ?? ""),
              let n = LessonSlot.minutes(Date().format("HH:mm")) else { return 0 }
        return max(0, b - n)
    }
    
    var body: some View {
        if inGap {
            HStack(spacing: 8) {
                Rectangle().fill(Color.accentColor.opacity(0.4)).frame(height: 2)
                Text("Сейчас \(Date().format("HH:mm")) · до пары \(minutesLeft) мин")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.accentColor)
                    .fixedSize()
                Rectangle().fill(Color.accentColor.opacity(0.4)).frame(height: 2)
            }
            .padding(.horizontal, 8)
        }
    }
}

// MARK: - Карточка пары
struct LessonCardView: View {
    let group: LessonGroup
    let isCurrent: Bool
    var showGroups: Bool = false
    @AppStorage("accentColor") private var accentRaw = "faTeal"
    @AppStorage("iconColorMode") private var iconColorMode = "accent"
    private var accent: Color { AccentColors.color(accentRaw) }

    private var typeCol: Color {
        iconColorMode == "colorful" ? typeColor(group.kindOfWork) : accent
    }

    // Уникальные строки «кто — аудитория»
    private var pairs: [(who: String, aud: String)] {
        var seen = Set<String>()
        var result: [(String, String)] = []
        for l in group.lessons {
            let who = (showGroups ? (l.group ?? l.stream ?? "") : (l.lecturer ?? ""))
                .trimmingCharacters(in: .whitespaces)
            let aud = (l.auditorium ?? "").trimmingCharacters(in: .whitespaces)
            let key = who + "|" + aud
            if key == "|" { continue }
            if seen.insert(key).inserted {
                result.append((who, aud))
            }
        }
        return result
    }

    private var subgroupsText: String? {
        guard group.lessons.count > 1 else { return nil }
        let n = group.lessons.count
        return "\(n) \(n.pluralForm(one: "подгруппа", few: "подгруппы", many: "подгрупп"))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Левая колонка: время + номер пары внизу
            VStack(spacing: 4) {
                Text(group.beginLesson ?? "—")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(group.endLesson ?? "—")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.secondary)

                Spacer(minLength: 4)

                // Номер пары — внизу слева
                if let n = group.lessonNumber {
                    Text("\(n) пара")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 54)

            // Правая колонка: дисциплина + тип + кто/аудитория
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(group.discipline ?? "Дисциплина")
                        .font(.appHeadline())
                        .lineLimit(2)
                        .padding(.trailing, subgroupsText != nil ? 74 : 0)
                    if isCurrent {
                        Label("Сейчас", systemImage: "bolt.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(accent)
                            .cornerRadius(6)
                    }
                }

                // Тип занятия — без подложки, тем же шрифтом что и предмет, но цветным
                Text(lessonTypeLabel(group.kindOfWork))
                    .font(.appHeadline())
                    .foregroundColor(typeCol)

                if pairs.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(pairs.enumerated()), id: \.offset) { _, p in
                            HStack(spacing: 5) {
                                Image(systemName: showGroups ? "person.3.fill" : "person.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(typeCol)
                                Text("\(p.who) — \(p.aud)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.top, 2)
                } else if let p = pairs.first {
                    // Аудитория — крупнее, без адреса (адрес только в деталях)
                    if !p.aud.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(typeCol)
                            Text(p.aud)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                        .padding(.top, 2)
                    }
                    // Кто — крупнее
                    if !p.who.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: showGroups ? "person.3.fill" : "person.fill")
                                .font(.system(size: 14))
                                .foregroundColor(typeCol)
                            Text(p.who)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .modifier(CardBackground())
        // Бейдж подгрупп — правый верхний угол
        .overlay(alignment: .topTrailing) {
            if let text = subgroupsText {
                Text(text)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(accent.opacity(0.12))
                    .foregroundColor(accent)
                    .cornerRadius(6)
                    .padding(10)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isCurrent ? accent : Color.clear, lineWidth: 1.5)
        )
    }
}

// MARK: - Детали пары
struct LessonDetailContainer: View {
    let group: LessonGroup
    let currentEntity: Group?
    let onNavigate: (Group) -> Void
    let onClose: () -> Void
    let showCloseButton: Bool
    var transparentBackground: Bool = false
    
    @AppStorage("accentColor") private var accentRaw = "faTeal"
    @AppStorage("iconColorMode") private var iconColorMode = "accent"
    private var accent: Color { AccentColors.color(accentRaw) }
    @State private var copiedMessage: String?

    private var typeCol: Color {
        iconColorMode == "colorful" ? typeColor(group.kindOfWork) : accent
    }
    
    private var uniqueLecturers: [(oid: Int, name: String, email: String?)] {
        var seen = Set<String>()
        var result: [(Int, String, String?)] = []
        for l in group.lessons {
            guard let short = l.lecturer, !short.isEmpty else { continue }
            let full = l.lecturerTitle ?? short
            guard !seen.contains(full) else { continue }
            seen.insert(full)
            result.append((l.lecturerOid ?? 0, full, l.lecturerEmail))
        }
        return result
    }
    
    private var uniqueAuditoriums: [(oid: Int, name: String, building: String?)] {
        var seen = Set<String>()
        var result: [(Int, String, String?)] = []
        for l in group.lessons {
            guard let a = l.auditorium, !a.isEmpty, !seen.contains(a) else { continue }
            seen.insert(a)
            result.append((l.auditoriumOid ?? 0, a, l.building))
        }
        return result
    }
    
    // Группы занятия (group + stream) — для расписания преподавателя
    private var uniqueStreams: [(oid: Int, name: String)] {
        var seen = Set<String>()
        var result: [(Int, String)] = []
        for l in group.lessons {
            let name = (l.group ?? l.stream ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  let oid = l.groupOid ?? l.streamOid, oid != 0,
                  seen.insert(name).inserted else { continue }
            result.append((oid, name))
        }
        return result
    }
    
    private func copy(_ text: String, label: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        withAnimation { copiedMessage = label }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copiedMessage = nil }
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Заголовок
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.discipline ?? "")
                        .font(.title2.bold())
                    HStack {
                        Text(lessonTypeLabel(group.kindOfWork))
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(typeCol.opacity(0.15))
                            .foregroundColor(typeCol)
                            .cornerRadius(8)
                        Spacer()
                        Text("\(group.lessonNumber.map { "\($0)-я пара · " } ?? "")\(group.beginLesson ?? "") – \(group.endLesson ?? "")")
                            .font(.headline.monospacedDigit())
                    }
                    if currentEntity?.isLecturer == true, let groups = group.groupsLine {
                        Label(groups, systemImage: "person.3.fill")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()
                
                // Подгруппы / единичная пара
                if group.lessons.count > 1 {
                    let n = group.lessons.count
                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel("\(n) \(n.pluralForm(one: "подгруппа", few: "подгруппы", many: "подгрупп"))")
                        ForEach(Array(group.lessons.enumerated()), id: \.offset) { idx, lesson in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Подгруппа \(idx + 1)")
                                    .font(.caption.bold())
                                    .foregroundColor(.secondary)
                                
                                if let name = lesson.lecturerTitle ?? lesson.lecturer {
                                    Button { copy(name, label: "ФИО скопировано") } label: {
                                        detailRow(icon: "person.crop.circle.fill", iconColor: accent, text: name, trailing: "doc.on.doc")
                                    }
                                    .buttonStyle(.plain)
                                }
                                if let email = lesson.lecturerEmail, !email.isEmpty {
                                    Button { copy(email, label: "Почта скопирована") } label: {
                                        detailRow(icon: "envelope.fill", iconColor: accent, text: email, trailing: "doc.on.doc")
                                    }
                                    .buttonStyle(.plain)
                                }
                                if let aud = lesson.auditorium {
                                    detailRow(icon: "mappin.circle.fill", iconColor: typeCol, text: "Аудитория: \(aud)")
                                }
                            }
                            .padding(12)
                            .background(Palette.card)
                            .cornerRadius(12)
                        }
                    }
                } else if let lesson = group.lessons.first {
                    if let name = lesson.lecturerTitle ?? lesson.lecturer {
                        VStack(alignment: .leading, spacing: 10) {
                            sectionLabel("Преподаватель")
                            Button { copy(name, label: "ФИО скопировано") } label: {
                                detailRow(icon: "person.crop.circle.fill", iconColor: accent, text: name, trailing: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            if let email = lesson.lecturerEmail, !email.isEmpty {
                                Button { copy(email, label: "Почта скопирована") } label: {
                                    detailRow(icon: "envelope.fill", iconColor: accent, text: email, trailing: "doc.on.doc")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if let aud = lesson.auditorium {
                        VStack(alignment: .leading, spacing: 10) {
                            sectionLabel("Место проведения")
                            detailRow(icon: "mappin.circle.fill", iconColor: typeCol, text: "Аудитория: \(aud)")
                            if let b = lesson.building {
                                detailRow(icon: "building.2.fill", iconColor: typeCol, text: b)
                            }
                        }
                    }
                }
                
                Divider()
                
                // Навигация: у преподавателя — группы, у групп — преподаватели
                VStack(spacing: 10) {
                    if currentEntity?.isLecturer == true {
                        ForEach(Array(uniqueStreams.enumerated()), id: \.offset) { _, s in
                            Button {
                                onNavigate(Group(id: String(s.oid), name: s.name, type: "group", description: nil))
                            } label: {
                                Label("Расписание группы · \(s.name)", systemImage: "person.3.fill")
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ForEach(Array(uniqueLecturers.enumerated()), id: \.offset) { _, lecturer in
                            if lecturer.oid != 0 {
                                Button {
                                    onNavigate(Group(id: String(lecturer.oid), name: lecturer.name, type: "lecturer", description: nil))
                                } label: {
                                    Label(lecturer.name, systemImage: "person.2.fill")
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    ForEach(Array(uniqueAuditoriums.enumerated()), id: \.offset) { _, aud in
                        if aud.oid != 0 {
                            Button {
                                onNavigate(Group(id: String(aud.oid), name: aud.name, type: "auditorium", description: aud.building))
                            } label: {
                                Label("Аудитория \(aud.name)", systemImage: "door.left.hand.open")
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding()
        }
        .background {
            if transparentBackground {
                Color.clear
            } else {
                Palette.background.ignoresSafeArea()
            }
        }
        .overlay(alignment: .topTrailing) {
            if showCloseButton {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
        }
        .overlay(alignment: .bottom) {
            if let msg = copiedMessage {
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 16)
            }
        }
    }
    
    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
    }
    
    private func detailRow(icon: String, iconColor: Color, text: String, trailing: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(iconColor)
                .frame(width: 28)
            Text(text)
                .font(.body)
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)
            Spacer()
            if let trailing {
                Image(systemName: trailing)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Palette.card)
        .cornerRadius(12)
    }
}

// Форма: скруглены только верхние углы
struct TopRounded: Shape {
    var radius: CGFloat
    
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        p.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                       control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Настройки
struct SettingsView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    @EnvironmentObject private var appearance: Appearance
    @AppStorage("theme") private var theme = "system"
    @AppStorage("accentColor") private var accent = "faTeal"
    @AppStorage("detailPresentation") private var detailPresentation = "sheet"
    @AppStorage("iconColorMode") private var iconColorMode = "accent"
    @AppStorage("fontMode") private var fontMode = "system"
    @AppStorage("newsDisplayFormat") private var newsDisplayFormat: NewsDisplayFormat = .list
    @AppStorage("mailAutoCheck") private var mailAutoCheck = true
    @AppStorage("mailNotifications") private var mailNotifications = true
    @AppStorage("scheduleNotifications") private var scheduleNotifications = true
    @AppStorage("scheduleAutoRefresh") private var scheduleAutoRefresh = true
    @AppStorage("hapticFeedback") private var hapticFeedback = true
    @AppStorage("compactSchedule") private var compactSchedule = false
    @AppStorage("showTeacherContacts") private var showTeacherContacts = true
    
    private var accentColor: Color { AccentColors.color(accent) }
    
    private var homeCandidates: [Group] {
        var list = viewModel.favorites
        if let cur = viewModel.selectedGroup, !list.contains(where: { $0.id == cur.id }) {
            list.insert(cur, at: 0)
        }
        return list
    }
    
    private var homeBinding: Binding<String> {
        Binding(
            get: { viewModel.homeGroup?.id ?? "" },
            set: { newValue in
                if newValue.isEmpty {
                    viewModel.setHome(nil)
                } else if let g = homeCandidates.first(where: { $0.id == newValue }) {
                    viewModel.setHome(g)
                }
            }
        )
    }
    
    var body: some View {
        Form {
            // ========================
            // ВНЕШНИЙ ВИД
            // ========================
            Section {
                Picker("Тема", selection: $theme) {
                    Text("Системная").tag("system")
                    Text("Светлая").tag("light")
                    Text("Тёмная").tag("dark")
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Акцентный цвет")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    // Основная палитра
                    Text("Основные")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                        ForEach(AccentColors.main, id: \.name) { item in
                            Button {
                                accent = item.name
                                UISelectionFeedbackGenerator().selectionChanged()
                            } label: {
                                ZStack {
                                    Circle().fill(item.color).frame(width: 36, height: 36)
                                    if accent == item.name {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Дополнительные цвета
                    Text("Дополнительные")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                        ForEach(AccentColors.additional, id: \.name) { item in
                            Button {
                                accent = item.name
                                UISelectionFeedbackGenerator().selectionChanged()
                            } label: {
                                ZStack {
                                    Circle().fill(item.color).frame(width: 36, height: 36)
                                    if accent == item.name {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 4)

                Toggle("Liquid Glass (стекло)", isOn: $appearance.liquidGlass)

                Picker("Цвет иконок", selection: $iconColorMode) {
                    Text("Акцентный").tag("accent")
                    Text("Многоцветные").tag("colorful")
                    Text("Без цвета").tag("none")
                }
                .pickerStyle(.segmented)

                // Шрифт
                Picker("Шрифт", selection: $fontMode) {
                    ForEach(FontMode.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Внешний вид")
            } footer: {
                Text("Liquid Glass — стеклянный эффект карточек (iOS 26+). Шрифт: системные (SF Pro), Open Sans или Golos Text (фирменные по брендбуку).")
            }

            // ========================
            // РАСПИСАНИЕ
            // ========================
            Section {
                Picker("Домашняя группа", selection: homeBinding) {
                    Text("Не выбрана").tag("")
                    ForEach(homeCandidates) { g in
                        Text("\(g.name) (\(g.typeLabel))").tag(g.id)
                    }
                }

                Toggle("Авто-обновление", isOn: $scheduleAutoRefresh)
                Toggle("Компактный режим", isOn: $compactSchedule)
                Toggle("Контакты преподавателей", isOn: $showTeacherContacts)

                Picker("Формат новостей", selection: $newsDisplayFormat) {
                    Text("Список").tag(NewsDisplayFormat.list)
                    Text("Умная плитка").tag(NewsDisplayFormat.grid)
                    Text("Крупные").tag(NewsDisplayFormat.big)
                }
            } header: {
                Text("Расписание и новости")
            } footer: {
                Text("Домашняя группа открывается при запуске. Компактный режим уменьшает карточки. Контакты преподавателей показывают email и ФИО в окне пары.")
            }

            // ========================
            // ОКНО ИНФОРМАЦИИ
            // ========================
            Section {
                presentationOption("sheet", title: "Лист",
                                   description: "Компактное окно снизу. Можно потянуть вверх, чтобы раскрыть.")
                presentationOption("fullscreen", title: "Весь экран",
                                   description: "Подробности занимают весь экран. Удобно на iPhone.")
                presentationOption("centered", title: "По центру",
                                   description: "Диалог в центре экрана. Рекомендуется для iPad и Mac.")
            } header: {
                Text("Окно информации")
            } footer: {
                Text("Как открывается подробная информация при нажатии на карточку занятия или новости. На Mac — всегда по центру.")
            }

            // ========================
            // УВЕДОМЛЕНИЯ
            // ========================
            Section {
                Toggle("Расписание", isOn: $scheduleNotifications)
                Toggle("Новые письма", isOn: $mailNotifications)
                Toggle("Авто-проверка почты", isOn: $mailAutoCheck)

                if (scheduleNotifications || mailNotifications) {
                    Button {
                        Task {
                            _ = await NotificationManager.shared.request()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "bell.badge.fill")
                            Text("Разрешить уведомления")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Уведомления")
            } footer: {
                Text("Уведомления о занятиях и новых письмах. Фоновая проверка почты каждые 15 минут.")
            }

            // ========================
            // ВИДЖЕТЫ
            // ========================
            Section {
                NavigationLink {
                    WidgetGuideView(viewModel: viewModel)
                } label: {
                    HStack {
                        Image(systemName: "rectangle.grid.2x2.fill")
                            .foregroundColor(.accentColor)
                        Text("Гид по виджетам")
                    }
                }
            } header: {
                Text("Виджеты")
            } footer: {
                Text("Как добавить расписание на главный экран и настроить виджеты.")
            }

            // ========================
            // ДАННЫЕ И КЭШ
            // ========================
            Section {
                Button {
                    viewModel.refreshSchedule()
                } label: {
                    HStack {
                        Text("Обновить расписание сейчас")
                        Spacer()
                        if viewModel.isLoading {
                            ProgressView().controlSize(.small)
                        }
                    }
                }

                Toggle("Тактильная отдача", isOn: $hapticFeedback)

                Button("Очистить кэш расписаний", role: .destructive) {
                    viewModel.clearCache()
                }
                Button("Очистить историю", role: .destructive) {
                    viewModel.clearHistory()
                }
                Button("Очистить избранное", role: .destructive) {
                    viewModel.clearFavorites()
                }
            } header: {
                Text("Данные и кэш")
            } footer: {
                Text("Кэш — сохранённые расписания для мгновенного возврата и работы виджетов. Тактильная отдача — вибро-отклик при нажатиях.")
            }

            // ========================
            // О ПРИЛОЖЕНИИ
            // ========================
            Section {
                HStack {
                    Text("Версия")
                    Spacer()
                    Text("1.0").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Источник данных")
                    Spacer()
                    Text("ruz.fa.ru").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Платформа")
                    Spacer()
                    Text("iOS 17+ / SwiftUI").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Разработчик")
                    Spacer()
                    Text("kirillsorocuk").foregroundStyle(.secondary)
                }
            } header: {
                Text("О приложении")
            }

            // ========================
            // ИКОНКА ПРИЛОЖЕНИЯ
            // ========================
            Section {
                AppIconPicker()
            } header: {
                Text("Иконка приложения")
            } footer: {
                Text("Выберите иконку приложения. Изменение применяется мгновенно.")
            }
        }
        .navigationTitle("Настройки")
    }
    
    private func presentationOption(_ id: String, title: String, description: String) -> some View {
        Button {
            detailPresentation = id
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundColor(.primary)
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if detailPresentation == id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(accentColor)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Гид по виджетам
struct WidgetGuideView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    
    private var available: [Group] {
        var seen = Set<String>()
        var list: [Group] = []
        for g in ([viewModel.homeGroup].compactMap { $0 } + viewModel.favorites + viewModel.searchHistory) {
            let key = "\(g.type ?? "group")_\(g.id)"
            if seen.insert(key).inserted { list.append(g) }
        }
        return list
    }
    
    var body: some View {
        List {
            Section("Доступные виджеты") {
                Label("Ближайшая пара — ближайшее занятие (мал., ср.)", systemImage: "clock")
                Label("День целиком — все пары дня, листается (бол.)", systemImage: "list.bullet.rectangle")
                Label("Время занятий — первая/последняя пара + список (ср., бол.)", systemImage: "timer")
            }
            .font(.subheadline)
            
            Section("Как настроить") {
                Label("Добавьте виджет на рабочий стол", systemImage: "plus.square.on.square")
                Label("Удерживайте виджет → «Изменить»", systemImage: "hand.tap.fill")
                Label("Выберите расписание из списка", systemImage: "checkmark.circle.fill")
            }
            .font(.subheadline)
            
            Section {
                if available.isEmpty {
                    Text("Пока пусто. Добавьте группы в избранное (звёздочка в поиске) — они появятся в настройках виджетов.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(available) { g in
                        HStack {
                            Image(systemName: g.isLecturer ? "person.fill" : g.isAuditorium ? "door.left.hand.open" : "person.3.fill")
                                .foregroundColor(g.isLecturer ? .green : g.isAuditorium ? .orange : .blue)
                            Text(g.name)
                            Spacer()
                            Text(g.typeLabel)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("Доступны в виджетах")
            } footer: {
                Text("Можно добавить несколько виджетов — каждый со своим расписанием.")
            }
        }
        .navigationTitle("Виджеты")
    }
}

// MARK: - Заглушка «пар нет»
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image("MascotGuide")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 120)
                .accessibilityHidden(true)
            Text("В этот день пар нет!")
                .font(.title3.bold())
                .foregroundColor(.gray)
            Text("Можно отдохнуть и заняться своими делами")
                .font(.subheadline)
                .foregroundColor(.gray.opacity(0.8))
        }
        .multilineTextAlignment(.center)
    }
}

// MARK: - Баннер уведомлений в расписании (заглушка)
// Раскомментируйте ScheduleNotificationBanner() в LessonsList для использования
struct ScheduleNotificationBanner: View {
    let title: String
    let subtitle: String
    let icon: String
    var action: (() -> Void)? = nil
    @AppStorage("accentColor") private var accentRaw = "faTeal"
    private var accent: Color { AccentColors.color(accentRaw) }

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(accent, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - VPN-баннер (inline уведомление)
struct VPNBannerView: View {
    @StateObject private var banner = VPNBanner.shared

    var body: some View {
        if banner.isVisible {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VPN обнаружен")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Сервисы университета работают хуже с VPN. Отключите, чтобы стало лучше.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    banner.hide()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.orange.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Смена иконки приложения
struct AppIconPicker: View {
    // По умолчанию — бирюзовая
    @AppStorage("appIconName") private var appIconName = "Icon-TurquoiseBg-WhiteHat"

    // 9 иконок в матрице 3×3
    private let icons: [String] = [
        "Icon-TurquoiseBg-WhiteHat", "Icon-RedBg-WhiteHat", "Icon-DeepBlueBg-WhiteHat",
        "Icon-Turquoise-Logo30", "Icon-Red-Logo30", "Icon-DeepBlue-Logo30",
        "Icon-WhiteBg-TurquoiseHat", "Icon-WhiteBg-RedHat", "Icon-WhiteBg-DeepBlueHat"
    ]

    // Количество столбцов
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 28), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 28) {
            ForEach(icons, id: \.self) { iconName in
                Button {
                    setIcon(iconName)
                } label: {
                    iconImage(name: iconName)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(
                                    appIconName == iconName ? Color.accentColor : Color.clear,
                                    lineWidth: 3
                                )
                        )
                        .shadow(color: Color.black.opacity(0.1), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func iconImage(name: String) -> some View {
        Image(name).resizable()
    }

    private func setIcon(_ name: String) {
        #if os(iOS)
        let iconToSet = name == "AppIcon" ? nil : name
        UIApplication.shared.setAlternateIconName(iconToSet) { error in
            if let error = error {
                print("[AppIcon] Error: \(error)")
            } else {
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        appIconName = name
                    }
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }
        }
        #endif
    }
}
