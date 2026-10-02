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

## Установка и обновление

Предпочтительный способ для Windows — `ChatGptDesktopLocalBridge-Setup.exe` из GitHub Releases.

Установщик:
- устанавливает приложение для текущего пользователя в `%LOCALAPPDATA%\Programs\ChatGPT Desktop Local Bridge`;
- создаёт обычную запись удаления Windows и ярлык в меню Пуск;
- использует постоянный AppId, поэтому запуск более новой версии установщика обновляет существующую установку поверх неё, а не создаёт новую копию;
- обновляет только файлы программы.

WebView2-профиль хранится отдельно:

`%LOCALAPPDATA%\ChatGptDesktopLocalBridge\WebView2`

Поэтому cookies, local storage и остальное состояние ChatGPT не находятся в каталоге установки и не удаляются при обычном обновлении программы. Текущая portable-сборка использует тот же путь, поэтому переход с portable на установленную версию также сохраняет уже созданный WebView2-профиль.

Portable ZIP остаётся только как диагностический/резервный вариант.

### Инкрементальные обновления

Для обычных следующих обновлений release workflow формирует маленькие single-file update installer'ы вида:

`ChatGptDesktopLocalBridge-Update-from-dev-XXXXXXX.exe`

Пользователю не нужно распаковывать архивы или запускать скрипты вручную: достаточно запустить подходящий EXE.

Updater:
- проверяет, что установлен именно ожидаемый базовый release;
- закрывает приложение;
- делает временный backup затрагиваемых файлов;
- применяет только изменённые/добавленные файлы и удаления;
- проверяет SHA-256 результата;
- откатывает изменения при ошибке;
- снова запускает приложение;
- не изменяет `%LOCALAPPDATA%\ChatGptDesktopLocalBridge\WebView2`.

Начиная с manifest-backed releases базовая версия определяется по `release-info.json` и точному `ChatGptDesktopLocalBridge-PublishManifest.json`. Для legacy `dev-1d00606` используется отдельная миграционная проверка по Inno Setup version и стабильным файлам, без побайтного требования к пересобранному .NET DLL.

Полный `ChatGptDesktopLocalBridge-Setup.exe` остаётся в каждом dev-release для первой установки и как fallback.

### Удаление программы

При обычной деинсталляции файлы программы из `%LOCALAPPDATA%\Programs\ChatGPT Desktop Local Bridge` удаляются всегда.

Перед удалением деинсталлятор дополнительно спрашивает:

`Удалить также настройки и рабочие данные?`

- **Нет** — сохраняется `%LOCALAPPDATA%\ChatGptDesktopLocalBridge`, включая WebView2-профиль и авторизацию ChatGPT.
- **Да** — эта папка удаляется целиком вместе с локальными рабочими данными и WebView2-профилем.

## Запуск из исходников

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
3. Нажать **Diagnostics** и убедиться, что WebView и composer определяются корректно.
4. Нажать **Initialize Bridge**.
5. После bootstrap-сообщения можно попросить ChatGPT, например:
   `Посмотри список файлов в C:/Temp`.
6. Если модель корректно запросит `fs.list`, приложение выполнит запрос локально и автоматически вернёт результат в тот же разговор.

В bridge JSON Windows-пути передаются с прямыми слэшами (`C:/...`), чтобы Markdown/JSON-рендеринг ChatGPT не искажал обратные слэши.

Кнопка **Diagnostics** показывает состояние WebView adapter: версию, наличие IPC, найден ли composer, готов ли native input, а также последнюю безопасную protocol-диагностику. Содержимое локальных запросов в эту диагностику не копируется.

### Надёжность Web adapter

Текущий adapter:
- вводит служебные сообщения через native Chromium/WebView2 input, а не прямой DOM mutation;
- поддерживает текущие и legacy-селекторы сообщений ChatGPT;
- исполняет только строгий точный `LOCAL_BRIDGE_REQUEST_V1` envelope и fail-closed отклоняет всё остальное;
- ждёт стабильности streaming-ответа перед dispatch;
- показывает payload-free причину malformed bridge-кандидата в Diagnostics;
- никогда не перезаписывает обычный пользовательский draft;
- может заменить только собственный stale draft, начинающийся с `LOCAL_BRIDGE_BOOTSTRAP_V1` или `LOCAL_BRIDGE_RESULT_V1`;
- умеет определить, что конкретный `LOCAL_BRIDGE_RESULT_V1` уже присутствует в текущем разговоре, чтобы crash-recovery не дублировал доставленный результат.

## Важная архитектурная граница

`chatgpt.com` не предоставляет публичный контракт для DOM-автоматизации. Поэтому Web adapter изолирован в одном файле `Web/bridge-adapter.js` и рассматривается как заменяемый compatibility layer. Изменение DOM ChatGPT не должно требовать изменения LocalToolHost или протокола.

## Данные

Постоянный профиль WebView2:

`%LOCALAPPDATA%\ChatGptDesktopLocalBridge\WebView2`

Настройки разрешений:

`%APPDATA%\ChatGptDesktopLocalBridge\permissions.json`

Audit log:

`%LOCALAPPDATA%\ChatGptDesktopLocalBridge\logs\bridge-YYYYMMDD.jsonl`

Durable request state:

`%LOCALAPPDATA%\ChatGptDesktopLocalBridge\state\requests`

Пока result имеет состояние `Pending`, его bounded envelope хранится здесь для crash-recovery. После подтверждённой доставки payload удаляется из ledger; остаются только идентификаторы, fingerprint и техническое состояние выполнения/доставки.

## Статус

- BRIDGE-M1 закрыт: READY и `fs.read_text` подтверждены на реальном Windows PC.
- BRIDGE-M2 закрыт: Web adapter fail-closed, диагностирует protocol-кандидаты и защищает пользовательский draft.
- BRIDGE-M3 durable foundation завершён как единый проверяемый slice: request ledger переживает restart, отделяет execution от delivery, блокирует небезопасный replay состояния `Executing`, восстанавливает Pending-result только в исходном ChatGPT conversation, не повторяет уже `Delivered` result и удаляет его payload после подтверждённой доставки. Полный `LOCAL_BRIDGE_RESULT_V1` ограничен 256 KiB; превышение превращается в явный bounded error без повторного выполнения локального tool. Tool dispatch, permission capability и bootstrap exposure теперь используют единый capability registry.
