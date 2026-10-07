using System.Text.Json;
using ChatGptDesktopLocalBridge.Bridge;
using Microsoft.Web.WebView2.Wpf;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

public sealed class LocalIntentPlanner
{
    private const int NetworkMinGapMs = 5000;
    private static readonly HashSet<string> AllowedPlannedTools =
        new(StringComparer.Ordinal)
        {
            "system.info",
            "fs.list",
            "fs.read_text",
            "fs.write_text",
            "fs.append_text",
            "fs.copy_first_line"
        };

    private readonly WebView2 _browser;
    private readonly RequestBindingGuard _binding;
    private readonly LocalIntentServiceStateStore _serviceState;

    public LocalIntentPlanner(WebView2 browser)
    {
        _browser = browser;
        _binding = new RequestBindingGuard(browser);
        _serviceState = new LocalIntentServiceStateStore();
    }

    public async Task<BridgePlannedAction> PlanAsync(
        string instruction,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(instruction))
        {
            throw new BridgeToolException(
                "invalid_args",
                "Local intent instruction is empty.");
        }

        if (_browser.CoreWebView2 is null)
        {
            throw new BridgeToolException(
                "private_transport_unavailable",
                "ChatGPT WebView is not initialized.");
        }

        cancellationToken.ThrowIfCancellationRequested();

        var binding = _binding.Capture();
        var probeId = "lb-" + Guid.NewGuid().ToString("N");
        var messageId = "msg-" + Guid.NewGuid().ToString("N");
        var serviceAutomationId =
            _serviceState.LoadAutomationId();

        var payload = JsonSerializer.Serialize(new
        {
            instruction,
            probeId,
            messageId,
            serviceAutomationId,
            networkMinGapMs = NetworkMinGapMs
        });

        var asyncBody = """
            const p = PAYLOAD;
            const started = performance.now();
            const minGapMs = Math.max(
              5000,
              Number(p.networkMinGapMs || 5000));
            const serviceTitle = 'Local Bridge Service Planner';
            const servicePrefix =
              'LOCAL BRIDGE SERVICE PLANNER V1.';
            const serviceSchedule = [
              'BEGIN:VEVENT',
              'DTSTART:20991231T235900',
              'END:VEVENT'
            ].join('\\n');

            let lastRequestCompletedAt = null;
            let authorization = "";
            let accountId = "";

            const delay =
              ms => new Promise(resolve => setTimeout(resolve, ms));

            async function beforeNetworkRequest() {
              if (lastRequestCompletedAt === null) return;
              const elapsed =
                performance.now() - lastRequestCompletedAt;
              const remaining = minGapMs - elapsed;
              if (remaining > 0) await delay(remaining);
            }

            async function rawFetch(path, options) {
              await beforeNetworkRequest();
              let response;
              try {
                response = await fetch(path, options);
                const text = await response.text();
                lastRequestCompletedAt = performance.now();
                return {
                  ok: response.ok,
                  status: response.status,
                  text
                };
              } catch (error) {
                lastRequestCompletedAt = performance.now();
                throw error;
              }
            }

            async function acquireAuth() {
              const r = await rawFetch('/api/auth/session', {
                method: 'GET',
                credentials: 'include',
                cache: 'no-store',
                redirect: 'error',
                headers: { 'accept': 'application/json' }
              });

              if (!r.ok) {
                throw new Error(
                  'auth_session_http_' + r.status);
              }

              const session = JSON.parse(r.text || '{}');
              const accessToken =
                typeof session?.accessToken === 'string'
                  ? session.accessToken
                  : '';

              accountId =
                typeof session?.account?.id === 'string'
                  ? session.account.id
                  : '';

              if (!accessToken || accessToken.length < 8) {
                throw new Error(
                  'auth_session_missing_access_token');
              }

              authorization = 'Bearer ' + accessToken;
            }

            async function api(method, path, body = null) {
              const headers = {
                'accept': 'application/json, text/plain, */*',
                'authorization': authorization
              };

              if (accountId) {
                headers['chatgpt-account-id'] = accountId;
              }

              const options = {
                method,
                credentials: 'include',
                redirect: 'follow',
                headers
              };

              if (body !== null) {
                headers['content-type'] = 'application/json';
                options.body = JSON.stringify(body);
              }

              const r = await rawFetch(path, options);
              let json = null;
              if (r.text) {
                try { json = JSON.parse(r.text); } catch {}
              }

              return { ...r, json };
            }

            function isServiceTask(value) {
              return Boolean(
                value &&
                value.is_enabled === false &&
                typeof value.id === 'string' &&
                value.id.length > 0 &&
                String(value.title || '') === serviceTitle &&
                String(value.prompt || '')
                  .startsWith(servicePrefix));
            }

            function extractAutomationId(value) {
              const candidates = [
                value?.id,
                value?.jawbone_id,
                value?.automation?.id,
                value?.automation?.jawbone_id,
                value?.task?.id,
                value?.task?.jawbone_id
              ];

              for (const candidate of candidates) {
                if (
                  typeof candidate === 'string' &&
                  candidate.length > 0
                ) {
                  return candidate;
                }
              }

              return '';
            }

            function createBody(prompt) {
              return {
                default_timezone:
                  Intl.DateTimeFormat()
                    .resolvedOptions().timeZone || 'UTC',
                email_enabled: false,
                is_enabled: false,
                notifications_enabled: false,
                prompt,
                emoji: '🔗',
                schedule: serviceSchedule,
                timing_mode: 0,
                title: serviceTitle
              };
            }

            function saveBody(current, prompt) {
              const body = {
                default_timezone:
                  current.default_timezone ||
                  Intl.DateTimeFormat()
                    .resolvedOptions().timeZone ||
                  'UTC',
                email_enabled: false,
                is_enabled: false,
                jawbone_id: current.id,
                notifications_enabled: false,
                prompt,
                emoji: current.display_emoji || '🔗',
                schedule:
                  current.schedule || serviceSchedule,
                timing_mode: 0,
                title: serviceTitle
              };

              if (current.model != null) {
                body.model = current.model;
              }

              if (current.reasoning_effort != null) {
                body.reasoning_effort =
                  current.reasoning_effort;
              }

              return body;
            }

            function finalText(run) {
              return typeof run?.content_text === 'string'
                ? run.content_text.trim()
                : '';
            }

            const marker =
              'PROBE_ID=' + p.probeId +
              ' MESSAGE_ID=' + p.messageId +
              ' ACTION_JSON=';

            const plannerPrompt = [
              servicePrefix,
              'You are planning exactly one local-computer action.',
              'You do not have access to the local computer. Do not claim that you executed anything.',
              'User instruction:',
              p.instruction,
              '',
              'Allowed tools and exact argument shapes:',
              '1. fs.copy_first_line {"source_path":"C:/path/source.txt","destination_path":"C:/path/destination.txt","overwrite":true,"create_directories":true}',
              '2. fs.read_text {"path":"C:/path/file.txt","max_chars":200000}',
              '3. fs.write_text {"path":"C:/path/file.txt","text":"text","overwrite":true,"create_directories":true}',
              '4. fs.append_text {"path":"C:/path/file.txt","text":"text","create_if_missing":true,"create_directories":true}',
              '5. fs.list {"path":"C:/path"}',
              '6. system.info {}',
              '',
              'For a request to copy the first line of one text file into another file, use fs.copy_first_line.',
              'Return exactly one line and no Markdown:',
              marker + '{"tool":"<allowed tool>","args":{...}}'
            ].join('\\n');

            await acquireAuth();

            let service = null;
            const preferredId =
              typeof p.serviceAutomationId === 'string'
                ? p.serviceAutomationId.trim()
                : '';

            if (preferredId) {
              const preferred = await api(
                'GET',
                '/backend-api/automation/' +
                  encodeURIComponent(preferredId));

              if (
                preferred.ok &&
                isServiceTask(preferred.json)
              ) {
                service = preferred.json;
              }
            }

            if (!service) {
              const paused = await api(
                'GET',
                '/backend-api/automations?filter=paused');

              if (
                !paused.ok ||
                !Array.isArray(paused.json?.items)
              ) {
                throw new Error(
                  'service_recovery_list_http_' +
                  paused.status);
              }

              service =
                paused.json.items.find(isServiceTask) ||
                null;
            }

            let created = false;

            if (!service) {
              let createResult = null;

              try {
                createResult = await api(
                  'POST',
                  '/backend-api/automations/save',
                  createBody(plannerPrompt));
              } catch {
                const readback = await api(
                  'GET',
                  '/backend-api/automations?filter=paused');

                if (
                  readback.ok &&
                  Array.isArray(readback.json?.items)
                ) {
                  service =
                    readback.json.items.find(x =>
                      isServiceTask(x) &&
                      String(x.prompt || '')
                        .includes(p.probeId)) ||
                    null;
                }

                if (!service) {
                  throw new Error(
                    'service_create_unknown_outcome');
                }
              }

              if (!service) {
                if (!createResult?.ok) {
                  throw new Error(
                    'service_create_http_' +
                    String(createResult?.status ?? 0) +
                    '_' +
                    String(createResult?.text || '')
                      .slice(0, 300));
                }

                const createdId =
                  extractAutomationId(createResult.json);

                if (createdId) {
                  const detail = await api(
                    'GET',
                    '/backend-api/automation/' +
                      encodeURIComponent(createdId));

                  if (
                    detail.ok &&
                    isServiceTask(detail.json)
                  ) {
                    service = detail.json;
                  }
                }

                if (!service) {
                  const readback = await api(
                    'GET',
                    '/backend-api/automations?filter=paused');

                  if (
                    readback.ok &&
                    Array.isArray(readback.json?.items)
                  ) {
                    service =
                      readback.json.items.find(x =>
                        isServiceTask(x) &&
                        String(x.prompt || '')
                          .includes(p.probeId)) ||
                      readback.json.items.find(
                        isServiceTask) ||
                      null;
                  }
                }

                if (!service) {
                  throw new Error(
                    'service_create_readback_failed');
                }
              }

              created = true;
            }

            if (!created) {
              const saved = await api(
                'POST',
                '/backend-api/automations/save',
                saveBody(service, plannerPrompt));

              if (!saved.ok) {
                throw new Error(
                  'service_save_http_' + saved.status +
                  '_' +
                  String(saved.text || '')
                    .slice(0, 300));
              }
            }

            const run = await api(
              'POST',
              '/backend-api/automation/' +
                encodeURIComponent(service.id) +
                '/run',
              {
                idempotency_key:
                  crypto.randomUUID()
              });

            if (!run.ok) {
              throw new Error(
                'service_run_http_' + run.status +
                '_' +
                String(run.text || '').slice(0, 300));
            }

            await delay(8000);

            let latest = null;

            for (let attempt = 0; attempt < 5; attempt++) {
              const candidate = await api(
                'GET',
                '/backend-api/automation/' +
                  encodeURIComponent(service.id) +
                  '/latest_backing_run?include_snapshot=true');

              if (!candidate.ok) {
                throw new Error(
                  'latest_run_http_' +
                  candidate.status);
              }

              const text = finalText(candidate.json);
              if (text.startsWith(marker)) {
                latest = candidate.json;
                break;
              }
            }

            if (!latest) {
              throw new Error(
                'latest_run_not_correlated');
            }

            return {
              ok: true,
              probeId: p.probeId,
              messageId: p.messageId,
              contentText: finalText(latest),
              runId: latest?.id ?? null,
              runCreatedAt: latest?.created_at ?? null,
              workerId: service.id,
              serviceCreated: created,
              elapsedMs:
                Math.round(
                  performance.now() - started)
            };
            """
            .Replace("PAYLOAD", payload);

        PlannerScriptResult? result;
        try
        {
            result = await PageContextAsyncExecutor.ExecuteAsync<PlannerScriptResult>(
                _browser,
                asyncBody,
                TimeSpan.FromMinutes(2));
        }
        catch (Exception ex)
        {
            throw new BridgeToolException(
                "private_transport_failed",
                ex.Message);
        }

        cancellationToken.ThrowIfCancellationRequested();

        try
        {
            _binding.Validate(binding);
        }
        catch (Exception ex)
        {
            throw new BridgeToolException(
                "private_transport_stale_context",
                ex.Message);
        }

        if (result is null || !result.Ok)
        {
            throw new BridgeToolException(
                "private_transport_failed",
                "Server-side local action planning did not complete.");
        }

        if (!string.IsNullOrWhiteSpace(result.WorkerId))
        {
            _serviceState.SaveAutomationId(
                result.WorkerId);
        }

        var marker =
            $"PROBE_ID={probeId} MESSAGE_ID={messageId} ACTION_JSON=";
        var contentText = result.ContentText?.Trim() ?? string.Empty;

        if (!contentText.StartsWith(marker, StringComparison.Ordinal))
        {
            throw new BridgeToolException(
                "private_transport_protocol",
                "Server-side action result did not match the current request.");
        }

        var json = contentText[marker.Length..].Trim();
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;

            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("tool", out var toolElement) ||
                toolElement.ValueKind != JsonValueKind.String ||
                !root.TryGetProperty("args", out var argsElement) ||
                argsElement.ValueKind != JsonValueKind.Object)
            {
                throw new InvalidOperationException(
                    "Action JSON must contain tool and args.");
            }

            var tool = toolElement.GetString() ?? string.Empty;
            if (!AllowedPlannedTools.Contains(tool))
            {
                throw new InvalidOperationException(
                    $"Planned tool is not allowed: {tool}");
            }

            return new BridgePlannedAction(
                tool,
                argsElement.Clone(),
                probeId,
                messageId,
                result.RunId,
                result.RunCreatedAt,
                result.ElapsedMs);
        }
        catch (BridgeToolException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new BridgeToolException(
                "private_transport_protocol",
                ex.Message);
        }
    }

    private sealed class PlannerScriptResult
    {
        public bool Ok { get; set; }
        public string? ProbeId { get; set; }
        public string? MessageId { get; set; }
        public string? ContentText { get; set; }
        public string? RunId { get; set; }
        public string? RunCreatedAt { get; set; }
        public string? WorkerId { get; set; }
        public bool ServiceCreated { get; set; }
        public long ElapsedMs { get; set; }
    }
}
