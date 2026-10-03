using System.Diagnostics;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;

namespace ChatGptDesktopLocalBridge;

public sealed record ReleaseIdentity(
    string Tag,
    string Commit,
    string AppVersion);

public sealed record UpdateCandidate(
    string CurrentTag,
    string TargetTag,
    string AssetName,
    string DownloadUrl,
    string? Digest);

public static class UpdateService
{
    private const string ReleasesUrl =
        "https://api.github.com/repos/lvlaksim1/chatgpt-desktop-local-bridge/releases?per_page=50";

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
        using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);

        var expectedAsset = $"ChatGptDesktopLocalBridge-Update-from-{identity.Tag}.exe";

        foreach (var release in document.RootElement.EnumerateArray())
        {
            var prerelease =
                release.TryGetProperty("prerelease", out var prereleaseElement) &&
                prereleaseElement.ValueKind == JsonValueKind.True;

            if (!prerelease)
            {
                continue;
            }

            var targetTag = release.TryGetProperty("tag_name", out var tagElement)
                ? tagElement.GetString()
                : null;

            if (string.IsNullOrWhiteSpace(targetTag) ||
                !targetTag.StartsWith("ui-shell-", StringComparison.Ordinal) ||
                string.Equals(targetTag, identity.Tag, StringComparison.Ordinal))
            {
                continue;
            }

            if (!release.TryGetProperty("assets", out var assetsElement) ||
                assetsElement.ValueKind != JsonValueKind.Array)
            {
                continue;
            }

            foreach (var asset in assetsElement.EnumerateArray())
            {
                var name = asset.TryGetProperty("name", out var nameElement)
                    ? nameElement.GetString()
                    : null;

                if (!string.Equals(name, expectedAsset, StringComparison.Ordinal))
                {
                    continue;
                }

                var downloadUrl =
                    asset.TryGetProperty("browser_download_url", out var urlElement)
                        ? urlElement.GetString()
                        : null;

                if (string.IsNullOrWhiteSpace(downloadUrl))
                {
                    continue;
                }

                var digest = asset.TryGetProperty("digest", out var digestElement)
                    ? digestElement.GetString()
                    : null;

                return new UpdateCandidate(
                    identity.Tag,
                    targetTag,
                    name!,
                    downloadUrl,
                    digest);
            }
        }

        return null;
    }

    public static async Task<string> DownloadAndVerifyAsync(
        UpdateCandidate candidate,
        IProgress<double>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ChatGptDesktopLocalBridge",
            "updates");

        Directory.CreateDirectory(directory);

        var safeName = Path.GetFileName(candidate.AssetName);
        var destination = Path.Combine(directory, safeName);
        var temp = destination + ".download";

        using var client = CreateClient();
        using var response = await client.GetAsync(
            candidate.DownloadUrl,
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

        if (!string.IsNullOrWhiteSpace(candidate.Digest) &&
            candidate.Digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
        {
            var expected = candidate.Digest["sha256:".Length..].Trim().ToLowerInvariant();

            await using var file = File.OpenRead(temp);
            var actualBytes = await SHA256.HashDataAsync(file, cancellationToken);
            var actual = Convert.ToHexString(actualBytes).ToLowerInvariant();

            if (!string.Equals(expected, actual, StringComparison.Ordinal))
            {
                File.Delete(temp);
                throw new InvalidOperationException(
                    "SHA-256 скачанного обновления не совпадает с GitHub release asset.");
            }
        }

        File.Move(temp, destination, true);
        return destination;
    }

    public static void StartInstaller(string path)
    {
        Process.Start(new ProcessStartInfo(path)
        {
            UseShellExecute = true
        });
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

        client.DefaultRequestHeaders.Add("X-GitHub-Api-Version", "2022-11-28");
        return client;
    }
}
