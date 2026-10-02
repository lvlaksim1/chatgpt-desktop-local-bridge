# Local Bridge Protocol v1

## Принцип

Модель работает в обычном разговоре ChatGPT. Когда ей требуется локальная операция, она возвращает ровно один машинный запрос.

### Request

```text
[[LOCAL_BRIDGE_REQUEST_V1]]
{
  "session": "<current-session-id>",
  "id": "req-0001",
  "tool": "fs.list",
  "args": {
    "path": "C:/Temp"
  }
}
[[/LOCAL_BRIDGE_REQUEST_V1]]
```

Запрос считается исполнимым только если:

- он находится в сообщении с ролью assistant;
- присутствуют оба marker;
- JSON полностью парсится;
- `session` совпадает с текущей native session;
- `id` ещё не исполнялся;
- `tool` зарегистрирован;
- permission policy разрешает capability.

### Result

```text
[[LOCAL_BRIDGE_RESULT_V1]]
{
  "session": "<current-session-id>",
  "request_id": "req-0001",
  "ok": true,
  "result": {}
}
[[/LOCAL_BRIDGE_RESULT_V1]]
```

Result автоматически отправляется в тот же conversation как служебное user message.

## Bootstrap

Native client сообщает модели session id, доступные tools и правила протокола через bootstrap user message. Bootstrap/result/request сообщения скрываются Web adapter-ом из визуального интерфейса, но остаются частью server-side conversation.

## Transport acknowledgement and delayed ChatGPT responses

Native client inserts bridge-owned user messages through Chromium/WebView2 native input and submits them with native `Enter`.

Local submit acknowledgement is intentionally independent from assistant completion:

- before submit, the adapter records the current user-message count;
- submit is confirmed when either the composer clears or an exact new user-message appears after that baseline;
- an identical older user-message does not confirm a new send;
- local submit confirmation is bounded to 30 seconds;
- READY/assistant-dependent waits are separate and may continue for up to 5 minutes when ChatGPT/network response is delayed.

This separation prevents slow network, service-side review, or slow model response from being misclassified as a local input failure.

## Permission policy

Разрешения находятся вне кода:

```text
%APPDATA%\ChatGptDesktopLocalBridge\permissions.json
```

Значения:

- `AUTO` — выполнить автоматически;
- `ASK` — потребовать подтверждение пользователя;
- `DENY` — отклонить.

MVP реализует read-only tools с AUTO по умолчанию. ASK уже представлен в policy model, а диалог подтверждения будет добавлен на следующем этапе.

## Security invariants, не являющиеся ограничениями полномочий

Даже в будущем unrestricted-профиле сохраняются:

- session nonce;
- unique request id;
- защита от duplicate execution;
- JSON/schema validation;
- проверка source origin;
- обработка только assistant messages;
- ожидание полного closing marker;
- audit log без содержимого возвращаемых файлов.

Это защищает транспорт и целостность исполнения, но не задаёт, какие capabilities пользователь вправе включить.
