import Foundation

// MARK: - Менеджер памяти
// Контролирует размер кэша и очищает при превышении лимита
// Приоритет сохранения (по убыванию):
// 1. Расписание
// 2. Данные ЛК
// 3. Последние 5-10 новостей из избранного раздела
// 4. 5-7 новостей из всех разделов
// 5. Прочие новости (чистим первыми)

enum MemoryManager {
    /// Максимальный размер кэша в байтах (200 МБ)
    static let maxCacheSize: Int = 200 * 1024 * 1024

    /// Проверяет размер кэша и очищает при необходимости
    static func cleanIfNeeded() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let size = directorySize(at: cacheDir)
        guard size > maxCacheSize else { return }

        print("[Memory] Cache size: \(size / 1024 / 1024) MB — cleaning...")

        // Очищаем в порядке приоритета (с конца):
        // 1. Сначала — старые новости всех разделов
        cleanOldNewsCache()
        // 2. Потом — статьи новостей
        cleanArticleCache()
        // 3. Проверяем снова
        let newSize = directorySize(at: cacheDir)
        if newSize > maxCacheSize {
            // Если всё ещё много — чистим кэш новостей кроме избранного раздела
            cleanAllNewsExceptPinned()
        }

        let finalSize = directorySize(at: cacheDir)
        print("[Memory] After cleaning: \(finalSize / 1024 / 1024) MB")
    }

    // Размер директории
    static func directorySize(at url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += size
            }
        }
        return total
    }

    // Очищаем старые новости (оставляем последние 5-7 из каждого раздела)
    private static func cleanOldNewsCache() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let newsCacheDir = cacheDir.appendingPathComponent("NewsCache")

        // Сохраняем последние 7 новостей из каждого раздела
        let keepCount = 7

        // Секции
        for section in NewsSection.allCases {
            let path = newsCacheDir.appendingPathComponent("\(section.cacheKey).json")
            trimNewsCache(at: path, keepCount: keepCount)
        }

        // Факультеты
        for faculty in Faculty.allCases {
            let path = newsCacheDir.appendingPathComponent("\(faculty.cacheKey).json")
            trimNewsCache(at: path, keepCount: keepCount)
        }
    }

    // Обрезаем кэш-файл новостей, оставляя только keepCount последних
    private static func trimNewsCache(at path: URL, keepCount: Int) {
        guard let data = try? Data(contentsOf: path),
              var items = try? JSONDecoder().decode([NewsItem].self, from: data) else { return }
        guard items.count > keepCount else { return }

        // Оставляем только последние keepCount
        items = Array(items.suffix(keepCount))
        if let trimmedData = try? JSONEncoder().encode(items) {
            try? trimmedData.write(to: path)
        }
    }

    // Очищаем кэш статей (новости уже загружены, статьи можно удалить)
    private static func cleanArticleCache() {
        // Article cache хранится в памяти NewsManager, тут можем очистить файлы если есть
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let articleCacheDir = cacheDir.appendingPathComponent("ArticleCache")
        try? FileManager.default.removeItem(at: articleCacheDir)
    }

    // Очищаем все новости кроме избранного раздела
    private static func cleanAllNewsExceptPinned() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let newsCacheDir = cacheDir.appendingPathComponent("NewsCache")

        // Удаляем все файлы кэша новостей
        try? FileManager.default.removeItem(at: newsCacheDir)
        try? FileManager.default.createDirectory(at: newsCacheDir, withIntermediateDirectories: true)
    }

    /// Очищает временные файлы (временная директория)
    static func cleanTempFiles() {
        let tmpDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil) else { return }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Полная очистка кэша (кроме расписания)
    static func clearAllCacheExceptSchedule() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        guard let items = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }

        for item in items {
            let name = item.lastPathComponent
            // Не удаляем расписание
            if name.contains("schedule") || name.contains("lessons") || name.contains("widget") { continue }
            // Не удаляем кэш ЛК
            if name.contains("lk") || name.contains("gradebook") { continue }
            try? FileManager.default.removeItem(at: item)
        }
    }
}
