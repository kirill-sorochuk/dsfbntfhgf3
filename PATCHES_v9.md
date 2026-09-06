# fa.schedule — Патчи v9 (Bitrix SSO вместо JWT)

> **Контекст:** Все эндпоинты `org.fa.ru/bitrix/vuz/api/*` (профиль, приказы, зачётка,
> студбилет) возвращали **401 Unauthorized**, потому что Swift-код использовал
> JWT Bearer от `client_id=elk-front`. Но JWT с `aud=account` и
> `allowed-origins=lk.fa.ru` **невалиден для org.fa.ru**.
>
> **Открытие v9:** Bitrix использует **собственную сессионную авторизацию**
> (cookies `BX_ORG_FA_RU_*`), JWT вообще не нужен. Сессия создаётся через
> 5-шаговый SSO-handshake через `/bitrix/vuz/sso/*`. Реальный `client_id`
> для org.fa.ru = **`orgfaru-client`** (не `elk-front`).

## Полный работающий flow

```
Шаги 1-7: авторизация lk.fa.ru (NextAuth + Keycloak + OTP) — без изменений

Bitrix SSO Handshake (новое):
  B1. GET https://org.fa.ru/                                -> PHPSESSID
  B2. GET /bitrix/vuz/sso/link?backurl=%2F                  -> JSON {auth_url}
                                                              (client_id=orgfaru-client)
  B3. GET auth_url (Keycloak SSO via KEYCLOAK_IDENTITY)     -> 302 с code (БЕЗ OTP)
  B4. GET /bitrix/vuz/sso/callback?code=XXX&state=YYY       -> BX_ORG_FA_RU_* cookies
  B5. GET /app/profile/home                                  -> метаданные (GUEST_ID, TZ)
```

После этого все запросы к `/bitrix/vuz/api/*` работают **только на cookies**
(как в браузере). `Authorization: Bearer` **не нужен и вреден**.

## Изменённые файлы (6 штук)

### 1. `NativeAuthManager.swift` — главные изменения

**Добавлено:**

- **3 константы Bitrix SSO:**
  ```swift
  private let bitrixBase = "https://org.fa.ru"
  private let bitrixSSOLinkURL = "https://org.fa.ru/bitrix/vuz/sso/link"
  private let bitrixSSOCallbackURL = "https://org.fa.ru/bitrix/vuz/sso/callback"
  ```

- **Флаг и Task для отслеживания handshake:**
  ```swift
  private var bitrixSSOTask: Task<Bool, Never>? = nil
  ```
  + `UserDefaults.standard.bool(forKey: "bitrixSSODone")` для постоянного флага.

- **Логгер `bitrixLog()`** — выводит с тегом `[bitrixSSO]` для удобной фильтрации в консоли.

- **Метод `bitrixSSOHandshake() async -> Bool`** — 5-шаговый SSO flow:
  - B1: GET `/` → PHPSESSID
  - B2: GET `/bitrix/vuz/sso/link?backurl=%2F` → парсит JSON, достаёт `auth_url`
  - B3: GET `auth_url` на Keycloak (SSO через KEYCLOAK_IDENTITY) → перехватывает 302
        (используя уже существующий `RedirectBlockingDelegate`), достаёт `code` и `state`
  - B4: GET `/bitrix/vuz/sso/callback?code=...&state=...` → Bitrix создаёт BX cookies.
        Здесь **разрешаем редиректы** (временная URLSession без RedirectBlockingDelegate),
        так как Bitrix может редиректить обратно на `/`.
  - B5: GET `/app/profile/home` → догружаем метаданные.
  - В конце проверяет наличие `BX_ORG_FA_RU_*` cookies и синхронизирует их в WKWebView.

- **Static-метод `ensureBitrixSession() async`** — гарантирует, что Bitrix-сессия есть:
  - Если `bitrixSSODone=true` и BX cookies существуют → сразу возвращает
  - Если handshake уже идёт — ждёт его завершения (через `bitrixSSOTask`)
  - Иначе запускает новый handshake
  - **Все `fetchBitrix*` методы должны вызывать это перед запросом.**

- **Static-метод `resetBitrixSSO()`** — сбрасывает флаг (для retry при 401).

- **В `fetchSessionAndFinish()`** после строки `authLog("=== АВТОРИЗАЦИЯ УСПЕШНА ===")`
  добавлен fire-and-forget запуск handshake:
  ```swift
  Task { [weak self] in
      guard let self else { return }
      let ok = await self.bitrixSSOHandshake()
      authLog("Bitrix SSO: \(ok ? "OK" : "FAILED")")
  }
  ```

**Изменено:**

- **`orgFaHeaders()`** — убран блок добавления `Authorization: Bearer`,
  `App-Version` обновлён с `8.133.0` → `8.135.3`. Добавлена синхронизация
  куки из WKWebView через новый хелпер `syncCookiesFromWKWebViewIfNeeded()`.

- **`fetchJWTAndSession()`** — превращён в stub, сразу вызывает
  `fetchSessionAndFinish(accessToken: nil, refreshToken: nil, expiresIn: nil)`.
  Вся логика SSO+PKCE для получения JWT удалена (~80 строк).

- **`refreshAccessToken()`** — превращён в stub, всегда возвращает `nil`.
  Сохранён для обратной совместимости (вдруг где-то вызывается).

- **`getOrgAccessToken()`** — превращён в stub, всегда возвращает `nil`.
  Сохранён для обратной совместимости.

### 2. `LKManager.swift` — изменения

**`bitrixHeaders(_:)`:**
- Удалён блок добавления `Authorization: Bearer` через `getOrgAccessToken()`.
- `App-Version` обновлён с `8.133.0` → `8.135.3`.

**`fetchBitrixProfile()`:**
- В начало добавлено `await NativeAuthManager.ensureBitrixSession()`.
- После handshake куки перечитываются (`cookies2`) — в них появятся `BX_ORG_FA_RU_*`.
- В retry-блоке на 401: раньше вызывал `refreshAccessToken()` — теперь вызывает
  `NativeAuthManager.resetBitrixSSO()` + `bitrixSSOHandshake()`, затем повторяет запрос.

**`fetchOrders()`:**
- Аналогично: `ensureBitrixSession()` в начале, retry через `bitrixSSOHandshake()`.

**`fetchStudentCard()`:**
- Аналогично: `ensureBitrixSession()` в начале.
- В retry-блоке на 401: раньше просто возвращал nil — теперь пробует
  перезапустить handshake и повторить запрос.
- Извлечена отдельная функция `processStudentCardResponse(_:headers:)` —
  чтобы не дублировать код между primary и retry запросами.

### 3. `LKGradebook.swift` — изменения

**URL:** `https://org.fa.ru/bitrix/vuz/api/marks2` → `https://org.fa.ru/bitrix/vuz/api/marks2/`
       (trailing slash обязателен — без него Bitrix возвращает 404).

**JWT Bearer блок (строки 201-206 в оригинале):** полностью удалён.

**В начало `fetchGradebook()`:** добавлено `await NativeAuthManager.ensureBitrixSession()`,
после handshake куки перечитываются.

**Retry-блок на 401:** раньше обновлял JWT через `refreshAccessToken()` —
  теперь вызывает `NativeAuthManager.resetBitrixSSO()` + `bitrixSSOHandshake()`,
  затем перечитывает куки и повторяет запрос.

**`App-Version`:** `8.133.0` → `8.135.3`.

**`Referer`:** добавлен `https://org.fa.ru/app/profile;mode=edu/marks`
              (как в браузерном запросе).

### 4-6. Дополнительные файлы с теми же изменениями

Эти файлы тоже использовали `org.fa.ru/bitrix/vuz/api/*`, но без Bearer (только cookies).
Применён тот же подход: добавлен `ensureBitrixSession()` + `App-Version` обновлён.

- **`LKNotificationsView.swift`** — `fetchNotifications()`:
  - Добавлен `await NativeAuthManager.ensureBitrixSession()` перед циклом URL candidates.
  - `App-Version`: `8.133.0` → `8.135.3`.

- **`MailManager.swift`** — `fetchWorkspaceContacts(query:)`:
  - Добавлен `await NativeAuthManager.ensureBitrixSession()` после проверки cookies.
  - `App-Version`: `8.133.0` → `8.135.3`.

- **`LKViews.swift`** — `fetchExtendedData()`:
  - Добавлен `await NativeAuthManager.ensureBitrixSession()` после проверки cookies.
  - Добавлены заголовки `App-Version: 8.135.3` и `App-Key: browser-bitrix`
    (раньше их не было — запрос мог падать с 400).

## Ключевые выводы (почему JWT не работал)

| Проблема | Причина | Решение |
|----------|---------|---------|
| JWT от `elk-front` невалиден для `org.fa.ru` | `aud=account`, `allowed-origins=lk.fa.ru` | Использовать Bitrix SSO с `client_id=orgfaru-client` |
| Bitrix не использует JWT вообще | Собственная сессионная авторизация | Cookies `BX_ORG_FA_RU_*` через `/bitrix/vuz/sso/*` |
| `trailing slash` обязателен для `marks2` | Bitrix требует `/` на некоторых эндпоинтах | URL `marks2/` вместо `marks2` |
| `App-Version` устарел | `8.133.0` — сервер требует актуальную | Обновлён до `8.135.3` |

## Как проверить (логи в Xcode)

После авторизации и открытия ЛК в консоли Xcode по тегу `bitrixSSO` должны увидеть:

```
HH:MM:SS.SSS [bitrixSSO] === Bitrix SSO Handshake (5 шагов) ===
HH:MM:SS.SSS [bitrixSSO] [1/5]: GET https://org.fa.ru/
HH:MM:SS.SSS [bitrixSSO] [1/5]: статус 302
HH:MM:SS.SSS [bitrixSSO] [2/5]: GET /bitrix/vuz/sso/link?backurl=%2F
HH:MM:SS.SSS [bitrixSSO] [2/5]: статус 200
HH:MM:SS.SSS [bitrixSSO] [2/5]: auth_url получен: https://auth.fa.ru/realms/elk/...
HH:MM:SS.SSS [bitrixSSO] [3/5]: GET Keycloak auth_url (SSO)
HH:MM:SS.SSS [bitrixSSO] [3/5]: статус 302
HH:MM:SS.SSS [bitrixSSO] [3/5]: Location -> https://org.fa.ru/bitrix/vuz/sso/callback?...
HH:MM:SS.SSS [bitrixSSO] [3/5]: code получен: 58634744-...
HH:MM:SS.SSS [bitrixSSO] [4/5]: GET https://org.fa.ru/bitrix/vuz/sso/callback?code=...
HH:MM:SS.SSS [bitrixSSO] [4/5]: статус 200
HH:MM:SS.SSS [bitrixSSO] [5/5]: GET /app/profile/home
HH:MM:SS.SSS [bitrixSSO] [5/5]: статус 200
HH:MM:SS.SSS [bitrixSSO] SUCCESS — получено 4 BX_ORG_FA_RU cookies
HH:MM:SS.SSS [bitrixSSO] cookies -> WKWebView (12 шт)
HH:MM:SS.SSS [AUTH] Bitrix SSO: OK
```

## Сборка и запуск

1. Откройте `schedule.xcodeproj` в Xcode 16+
2. Выберите target `schedule` и устройство (iPhone 15 / iOS 17+)
3. ⌘B для проверки сборки
4. ⌘R для запуска
5. Авторизуйтесь (логин/пароль + OTP)
6. Зайдите в ЛК → должны загрузиться:
   - Профиль (ФИО, курс, форма обучения, факультет, группа)
   - Приказы (список с датами)
   - Зачётная книжка (по учебным годам и семестрам)
   - Студенческий билет (PDF)

## Файлы, изменённые в v9

- `schedule/NativeAuthManager.swift` — добавлен Bitrix SSO handshake, заглушены JWT-методы
- `schedule/LKManager.swift` — убран Bearer, добавлен `ensureBitrixSession()` в Bitrix-запросы
- `schedule/LKGradebook.swift` — URL `marks2/`, убран JWT, добавлен Referer и `ensureBitrixSession()`
- `schedule/LKNotificationsView.swift` — `ensureBitrixSession()` + `App-Version=8.135.3`
- `schedule/MailManager.swift` — `ensureBitrixSession()` + `App-Version=8.135.3` в `fetchContacts`
- `schedule/LKViews.swift` — `ensureBitrixSession()` + `App-Version=8.135.3` + `App-Key` в `fetchExtendedData`

## Артефакты диагностики

- `/home/z/my-project/upload/lk_auth_diagnostic_v9.py` — Python-скрипт, который воспроизводит
  весь flow (NextAuth + Keycloak + OTP + Bitrix SSO) и проверяет все эндпоинты.
  Использовался для поиска решения.
