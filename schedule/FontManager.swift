import SwiftUI

// MARK: - Менеджер шрифтов (только системный шрифт SF Pro)
// Кастомные шрифты (Open Sans, Golos Text) удалены — оставляем только системный,
// как просил пользователь. Все методы .app/.appHeadline/.appBody теперь возвращают
// системный шрифт, чтобы не нужно было переписывать вызовы в других файлах.

enum FontMode: String, CaseIterable {
    case system = "system"  // только системный режим

    var label: String { "Системные" }
    var icon: String { "textformat" }
}

extension Font {
    /// Возвращает системный шрифт для стиля (раньше применял Open Sans / Golos).
    static func app(_ style: Font.TextStyle, mode: FontMode = .system) -> Font {
        .system(style)
    }

    static func appBody(_ mode: FontMode = .system) -> Font { .system(.body) }
    static func appHeadline(_ mode: FontMode = .system) -> Font { .system(.headline) }
    static func appTitle2(_ mode: FontMode = .system) -> Font { .system(.title2) }
    static func appTitle3(_ mode: FontMode = .system) -> Font { .system(.title3) }
    static func appCaption(_ mode: FontMode = .system) -> Font { .system(.caption) }
    static func appSubheadline(_ mode: FontMode = .system) -> Font { .system(.subheadline) }
}

// MARK: - FontManager (заглушка, не делает ничего)
enum FontManager {
    static var currentMode: FontMode { .system }

    /// Раньше регистрировала кастомные шрифты Open Sans / Golos Text.
    /// Сейчас — no-op, оставлено для обратной совместимости с вызовами в scheduleApp.init().
    static func registerFonts() {
        // Намеренно пусто: используем только системный шрифт SF Pro.
    }
}
