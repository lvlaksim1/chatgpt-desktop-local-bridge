# ChatGPT Desktop Local Bridge

Экспериментальный Windows-клиент ChatGPT, который использует обычный `chatgpt.com` и пользовательскую подписку ChatGPT **без OpenAI API**, но добавляет встроенный локальный мост к компьютеру.

## Цель первого прототипа

Доказать полный цикл:

```text
ChatGPT в WebView2
  -> LOCAL_BRIDGE_REQUEST_V1
  -> native C# LocalToolHost
  -> Windows
  -> LOCAL_BRIDGE_RESULT_V1
  -> обратно в тот же разговор ChatGPT
  -> обычный человеческий ответ
```

Первая версия намеренно содержит только read-only tools:

- `system.info`
- `fs.list`
- `fs.read_text`

Политика доступа **не прошита жестко в коде**. Она хранится во внешнем `permissions.json`. Безопасный профиль создаётся по умолчанию, но пользователь может штатно изменить `AUTO / ASK / DENY` для capabilities и расширить доступ в будущих версиях вплоть до полного доверия.

## Технологии

- .NET 8
- WPF
- Microsoft Edge WebView2
- Local Bridge внутри процесса приложения; localhost-сервер не используется

## Запуск

Требования:

- Windows 10/11
- .NET 8 Desktop Runtime или .NET 8 SDK
- Microsoft Edge WebView2 Runtime

```powershell
dotnet restore
dotnet run --project .\src\ChatGptDesktopLocalBridge\ChatGptDesktopLocalBridge.csproj
```

После запуска:

1. Войти в ChatGPT обычным способом внутри WebView2.
2. Открыть нужный чат или новый чат.
3. Нажать **Initialize Bridge**.
4. После bootstrap-сообщения можно попросить ChatGPT, например:
   `Посмотри список файлов в C:\Temp`.
5. Если модель корректно запросит `fs.list`, приложение выполнит запрос локально и автоматически вернёт результат в тот же разговор.

## Важная архитектурная граница

`chatgpt.com` не предоставляет публичный контракт для DOM-автоматизации. Поэтому Web adapter изолирован в одном файле `Web/bridge-adapter.js` и рассматривается как заменяемый compatibility layer. Изменение DOM ChatGPT не должно требовать изменения LocalToolHost или протокола.

## Данные

Постоянный профиль WebView2:

`%LOCALAPPDATA%\ChatGptDesktopLocalBridge\WebView2`

Настройки разрешений:

`%APPDATA%\ChatGptDesktopLocalBridge\permissions.json`

Audit log:

`%LOCALAPPDATA%\ChatGptDesktopLocalBridge\logs\bridge-YYYYMMDD.jsonl`

## Статус

MVP / feasibility prototype.
