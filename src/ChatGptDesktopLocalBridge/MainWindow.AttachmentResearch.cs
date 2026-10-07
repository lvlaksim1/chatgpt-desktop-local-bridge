using System.Text.Json;
using ChatGptDesktopLocalBridge.ScheduledTasks;

namespace ChatGptDesktopLocalBridge;

public partial class MainWindow
{
    private async Task<bool> TryRunAttachmentTransportResearchProbeAsync(ChatTab tab)
    {
        var resultPath = Environment.GetEnvironmentVariable(
            "LOCAL_BRIDGE_ATTACHMENT_RESEARCH_RESULT");

        if (string.IsNullOrWhiteSpace(resultPath))
        {
            return false;
        }

        object output;

        try
        {
            var asyncBody = """
                const gapMs = 5000;
                let lastCompletedAt = null;
                const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

                async function pacedFetch(path, options) {
                  if (lastCompletedAt !== null) {
                    const remaining =
                      gapMs - (performance.now() - lastCompletedAt);
                    if (remaining > 0) await delay(remaining);
                  }

                  try {
                    const response = await fetch(path, options);
                    const text = await response.text();
                    lastCompletedAt = performance.now();
                    return {
                      ok: response.ok,
                      status: response.status,
                      text
                    };
                  } catch (error) {
                    lastCompletedAt = performance.now();
                    throw error;
                  }
                }

                const authResponse = await pacedFetch('/api/auth/session', {
                  method: 'GET',
                  credentials: 'include',
                  cache: 'no-store',
                  redirect: 'error',
                  headers: { accept: 'application/json' }
                });

                if (!authResponse.ok) {
                  throw new Error(
                    'auth_session_http_' + authResponse.status);
                }

                const session = JSON.parse(authResponse.text || '{}');
                const token =
                  typeof session?.accessToken === 'string'
                    ? session.accessToken
                    : '';
                const accountId =
                  typeof session?.account?.id === 'string'
                    ? session.account.id
                    : '';

                if (!token || token.length < 8) {
                  throw new Error('auth_session_missing_access_token');
                }

                const headers = {
                  accept: 'application/json, text/plain, */*',
                  authorization: 'Bearer ' + token
                };

                if (accountId) {
                  headers['chatgpt-account-id'] = accountId;
                }

                const pausedResponse = await pacedFetch(
                  '/backend-api/automations?filter=paused',
                  {
                    method: 'GET',
                    credentials: 'include',
                    cache: 'no-store',
                    redirect: 'follow',
                    headers
                  });

                if (!pausedResponse.ok) {
                  throw new Error(
                    'paused_list_http_' + pausedResponse.status);
                }

                const paused = JSON.parse(pausedResponse.text || '{}');
                const items = Array.isArray(paused?.items)
                  ? paused.items
                  : [];

                const selected =
                  items.find(item =>
                    item &&
                    item.is_enabled === false &&
                    typeof item.id === 'string') ||
                  items[0] ||
                  null;

                if (!selected?.id) {
                  throw new Error('no_automation_available');
                }

                const detailResponse = await pacedFetch(
                  '/backend-api/automation/' +
                    encodeURIComponent(selected.id),
                  {
                    method: 'GET',
                    credentials: 'include',
                    cache: 'no-store',
                    redirect: 'follow',
                    headers
                  });

                if (!detailResponse.ok) {
                  throw new Error(
                    'automation_detail_http_' + detailResponse.status);
                }

                const detail = JSON.parse(detailResponse.text || '{}');

                const relevantKeys = value =>
                  Object.keys(value || {})
                    .filter(key =>
                      /file|attach|upload|asset|document|media|resource|conversation|metadata|content/i
                        .test(key))
                    .sort();

                const describe = value => {
                  const result = {};
                  for (const key of Object.keys(value || {}).sort()) {
                    const item = value[key];
                    result[key] =
                      item === null
                        ? 'null'
                        : Array.isArray(item)
                          ? 'array'
                          : typeof item;
                  }
                  return result;
                };

                return {
                  ok: true,
                  networkMinGapMs: gapMs,
                  listKeys: Object.keys(paused || {}).sort(),
                  itemKeys: Object.keys(selected || {}).sort(),
                  itemRelevantKeys: relevantKeys(selected),
                  itemTypes: describe(selected),
                  detailKeys: Object.keys(detail || {}).sort(),
                  detailRelevantKeys: relevantKeys(detail),
                  detailTypes: describe(detail),
                  automationIdPresent:
                    typeof detail?.id === 'string' &&
                    detail.id.length > 0,
                  conversationIdPresent:
                    typeof detail?.conversation_id === 'string' &&
                    detail.conversation_id.length > 0
                };
                """;

            var probe = await PageContextAsyncExecutor.ExecuteAsync<JsonElement>(
                tab.Browser,
                asyncBody,
                TimeSpan.FromSeconds(45));

            output = new
            {
                status = "pass",
                probe
            };
        }
        catch (Exception ex)
        {
            output = new
            {
                status = "fail",
                error = ex.Message
            };
        }

        try
        {
            var directory = Path.GetDirectoryName(resultPath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            await File.WriteAllTextAsync(
                resultPath,
                JsonSerializer.Serialize(
                    output,
                    new JsonSerializerOptions
                    {
                        WriteIndented = true
                    }));
        }
        finally
        {
            Dispatcher.BeginInvoke(
                new Action(() => Application.Current.Shutdown()));
        }

        return true;
    }
}
