# MVP live test

This test validates the first complete Local Bridge loop on a real Windows machine:

```text
ChatGPT -> assistant bridge request -> WebView2 adapter -> native C#
        -> Windows filesystem -> bridge result -> same ChatGPT conversation
```

No OpenAI API, MCP server, localhost service, or third-party plugin is used.

## 1. Prepare the probe file

Create:

```text
C:\Temp\bridge-test.txt
```

with a distinctive value, for example:

```text
LOCAL-BRIDGE-PROBE-01
```

## 2. Start the client

1. Extract the development ZIP to a normal writable directory.
2. Run `ChatGptDesktopLocalBridge.exe`.
3. Sign in to ChatGPT inside the embedded browser if necessary.
4. Open a new normal conversation.
5. Click **Initialize Bridge**.
6. Confirm the status line shows `Bridge initialized. Session ...`.

The bootstrap message is intentionally hidden by the Web adapter after it is sent.

## 3. Run the end-to-end probe

Send a normal human request:

```text
Прочитай файл C:\Temp\bridge-test.txt и скажи мне ровно, что в нём написано.
```

Expected behavior:

1. ChatGPT produces one `LOCAL_BRIDGE_REQUEST_V1` for `fs.read_text`.
2. The adapter waits until the assistant message is stable and validates that the whole message is a bridge request.
3. The machine request is hidden from the visible conversation.
4. Native C# reads the file.
5. A `LOCAL_BRIDGE_RESULT_V1` message is sent automatically into the same conversation and hidden.
6. ChatGPT answers with the actual file contents.
7. No manual copy/paste is required.

## 4. Check the audit log

The local operation should be recorded in:

```text
%LOCALAPPDATA%\ChatGptDesktopLocalBridge\logs\bridge-YYYYMMDD.jsonl
```

The record contains request metadata and timing, but not the returned file contents.

## 5. Permission configuration

The active user policy is stored in:

```text
%APPDATA%\ChatGptDesktopLocalBridge\permissions.json
```

The **Permissions** button opens that file. Policy values are `AUTO`, `ASK`, or `DENY`.

The current MVP implements only:

- `system.info`
- `fs.list`
- `fs.read_text`

The broader permissions in the default file are forward-compatible configuration, not hard-coded restrictions.

## Failure evidence to capture

If the probe fails, record:

- the status text shown by the client;
- whether the bootstrap appeared in the visible chat;
- whether the assistant bridge request appeared or disappeared;
- whether a result message appeared or disappeared;
- the final lines of the local audit log;
- a screenshot of the ChatGPT page.

Do not retry by manually copying bridge envelopes. A failure should be diagnosed in the transport or DOM compatibility layer.
