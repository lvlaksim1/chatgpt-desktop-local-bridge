using System.Text.Json;
using ChatGptDesktopLocalBridge.Bridge;
using Microsoft.Web.WebView2.Wpf;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

public sealed class LocalIntentPlanner
{
    private const int NetworkMinGapMs = 5000;
    private const string WorkerTitle =
        "Local Bridge · служебный планировщик";
    private const string WorkerMarker =
        "LOCAL BRIDGE SERVICE WORKER V1";
    private const string WorkerSchedule =
        "BEGIN:VEVENT\n" +
        "DTSTART:20300101T060000Z\n" +
        "RRULE:FREQ=DAILY;BYHOUR=6;BYMINUTE=0\n" +
        "END:VEVENT";

    private static readonly SemaphoreSlim WorkerGate = new(1, 1);
    private static string? _processWorkerId;

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

    public LocalIntentPlanner(WebView2 browser)
    {
        _browser = browser;
        _binding = new RequestBindingGuard(browser);
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

        await WorkerGate.WaitAsync(cancellationToken);
        try
        {
            return await PlanCoreAsync(instruction, cancellationToken);
        }
        finally
        {
            WorkerGate.Release();
        }
    }

    private async Task<BridgePlannedAction> PlanCoreAsync(
        string instruction,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        var settings = AppSettings.Load();
        var configuredWorkerId =
            !string.IsNullOrWhiteSpace(settings.LocalIntentWorkerAutomationId)
                ? settings.LocalIntentWorkerAutomationId!.Trim()
                : _processWorkerId;

        if (!string.IsNullOrWhiteSpace(configuredWorkerId) &&
            !IsOpaqueBackendId(configuredWorkerId))
        {
            throw new BridgeToolException(
                "private_transport_worker_state",
                "Stored Local Bridge worker id is invalid.");
        }

        if (settings.LocalIntentWorkerProvisioningUncertain &&
            string.IsNullOrWhiteSpace(configuredWorkerId))
        {
            throw new BridgeToolException(
                "private_transport_worker_uncertain",
                "A previous Local Bridge worker creation had an unknown outcome. Automatic recreation is blocked to avoid creating a duplicate service task.");
        }

        var binding = _binding.Capture();
        var targetThreadId = TryExtractConversationId(binding.DocumentUri);
        var probeId = "lb-" + Guid.NewGuid().ToString("N");
        var messageId = "msg-" + Guid.NewGuid().ToString("N");

        var payload = JsonSerializer.Serialize(new
        {
            instruction,
            probeId,
            messageId,
            networkMinGapMs = NetworkMinGapMs,
            workerId = configuredWorkerId ?? string.Empty,
            provisioningUncertain =
                settings.LocalIntentWorkerProvisioningUncertain,
            targetThreadId = targetThreadId ?? string.Empty,
            workerTitle = WorkerTitle,
            workerMarker = WorkerMarker,
            workerSchedule = WorkerSchedule
        });

        var asyncBody = """
            const p = PAYLOAD;
            const started = performance.now();
            const minGapMs = Math.max(5000, Number(p.networkMinGapMs || 5000));
            let lastRequestCompletedAt = null;
            let authorization = "";
            let accountId = "";
            let workerId =
              typeof p.workerId === 'string' ? p.workerId.trim() : '';
            let workerCreated = false;
            let provisioningUncertain =
              p.provisioningUncertain === true;

            const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

            async function beforeNetworkRequest() {
              if (lastRequestCompletedAt === null) return;
              const elapsed = performance.now() - lastRequestCompletedAt;
              const remaining = minGapMs - elapsed;
              if (remaining > 0) await delay(remaining);
            }

            async function rawFetch(path, options) {
              await beforeNetworkRequest();
              try {
                const response = await fetch(path, options);
                const text = await response.text();
                lastRequestCompletedAt = performance.now();
                return {
                  ok: response.ok,
                  status: response.status,
                  text,
                  error: null
                };
              } catch (error) {
                lastRequestCompletedAt = performance.now();
                return {
                  ok: false,
                  status: 0,
                  text: '',
                  error: String(error)
                };
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
                  r.status === 0
                    ? 'auth_session_network_' + String(r.error || 'failed')
                    : 'auth_session_http_' + r.status);
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
                throw new Error('auth_session_missing_access_token');
              }

              authorization = 'Bearer ' + accessToken;
            }

            async function api(method, path, body = null) {
              const headers = {
                'accept': 'application/json, text/plain, */*',
                'authorization': authorization
              };
              if (accountId) headers['chatgpt-account-id'] = accountId;

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

            function saveBody(current, prompt) {
              const body = {
                default_timezone:
                  current.default_timezone || 'UTC',
                email_enabled: false,
                is_enabled: false,
                jawbone_id: current.id,
                notifications_enabled: false,
                prompt,
                emoji: current.display_emoji,
                schedule:
                  typeof current.schedule === 'string' &&
                  current.schedule.length > 0
                    ? current.schedule
                    : p.workerSchedule,
                timing_mode: 0,
                title: p.workerTitle
              };
              if (current.model != null) body.model = current.model;
              if (current.reasoning_effort != null) {
                body.reasoning_effort = current.reasoning_effort;
              }
              return body;
            }

            function finalText(run) {
              return typeof run?.content_text === 'string'
                ? run.content_text.trim()
                : '';
            }

            function assertWorkerIdentity(worker) {
              if (!worker || typeof worker.id !== 'string') {
                throw new Error('worker_invalid_shape');
              }
              if (worker.id !== workerId) {
                throw new Error('worker_id_mismatch');
              }
              if (String(worker.title || '') !== p.workerTitle) {
                throw new Error('worker_title_mismatch');
              }
              if (
                typeof worker.prompt !== 'string' ||
                !worker.prompt.includes(p.workerMarker)
              ) {
                throw new Error('worker_marker_mismatch');
              }
            }

            async function readWorker(id) {
              const detail = await api(
                'GET',
                '/backend-api/automation/' +
                  encodeURIComponent(id));

              if (detail.status === 404) return null;

              if (!detail.ok || !detail.json) {
                throw new Error(
                  detail.status === 0
                    ? 'worker_read_network_' +
                      String(detail.error || 'failed')
                    : 'worker_read_http_' + detail.status);
              }

              return detail.json;
            }

            async function createWorker() {
              if (
                typeof p.targetThreadId !== 'string' ||
                !p.targetThreadId
              ) {
                throw new Error(
                  'worker_create_requires_current_conversation');
              }

              const created = await api(
                'POST',
                '/backend-api/automations/save',
                {
                  title: p.workerTitle,
                  prompt:
                    p.workerMarker +
                    '\nDedicated Local Bridge planner. ' +
                    'Remain disabled and do nothing unless Run Now is requested by Local Bridge.',
                  schedule: p.workerSchedule,
                  timing_mode: 0,
                  default_timezone: 'UTC',
                  executor: 'cloud',
                  is_enabled: false,
                  jawbone_id: null,
                  legacy_automation_id: null,
                  notification_policy: null,
                  notifications_enabled: false,
                  email_enabled: false,
                  target_thread_id: p.targetThreadId
                });

              if (!created.ok) {
                if (created.status === 0) {
                  provisioningUncertain = true;
                  throw new Error(
                    'worker_create_unknown_outcome_' +
                    String(created.error || 'network_failure'));
                }

                throw new Error(
                  'worker_create_http_' + created.status + '_' +
                  String(created.text || '').slice(0, 300));
              }

              workerId =
                typeof created.json?.id === 'string'
                  ? created.json.id
                  : typeof created.json?.jawbone_id === 'string'
                    ? created.json.jawbone_id
                    : '';

              if (!workerId) {
                provisioningUncertain = true;
                throw new Error('worker_create_id_missing');
              }

              workerCreated = true;
              provisioningUncertain = true;

              const worker = await readWorker(workerId);
              if (!worker) {
                throw new Error('worker_create_readback_missing');
              }

              assertWorkerIdentity(worker);
              provisioningUncertain = false;
              return worker;
            }

            try {
              await acquireAuth();

              let worker = null;

              if (workerId) {
                worker = await readWorker(workerId);

                if (!worker && provisioningUncertain) {
                  throw new Error(
                    'worker_state_uncertain_missing');
                }

                if (worker) {
                  assertWorkerIdentity(worker);
                  provisioningUncertain = false;
                } else {
                  workerId = '';
                }
              }

              if (!worker) {
                worker = await createWorker();
              }

              const marker =
                'PROBE_ID=' + p.probeId +
                ' MESSAGE_ID=' + p.messageId +
                ' ACTION_JSON=';

              const plannerPrompt = [
                p.workerMarker,
                'LOCAL BRIDGE ACTION PLANNER V2.',
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
              ].join('\n');

              const saved = await api(
                'POST',
                '/backend-api/automations/save',
                saveBody(worker, plannerPrompt));

              if (!saved.ok) {
                throw new Error(
                  saved.status === 0
                    ? 'worker_save_unknown_outcome_' +
                      String(saved.error || 'network_failure')
                    : 'worker_save_http_' + saved.status + '_' +
                      String(saved.text || '').slice(0, 300));
              }

              const run = await api(
                'POST',
                '/backend-api/automation/' +
                  encodeURIComponent(workerId) +
                  '/run',
                { idempotency_key: crypto.randomUUID() });

              if (!run.ok && run.status !== 0) {
                throw new Error(
                  'worker_run_http_' + run.status + '_' +
                  String(run.text || '').slice(0, 300));
              }

              await delay(8000);

              let latest = null;
              for (let attempt = 0; attempt < 5; attempt++) {
                const candidate = await api(
                  'GET',
                  '/backend-api/automation/' +
                    encodeURIComponent(workerId) +
                    '/latest_backing_run?include_snapshot=true');

                if (!candidate.ok) {
                  throw new Error(
                    candidate.status === 0
                      ? 'latest_run_network_' +
                        String(candidate.error || 'failed')
                      : 'latest_run_http_' + candidate.status);
                }

                const text = finalText(candidate.json);
                if (text.startsWith(marker)) {
                  latest = candidate.json;
                  break;
                }
              }

              if (!latest) {
                throw new Error(
                  run.status === 0
                    ? 'worker_run_unknown_outcome_not_correlated'
                    : 'latest_run_not_correlated');
              }

              return {
                ok: true,
                probeId: p.probeId,
                messageId: p.messageId,
                contentText: finalText(latest),
                runId: latest?.id ?? null,
                runCreatedAt: latest?.created_at ?? null,
                workerId,
                workerCreated,
                provisioningUncertain: false,
                elapsedMs: Math.round(performance.now() - started),
                error: null
              };
            } catch (error) {
              return {
                ok: false,
                probeId: p.probeId,
                messageId: p.messageId,
                contentText: '',
                runId: null,
                runCreatedAt: null,
                workerId: workerId || null,
                workerCreated,
                provisioningUncertain,
                elapsedMs: Math.round(performance.now() - started),
                error: String(error)
              };
            }
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

        if (result is not null)
        {
            PersistWorkerState(settings, result);
        }

        if (result is null || !result.Ok)
        {
            if (result?.ProvisioningUncertain == true &&
                string.IsNullOrWhiteSpace(result.WorkerId))
            {
                throw new BridgeToolException(
                    "private_transport_worker_uncertain",
                    "Local Bridge could not determine whether its dedicated service task was created. Automatic recreation is blocked to avoid duplicates.");
            }

            throw new BridgeToolException(
                "private_transport_failed",
                string.IsNullOrWhiteSpace(result?.Error)
                    ? "Server-side local action planning did not complete."
                    : result!.Error!);
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

    private static void PersistWorkerState(
        AppSettings settings,
        PlannerScriptResult result)
    {
        var changed = false;

        if (!string.IsNullOrWhiteSpace(result.WorkerId) &&
            IsOpaqueBackendId(result.WorkerId))
        {
            _processWorkerId = result.WorkerId;

            if (!string.Equals(
                    settings.LocalIntentWorkerAutomationId,
                    result.WorkerId,
                    StringComparison.Ordinal))
            {
                settings.LocalIntentWorkerAutomationId = result.WorkerId;
                changed = true;
            }
        }

        if (settings.LocalIntentWorkerProvisioningUncertain !=
            result.ProvisioningUncertain)
        {
            settings.LocalIntentWorkerProvisioningUncertain =
                result.ProvisioningUncertain;
            changed = true;
        }

        if (!changed)
        {
            return;
        }

        try
        {
            settings.Save();
        }
        catch (Exception ex)
        {
            throw new BridgeToolException(
                "private_transport_worker_state_persist_failed",
                "Local Bridge obtained a service worker state but could not persist it locally: " +
                ex.Message);
        }
    }

    private static string? TryExtractConversationId(string documentUri)
    {
        if (!Uri.TryCreate(documentUri, UriKind.Absolute, out var uri))
        {
            return null;
        }

        var segments = uri.AbsolutePath.Split(
            '/',
            StringSplitOptions.RemoveEmptyEntries);

        for (var index = 0; index + 1 < segments.Length; index++)
        {
            if (!string.Equals(
                    segments[index],
                    "c",
                    StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var candidate = segments[index + 1];
            return IsOpaqueBackendId(candidate)
                ? candidate
                : null;
        }

        return null;
    }

    private static bool IsOpaqueBackendId(string value)
    {
        var id = value.Trim();

        return id.Length is >= 1 and <= 200 &&
               id.All(ch =>
                   char.IsLetterOrDigit(ch) ||
                   ch is '-' or '_');
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
        public bool WorkerCreated { get; set; }
        public bool ProvisioningUncertain { get; set; }
        public long ElapsedMs { get; set; }
        public string? Error { get; set; }
    }
}
