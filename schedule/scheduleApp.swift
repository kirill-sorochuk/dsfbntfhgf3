import SwiftUI
import Combine

@main
struct scheduleApp: App {
    @StateObject private var appearance = Appearance()
    @State private var showSplash = true

    init() {
        FontManager.registerFonts()
        // Очищаем кэш при запуске
        MemoryManager.cleanIfNeeded()
        MemoryManager.cleanTempFiles()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                AppRootView()
                    .environmentObject(appearance)

                if showSplash {
                    LKSplashView(
                        onFinished: {
                            withAnimation(.easeIn(duration: 0.2)) {
                                showSplash = false
                            }
                            // Проверяем VPN после закрытия splash
                            VPNBanner.shared.checkAndShow()
                        },
                        preload: {
                            let vm = await MainActor.run { ScheduleViewModel() }
                            if let home = vm.homeGroup {
                                let cal = Calendar.current
                                let from = cal.startOfDay(for: Date())
                                let to = cal.date(byAdding: .month, value: 1, to: from)!
                                _ = await RuzAPI.shared.fetchChunk(
                                    entityId: home.id,
                                    type: home.type ?? "group",
                                    start: from,
                                    end: to
                                )
                            }
                        }
                    )
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
        }
    }
}

// MARK: - VPN Detector + Banner Manager
enum VPNChecker {
    static func isVPNActive() -> Bool {
        #if os(iOS)
        let vpnProtocols: Set<String> = [
            "tap", "tun", "ppp", "ipsec", "utun", "gpd", "wg", "ipsec0", "utun0", "utun1", "utun2"
        ]
        var address: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&address) == 0 else { return false }
        defer { freeifaddrs(address) }

        var pointer = address
        while pointer != nil {
            let name = String(cString: pointer!.pointee.ifa_name)
            if vpnProtocols.contains(where: { name.hasPrefix($0) }) {
                return true
            }
            pointer = pointer!.pointee.ifa_next
        }
        return false
        #else
        return false
        #endif
    }
}

// Менеджер баннера VPN — показывает inline-уведомление
final class VPNBanner: ObservableObject {
    static let shared = VPNBanner()
    @Published var isVisible = false

    func checkAndShow() {
        guard VPNChecker.isVPNActive() else { return }
        let key = "vpn_warning_shown_\(Date().format("yyyyMMdd"))"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                self.isVisible = true
            }
            // Автоскрытие через 8 секунд
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                self.hide()
            }
        }
    }

    func hide() {
        withAnimation(.easeOut(duration: 0.3)) {
            isVisible = false
        }
    }
}

// MARK: - Корневой TabView: Новости | Расписание | Профиль

struct AppRootView: View {
    @EnvironmentObject private var appearance: Appearance
    @StateObject private var scheduleVM = ScheduleViewModel()
    @AppStorage("theme") private var theme = "system"
    @AppStorage("accentColor") private var accentRaw = "faTeal"
    @State private var showNotifIntro = false
    @State private var animateTabs = false
    @State private var selectedTab = 1 // Расписание по умолчанию (2-я вкладка)

    private var colorScheme: ColorScheme? {
        switch theme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private var activePublisher: NotificationCenter.Publisher {
        #if canImport(UIKit)
        return NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
        #else
        return NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        #endif
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Новости (1-я вкладка — слева)
            NavigationStack {
                LKNewsView()
                    .environmentObject(scheduleVM)
                    .offset(x: animateTabs ? 0 : -40)
                    .opacity(animateTabs ? 1 : 0)
            }
            .tabItem {
                Label("Новости", systemImage: "newspaper")
            }
            .tag(0)

            // Расписание (2-я вкладка — открывается по умолчанию)
            ContentView()
                .environmentObject(scheduleVM)
                .offset(y: animateTabs ? 0 : 20)
                .opacity(animateTabs ? 1 : 0)
            .tabItem {
                Label("Расписание", systemImage: "calendar")
            }
            .tag(1)

            // Профиль (3-я вкладка)
            NavigationStack {
                LKRootView()
                    .environmentObject(scheduleVM)
                    .offset(x: animateTabs ? 0 : 40)
                    .opacity(animateTabs ? 1 : 0)
            }
            .tabItem {
                Label("Профиль", systemImage: "person.crop.circle")
            }
            .tag(2)
        }
        .tint(AccentColors.color(accentRaw))
        .preferredColorScheme(colorScheme)
        .onReceive(activePublisher) { _ in
            NotificationCenter.default.post(name: .init("appForeground"), object: nil)
            // Тихо перепроверяем сессию ЛК при активации приложения
            Task { @MainActor in
                let manager = LKManager.shared
                if manager.state == .loggedIn {
                    if let s = await manager.probeSession(), s.user != nil {
                        manager.session = s
                        manager.lastSessionCheck = Date()
                    }
                } else if manager.state == .unknown {
                    await manager.checkSession()
                }
                await LKManager.syncCookiesFromWKWebView()
                await LKManager.syncCookiesToWKWebView()
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(0.15)) {
                animateTabs = true
            }
            if UserDefaults.standard.object(forKey: "notifIntroShown") == nil {
                showNotifIntro = true
            }
        }
        .sheet(isPresented: $showNotifIntro) {
            NotificationIntroView()
        }
    }
}
