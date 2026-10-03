using System.Diagnostics;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;

namespace ChatGptDesktopLocalBridge;

public enum UpdatePackageKind
{
    Delta,
    FullSetup
}

public sealed record ReleaseIdentity(
    string Tag,
    string Commit,
    string AppVersion);

public sealed record ReleaseAssetInfo(
    string Name,
    string DownloadUrl,
    string? Digest,
    long Size);

public sealed record UpdateCandidate(
    string CurrentTag,
    string TargetTag,
    UpdatePackageKind PackageKind,
    ReleaseAssetInfo SelectedAsset,
    ReleaseAssetInfo? FullSetupAsset,
    string Reason);

public sealed record UpdateResultRecord(
    DateTimeOffset Timestamp,
    string Status,
    string FromTag,
    string ToTag,
    string Message,
    bool RequiresFullSetup);

public static class UpdateService
{
    private const string ReleasesUrl =
        "https://api.github.com/repos/lvlaksim1/chatgpt-desktop-local-bridge/releases?per_page=50";

    private static string RootDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ChatGptDesktopLocalBridge",
        "updates");

    public static string LastResultPath =>
        Path.Combine(RootDirectory, "last-update-result.json");

    public static string HistoryPath =>
        Path.Combine(RootDirectory, "update-history.jsonl");

    public static string PendingPath =>
        Path.Combine(RootDirectory, "pending-update.json");

    public static ReleaseIdentity? LoadInstalledIdentity()
    {
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "release-info.json");
            if (!File.Exists(path))
            {
                return null;
            }

            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var root = document.RootElement;

            var tag = root.TryGetProperty("tag", out var tagElement)
                ? tagElement.GetString()
                : null;
            var commit = root.TryGetProperty("commit", out var commitElement)
                ? commitElement.GetString()
                : null;
            var version = root.TryGetProperty("appVersion", out var versionElement)
                ? versionElement.GetString()
                : null;

            if (string.IsNullOrWhiteSpace(tag))
            {
                return null;
            }

            return new ReleaseIdentity(
                tag,
                commit ?? string.Empty,
                version ?? string.Empty);
        }
        catch
        {
            return null;
        }
    }

    public static void ReconcilePendingUpdate()
    {
        try
        {
            Directory.CreateDirectory(RootDirectory);
            if (!File.Exists(PendingPath))
            {
                return;
            }

            var pending = JsonSerializer.Deserialize<PendingUpdateRecord>(
                File.ReadAllText(PendingPath));

            if (pending is null)
            {
                File.Delete(PendingPath);
                return;
            }

            var installed = LoadInstalledIdentity();
            if (string.Equals(
                    installed?.Tag,
                    pending.TargetTag,
                    StringComparison.Ordinal))
            {
                var last = GetLastResult();
                if (last is null ||
                    !string.Equals(last.ToTag, pending.TargetTag, StringComparison.Ordinal) ||
                    !string.Equals(last.Status, "success", StringComparison.OrdinalIgnoreCase))
                {
                    WriteResult(new UpdateResultRecord(
                        DateTimeOffset.Now,
                        "success",
                        pending.FromTag,
                        pending.TargetTag,
                        "Обновление установлено и подтверждено после перезапуска.",
                        false));
                }

                File.Delete(PendingPath);
                return;
            }

            var failed = GetLastResult();
            if (failed is not null &&
                string.Equals(failed.ToTag, pending.TargetTag, StringComparison.Ordinal) &&
                string.Equals(failed.Status, "failed", StringComparison.OrdinalIgnoreCase))
            {
                File.Delete(PendingPath);
                return;
            }

            if (DateTimeOffset.Now - pending.StartedAt > TimeSpan.FromMinutes(10))
            {
                WriteResult(new UpdateResultRecord(
                    DateTimeOffset.Now,
                    "failed",
                    pending.FromTag,
                    pending.TargetTag,
                    "Обновление не изменило установленную версию.",
                    pending.PackageKind == UpdatePackageKind.Delta));

                File.Delete(PendingPath);
            }
        }
        catch
        {
            // Update reconciliation must never block application startup.
        }
    }

    public static async Task<UpdateCandidate?> CheckAsync(
        CancellationToken cancellationToken = default)
    {
        var identity = LoadInstalledIdentity();
        if (identity is null)
        {
            return null;
        }

        using var client = CreateClient();
        using var response = await client.GetAsync(ReleasesUrl, cancellationToken);
        response.EnsureSuccessStatusCode();

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var document = await JsonDocument.ParseAsync(
            stream,
            cancellationToken: cancellationToken);

        var lastFailure = GetLastResult();

        foreach (var release in document.RootElement.EnumerateArray())
        {
            if (!IsUiPrerelease(release))
            {
                continue;
            }

            var targetTag = release.GetProperty("tag_name").GetString();
            if (string.IsNullOrWhiteSpace(targetTag) ||
                string.Equals(targetTag, identity.Tag, StringComparison.Ordinal))
            {
                continue;
            }

            var assets = ParseAssets(release);
            var deltaName =
                $"ChatGptDesktopLocalBridge-Update-from-{identity.Tag}.exe";
            var delta = assets.FirstOrDefault(asset =>
                string.Equals(asset.Name, deltaName, StringComparison.Ordinal));
            var full = assets.FirstOrDefault(asset =>
                string.Equals(
                    asset.Name,
                    "ChatGptDesktopLocalBridge-ui-shell-Setup.exe",
                    StringComparison.Ordinal));

            var forceFull =
                lastFailure is not null &&
                lastFailure.RequiresFullSetup &&
                string.Equals(lastFailure.ToTag, targetTag, StringComparison.Ordinal);

            if (!forceFull && delta is not null)
            {
                return new UpdateCandidate(
                    identity.Tag,
                    targetTag,
                    UpdatePackageKind.Delta,
                    delta,
                    full,
                    "Совместимый инкрементальный пакет для установленной версии.");
            }

            if (full is not null)
            {
                return new UpdateCandidate(
                    identity.Tag,
                    targetTag,
                    UpdatePackageKind.FullSetup,
                    full,
                    full,
                    forceFull
                        ? "Предыдущий delta-update сообщил о несовместимой базе. Будет использован полный Setup."
                        : "Для установленной версии нет точного delta-пакета. Будет использован полный Setup.");
            }
        }

        return null;
    }

    public static async Task<UpdateCandidate?> GetLatestFullSetupAsync(
        CancellationToken cancellationToken = default)
    {
        var identity = LoadInstalledIdentity()
                       ?? new ReleaseIdentity("unknown", string.Empty, string.Empty);

        using var client = CreateClient();
        using var response = await client.GetAsync(
            ReleasesUrl,
            cancellationToken);

        response.EnsureSuccessStatusCode();

        await using var stream =
            await response.Content.ReadAsStreamAsync(cancellationToken);

        using var document = await JsonDocument.ParseAsync(
            stream,
            cancellationToken: cancellationToken);

        foreach (var release in document.RootElement.EnumerateArray())
        {
            if (!IsUiPrerelease(release))
            {
                continue;
            }

            var targetTag =
                release.GetProperty("tag_name").GetString();

            if (string.IsNullOrWhiteSpace(targetTag))
            {
                continue;
            }

            var assets = ParseAssets(release);
            var full = assets.FirstOrDefault(asset =>
                string.Equals(
                    asset.Name,
                    "ChatGptDesktopLocalBridge-ui-shell-Setup.exe",
                    StringComparison.Ordinal));

            if (full is null)
            {
                continue;
            }

            return new UpdateCandidate(
                identity.Tag,
                targetTag,
                UpdatePackageKind.FullSetup,
                full,
                full,
                "Резервный полный установщик последнего UI-релиза.");
        }

        return null;
    }

    public static async Task<string> DownloadAndVerifyAsync(
        UpdateCandidate candidate,
        IProgress<double>? progress = null,
        CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(RootDirectory);

        var asset = candidate.SelectedAsset;
        if (string.IsNullOrWhiteSpace(asset.Digest) ||
            !asset.Digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                "GitHub release asset не содержит SHA-256 digest; установка отменена.");
        }

        var destination = Path.Combine(
            RootDirectory,
            Path.GetFileName(asset.Name));
        var temp = destination + ".download";

        using var client = CreateClient();
        using var response = await client.GetAsync(
            asset.DownloadUrl,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken);

        response.EnsureSuccessStatusCode();

        var total = response.Content.Headers.ContentLength;
        await using (var input = await response.Content.ReadAsStreamAsync(cancellationToken))
        await using (var output = new FileStream(
                         temp,
                         FileMode.Create,
                         FileAccess.Write,
                         FileShare.None,
                         81920,
                         useAsync: true))
        {
            var buffer = new byte[81920];
            long written = 0;

            while (true)
            {
                var read = await input.ReadAsync(buffer, cancellationToken);
                if (read == 0)
                {
                    break;
                }

                await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                written += read;

                if (total is > 0)
                {
                    progress?.Report((double)written / total.Value);
                }
            }
        }

        var expected = asset.Digest["sha256:".Length..]
            .Trim()
            .ToLowerInvariant();

        await using var file = File.OpenRead(temp);
        var actualBytes = await SHA256.HashDataAsync(file, cancellationToken);
        var actual = Convert.ToHexString(actualBytes).ToLowerInvariant();

        if (!string.Equals(expected, actual, StringComparison.Ordinal))
        {
            File.Delete(temp);
            throw new InvalidOperationException(
                "SHA-256 скачанного обновления не совпадает с GitHub release asset.");
        }

        File.Move(temp, destination, true);
        return destination;
    }

    public static void MarkPending(UpdateCandidate candidate)
    {
        Directory.CreateDirectory(RootDirectory);

        var pending = new PendingUpdateRecord(
            DateTimeOffset.Now,
            candidate.CurrentTag,
            candidate.TargetTag,
            candidate.PackageKind);

        File.WriteAllText(
            PendingPath,
            JsonSerializer.Serialize(
                pending,
                new JsonSerializerOptions { WriteIndented = true }));
    }

    public static UpdateResultRecord? GetLastResult()
    {
        try
        {
            if (!File.Exists(LastResultPath))
            {
                return null;
            }

            return JsonSerializer.Deserialize<UpdateResultRecord>(
                File.ReadAllText(LastResultPath),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        }
        catch
        {
            return null;
        }
    }

    public static string GetLastResultSummary()
    {
        var result = GetLastResult();
        if (result is null)
        {
            return "Обновления ещё не устанавливались из приложения.";
        }

        var status = string.Equals(
            result.Status,
            "success",
            StringComparison.OrdinalIgnoreCase)
            ? "Успешно"
            : "Ошибка";

        return $"{result.Timestamp.LocalDateTime:g} · {status}\n" +
               $"{result.FromTag} → {result.ToTag}\n{result.Message}";
    }

    public static string GetRecentHistoryText(int count = 5)
    {
        try
        {
            if (!File.Exists(HistoryPath))
            {
                return GetLastResultSummary();
            }

            var lines = File.ReadLines(HistoryPath)
                .Where(static line => !string.IsNullOrWhiteSpace(line))
                .TakeLast(Math.Clamp(count, 1, 20))
                .Select(line =>
                {
                    try
                    {
                        var item = JsonSerializer.Deserialize<UpdateResultRecord>(line);
                        if (item is null)
                        {
                            return null;
                        }

                        return $"{item.Timestamp.LocalDateTime:g} · {item.Status} · " +
                               $"{item.FromTag} → {item.ToTag}\n{item.Message}";
                    }
                    catch
                    {
                        return null;
                    }
                })
                .Where(static line => line is not null);

            return string.Join("\n\n", lines!);
        }
        catch
        {
            return GetLastResultSummary();
        }
    }

    public static void StartInstaller(string path)
    {
        Process.Start(new ProcessStartInfo(path)
        {
            UseShellExecute = true
        });
    }

    private static void WriteResult(UpdateResultRecord result)
    {
        Directory.CreateDirectory(RootDirectory);

        var json = JsonSerializer.Serialize(result);
        File.WriteAllText(
            LastResultPath,
            JsonSerializer.Serialize(
                result,
                new JsonSerializerOptions { WriteIndented = true }));
        File.AppendAllText(HistoryPath, json + Environment.NewLine);
    }

    private static bool IsUiPrerelease(JsonElement release)
        => release.TryGetProperty("prerelease", out var prerelease) &&
           prerelease.ValueKind == JsonValueKind.True &&
           release.TryGetProperty("tag_name", out var tag) &&
           tag.ValueKind == JsonValueKind.String &&
           (tag.GetString()?.StartsWith("ui-shell-", StringComparison.Ordinal) ?? false);

    private static List<ReleaseAssetInfo> ParseAssets(JsonElement release)
    {
        var result = new List<ReleaseAssetInfo>();

        if (!release.TryGetProperty("assets", out var assets) ||
            assets.ValueKind != JsonValueKind.Array)
        {
            return result;
        }

        foreach (var asset in assets.EnumerateArray())
        {
            var name = asset.TryGetProperty("name", out var n) ? n.GetString() : null;
            var url = asset.TryGetProperty("browser_download_url", out var u) ? u.GetString() : null;
            var digest = asset.TryGetProperty("digest", out var d) ? d.GetString() : null;
            var size = asset.TryGetProperty("size", out var s) && s.TryGetInt64(out var parsed)
                ? parsed
                : 0;

            if (!string.IsNullOrWhiteSpace(name) &&
                !string.IsNullOrWhiteSpace(url))
            {
                result.Add(new ReleaseAssetInfo(name, url, digest, size));
            }
        }

        return result;
    }

    private static HttpClient CreateClient()
    {
        var client = new HttpClient
        {
            Timeout = TimeSpan.FromMinutes(10)
        };

        client.DefaultRequestHeaders.UserAgent.Add(
            new ProductInfoHeaderValue("ChatGptDesktopLocalBridge", "1.0"));
        client.DefaultRequestHeaders.Accept.Add(
            new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        client.DefaultRequestHeaders.Add(
            "X-GitHub-Api-Version",
            "2022-11-28");

        return client;
    }

    private sealed record PendingUpdateRecord(
        DateTimeOffset StartedAt,
        string FromTag,
        string TargetTag,
        UpdatePackageKind PackageKind);
}
