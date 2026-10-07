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
    "path": "C:\\Temp"
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
