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

## Durable request lifecycle

До выполнения native client резервирует пару `session + request_id` в локальном ledger:

`%LOCALAPPDATA%\ChatGptDesktopLocalBridge\state\requests`

Execution state проходит последовательность:

`reserved -> executing -> completed`

Delivery state ведётся отдельно:

`notReady -> pending -> delivered`

Практические инварианты:

- повтор того же `session + request_id` с тем же tool/args не запускает tool повторно;
- повтор того же id с другим tool/args считается конфликтом и fail-closed отклоняется;
- после локального завершения execution сначала фиксируется `completed/pending`, и только затем выполняется отправка `LOCAL_BRIDGE_RESULT_V1`;
- успешная отправка отдельно фиксируется как `delivered`;
- crash/restart не стирает факт уже начатого или завершённого execution;
- ledger не хранит аргументы запроса или payload результата — только fingerprint, состояния и технические метаданные.

Текущий этап M3 намеренно ещё не выполняет replay payload для записи `completed/pending`. Такая запись блокирует слепой повтор execution и остаётся видимой как незавершённая доставка для следующего слоя recovery.

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
