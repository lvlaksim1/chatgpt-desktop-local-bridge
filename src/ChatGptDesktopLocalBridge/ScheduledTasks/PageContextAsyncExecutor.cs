using System.Diagnostics;
using System.Text.Json;
using Microsoft.Web.WebView2.Wpf;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

internal static class PageContextAsyncExecutor
{
    private const string SlotName = "__chatGptDesktopLocalBridgeAsyncResults";

    public static async Task<T> ExecuteAsync<T>(
        WebView2 browser,
        string asyncBody,
        TimeSpan timeout)
    {
        if (browser.CoreWebView2 is null)
        {
            throw new InvalidOperationException(
                "ChatGPT WebView is not initialized.");
        }

        var key = Guid.NewGuid().ToString("N");
        var keyJson = JsonSerializer.Serialize(key);

        var startScript = $$"""
            (() => {
              const key = {{keyJson}};
              const root = window;
              if (!root.{{SlotName}}) {
                Object.defineProperty(root, "{{SlotName}}", {
                  value: Object.create(null),
                  configurable: true
                });
              }

              root.{{SlotName}}[key] = { state: "pending" };

              Promise.resolve().then(async () => {
                try {
                  const value = await (async () => {
                    {{asyncBody}}
                  })();

                  root.{{SlotName}}[key] = {
                    state: "done",
                    value
                  };
                } catch (error) {
                  root.{{SlotName}}[key] = {
                    state: "error",
                    error: String(error)
                  };
                }
              });

              return { started: true };
            })()
            """;

        var startRaw = await browser.ExecuteScriptAsync(startScript);
        if (string.IsNullOrWhiteSpace(startRaw) ||
            string.Equals(startRaw, "null", StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "Page-context async operation could not be started.");
        }

        var stopwatch = Stopwatch.StartNew();

        try
        {
            while (stopwatch.Elapsed < timeout)
            {
                var pollScript = $$"""
                    (() => {
                      const root = window;
                      const key = {{keyJson}};
                      const slot = root.{{SlotName}};
                      if (!slot || !slot[key] || slot[key].state === "pending") {
                        return null;
                      }

                      const result = slot[key];
                      delete slot[key];
                      return result;
                    })()
                    """;

                var raw = await browser.ExecuteScriptAsync(pollScript);

                if (string.IsNullOrWhiteSpace(raw) ||
                    string.Equals(raw, "null", StringComparison.Ordinal))
                {
                    await Task.Delay(50);
                    continue;
                }

                var envelope = JsonSerializer.Deserialize<AsyncEnvelope<T>>(
                    raw,
                    new JsonSerializerOptions
                    {
                        PropertyNameCaseInsensitive = true
                    });

                if (envelope is null)
                {
                    throw new InvalidOperationException(
                        "Page-context async result could not be decoded.");
                }

                if (string.Equals(
                        envelope.State,
                        "error",
                        StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException(
                        envelope.Error ??
                        "Page-context async operation failed.");
                }

                if (!string.Equals(
                        envelope.State,
                        "done",
                        StringComparison.OrdinalIgnoreCase) ||
                    envelope.Value is null)
                {
                    throw new InvalidOperationException(
                        "Page-context async operation returned an invalid terminal state.");
                }

                return envelope.Value;
            }

            throw new TimeoutException(
                $"Page-context async operation exceeded {timeout.TotalSeconds:0.#} seconds.");
        }
        finally
        {
            try
            {
                var cleanupScript = $$"""
                    (() => {
                      const slot = window.{{SlotName}};
                      if (slot) delete slot[{{keyJson}}];
                      return true;
                    })()
                    """;
                await browser.ExecuteScriptAsync(cleanupScript);
            }
            catch
            {
                // Best-effort cleanup only.
            }
        }
    }

    private sealed class AsyncEnvelope<T>
    {
        public string? State { get; set; }
        public T? Value { get; set; }
        public string? Error { get; set; }
    }
}
