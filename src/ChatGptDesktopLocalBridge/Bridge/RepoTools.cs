using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ChatGptDesktopLocalBridge.Bridge;

public sealed class RepoTools
{
    private const int DefaultGitOutputChars = 200_000;
    private const int MaxMapSourceCharsPerFile = 200_000;
    private const long MaxCheckpointUntrackedFileBytes = 1_048_576;
    private const long MaxCheckpointUntrackedTotalBytes = 10_485_760;

    private static readonly HashSet<string> TextExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".cs", ".xaml", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx",
        ".py", ".ps1", ".psm1", ".psd1", ".json", ".jsonc", ".md",
        ".yml", ".yaml", ".xml", ".props", ".targets", ".toml", ".ini",
        ".cpp", ".c", ".h", ".hpp", ".java", ".kt", ".kts", ".go", ".rs",
        ".rb", ".php", ".swift", ".sql", ".sh", ".cmd", ".bat"
    };

    private static readonly Regex SymbolLinePattern = new(
        @"^\s*(?:(?:public|private|protected|internal|static|sealed|partial|abstract|async|export|default)\s+)*(?:(?:class|record|interface|enum|struct|namespace|function|def|func|fn)\s+[A-Za-z_$][\w$]*|function\s+[A-Za-z_$][\w$]*|(?:[A-Za-z_][\w<>,.?\[\]\s]*\s+)+[A-Za-z_][\w]*\s*\([^;]*\)\s*(?:=>|\{|$)|function\s+[A-Za-z_][\w-]*|[A-Za-z_][\w-]*\s*:\s*function)",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private readonly ProcessExecutionManager _processes;

    public RepoTools(ProcessExecutionManager processes)
    {
        _processes = processes;
    }

    public async Task<object> StatusAsync(string path, CancellationToken cancellationToken = default)
    {
        var root = await ResolveRepositoryRootAsync(path, cancellationToken);
        var status = await RunGitAsync(
            root,
            ["status", "--short", "--branch", "--untracked-files=all"],
            DefaultGitOutputChars,
            cancellationToken);
        var head = await RunGitAsync(root, ["rev-parse", "HEAD"], 4096, cancellationToken);
        var branch = await RunGitAsync(
            root,
            ["rev-parse", "--abbrev-ref", "HEAD"],
            4096,
            cancellationToken);

        return new
        {
            root,
            branch = branch.Stdout.Trim(),
            head = head.Stdout.Trim(),
            status = status.Stdout,
            clean = string.IsNullOrWhiteSpace(
                string.Join(
                    Environment.NewLine,
                    status.Stdout.Split(
                        ['\r', '\n'],
                        StringSplitOptions.RemoveEmptyEntries)
                    .Where(line => !line.StartsWith("## ", StringComparison.Ordinal)))),
            elapsedMs = status.ElapsedMs + head.ElapsedMs + branch.ElapsedMs
        };
    }

    public async Task<object> DiffAsync(
        string path,
        bool staged,
        int maxChars,
        CancellationToken cancellationToken = default)
    {
        var root = await ResolveRepositoryRootAsync(path, cancellationToken);
        var arguments = new List<string> { "diff", "--no-ext-diff", "--no-color" };
        if (staged)
        {
            arguments.Add("--cached");
        }

        var diff = await RunGitAsync(root, arguments, maxChars, cancellationToken);

        return new
        {
            root,
            staged,
            diff = diff.Stdout,
            truncated = diff.StdoutTruncated,
            exitCode = diff.ExitCode,
            elapsedMs = diff.ElapsedMs
        };
    }

    public async Task<object> MapAsync(
        string path,
        string query,
        int maxFiles,
        int maxChars,
        CancellationToken cancellationToken = default)
    {
        var root = await ResolveRepositoryRootAsync(path, cancellationToken);
        var listed = await RunGitAsync(
            root,
            ["ls-files", "-co", "--exclude-standard"],
            1_000_000,
            cancellationToken);

        var files = listed.Stdout
            .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Where(IsMapCandidate)
            .Take(2_000)
            .ToArray();

        var terms = query
            .Split(
                [' ', '\t', '\r', '\n', '.', '/', '\\', ':', ';', ',', '(', ')', '[', ']', '{', '}'],
                StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(term => term.Length >= 2)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(16)
            .ToArray();

        var ranked = new List<RepoMapEntry>();

        foreach (var relativePath in files)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var fullPath = Path.Combine(root, relativePath.Replace('/', Path.DirectorySeparatorChar));
            FileInfo info;
            try
            {
                info = new FileInfo(fullPath);
                if (!info.Exists || info.Length > 1_048_576)
                {
                    continue;
                }
            }
            catch
            {
                continue;
            }

            string text;
            try
            {
                using var reader = new StreamReader(fullPath, detectEncodingFromByteOrderMarks: true);
                var buffer = new char[MaxMapSourceCharsPerFile + 1];
                var count = await reader.ReadBlockAsync(buffer, 0, buffer.Length);
                text = new string(buffer, 0, Math.Min(count, MaxMapSourceCharsPerFile));
            }
            catch
            {
                continue;
            }

            var symbols = ExtractSymbols(text);
            var score = Score(relativePath, text, symbols, terms);
            ranked.Add(new RepoMapEntry(relativePath, score, symbols));
        }

        var selected = ranked
            .OrderByDescending(entry => entry.Score)
            .ThenBy(entry => entry.Path, StringComparer.OrdinalIgnoreCase)
            .Take(maxFiles)
            .ToArray();

        var builder = new StringBuilder(Math.Min(maxChars, 32_768));
        builder.AppendLine($"Repository: {root}");
        if (!string.IsNullOrWhiteSpace(query))
        {
            builder.AppendLine($"Query: {query}");
        }

        builder.AppendLine($"Indexed text files: {ranked.Count}; selected: {selected.Length}");
        builder.AppendLine();

        var truncated = false;
        foreach (var entry in selected)
        {
            var header = entry.Symbols.Count == 0
                ? entry.Path
                : entry.Path + Environment.NewLine +
                  string.Join(
                      Environment.NewLine,
                      entry.Symbols.Take(24).Select(symbol => "  " + symbol));

            if (builder.Length + header.Length + 2 > maxChars)
            {
                truncated = true;
                break;
            }

            builder.AppendLine(header);
            builder.AppendLine();
        }

        return new
        {
            root,
            query,
            map = builder.ToString(),
            indexedFiles = ranked.Count,
            selectedFiles = selected.Length,
            truncated,
            maxChars
        };
    }

    public async Task<object> CheckpointAsync(
        string path,
        CancellationToken cancellationToken = default)
    {
        var root = await ResolveRepositoryRootAsync(path, cancellationToken);
        var status = await RunGitAsync(
            root,
            ["status", "--short", "--branch", "--untracked-files=all"],
            500_000,
            cancellationToken);
        var diff = await RunGitAsync(
            root,
            ["diff", "--no-ext-diff", "--no-color"],
            2_000_000,
            cancellationToken);
        var staged = await RunGitAsync(
            root,
            ["diff", "--cached", "--no-ext-diff", "--no-color"],
            2_000_000,
            cancellationToken);
        var head = await RunGitAsync(root, ["rev-parse", "HEAD"], 4096, cancellationToken);

        var rootHash = Convert.ToHexString(
                SHA256.HashData(Encoding.UTF8.GetBytes(root)))
            .ToLowerInvariant()[..16];
        var checkpointId =
            DateTimeOffset.UtcNow.ToString("yyyyMMdd-HHmmss-fff") + "-" +
            Guid.NewGuid().ToString("N")[..8];
        var checkpointRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ChatGptDesktopLocalBridge",
            "state",
            "repo-checkpoints",
            rootHash,
            checkpointId);

        Directory.CreateDirectory(checkpointRoot);
        await File.WriteAllTextAsync(
            Path.Combine(checkpointRoot, "status.txt"),
            status.Stdout,
            cancellationToken);
        await File.WriteAllTextAsync(
            Path.Combine(checkpointRoot, "working.diff"),
            diff.Stdout,
            cancellationToken);
        await File.WriteAllTextAsync(
            Path.Combine(checkpointRoot, "staged.diff"),
            staged.Stdout,
            cancellationToken);

        var copiedUntracked = new List<string>();
        var skippedUntracked = new List<string>();
        long copiedBytes = 0;

        foreach (var line in status.Stdout.Split(
                     ['\r', '\n'],
                     StringSplitOptions.RemoveEmptyEntries))
        {
            if (!line.StartsWith("?? ", StringComparison.Ordinal) || line.Length <= 3)
            {
                continue;
            }

            var relative = line[3..].Trim();
            var source = Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));

            try
            {
                var info = new FileInfo(source);
                if (!info.Exists ||
                    info.Length > MaxCheckpointUntrackedFileBytes ||
                    copiedBytes + info.Length > MaxCheckpointUntrackedTotalBytes)
                {
                    skippedUntracked.Add(relative);
                    continue;
                }

                var destination = Path.Combine(
                    checkpointRoot,
                    "untracked",
                    relative.Replace('/', Path.DirectorySeparatorChar));
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                File.Copy(source, destination, overwrite: false);
                copiedBytes += info.Length;
                copiedUntracked.Add(relative);
            }
            catch
            {
                skippedUntracked.Add(relative);
            }
        }

        var metadata = new
        {
            schema = "local-bridge-repo-checkpoint-v1",
            checkpointId,
            createdUtc = DateTimeOffset.UtcNow,
            repositoryRoot = root,
            head = head.Stdout.Trim(),
            copiedUntracked,
            skippedUntracked,
            copiedUntrackedBytes = copiedBytes,
            workingDiffTruncated = diff.StdoutTruncated,
            stagedDiffTruncated = staged.StdoutTruncated
        };

        await File.WriteAllTextAsync(
            Path.Combine(checkpointRoot, "metadata.json"),
            JsonSerializer.Serialize(
                metadata,
                new JsonSerializerOptions { WriteIndented = true }),
            cancellationToken);

        return new
        {
            checkpointId,
            repositoryRoot = root,
            checkpointPath = checkpointRoot,
            head = head.Stdout.Trim(),
            copiedUntrackedCount = copiedUntracked.Count,
            skippedUntrackedCount = skippedUntracked.Count,
            copiedUntrackedBytes = copiedBytes
        };
    }

    public async Task<object> VerifyAsync(
        string path,
        string file,
        IReadOnlyList<string> arguments,
        int timeoutMs,
        int maxOutputChars,
        CancellationToken cancellationToken = default)
    {
        var root = await ResolveRepositoryRootAsync(path, cancellationToken);
        var outcome = await _processes.RunAsync(
            new ProcessRunSpec(
                file,
                arguments,
                root,
                timeoutMs,
                maxOutputChars),
            cancellationToken);

        return new
        {
            root,
            outcome.ExecutionId,
            outcome.File,
            outcome.Arguments,
            cwd = outcome.WorkingDirectory,
            outcome.ExitCode,
            stdout = outcome.Stdout,
            stderr = outcome.Stderr,
            outcome.StdoutTruncated,
            outcome.StderrTruncated,
            outcome.TimedOut,
            outcome.Stopped,
            outcome.Cancelled,
            outcome.ElapsedMs,
            ok = outcome.ExitCode == 0 &&
                 !outcome.TimedOut &&
                 !outcome.Stopped &&
                 !outcome.Cancelled
        };
    }

    private async Task<string> ResolveRepositoryRootAsync(
        string path,
        CancellationToken cancellationToken)
    {
        var fullPath = Path.GetFullPath(Environment.ExpandEnvironmentVariables(path));
        var cwd = Directory.Exists(fullPath)
            ? fullPath
            : Path.GetDirectoryName(fullPath);

        if (string.IsNullOrWhiteSpace(cwd) || !Directory.Exists(cwd))
        {
            throw new BridgeToolException(
                "directory_not_found",
                $"Repository path does not exist: {fullPath}");
        }

        var root = await _processes.RunAsync(
            new ProcessRunSpec(
                "git.exe",
                ["rev-parse", "--show-toplevel"],
                cwd,
                30_000,
                16_384),
            cancellationToken);

        if (root.ExitCode != 0 ||
            root.TimedOut ||
            root.Stopped ||
            root.Cancelled ||
            string.IsNullOrWhiteSpace(root.Stdout))
        {
            throw new BridgeToolException(
                "not_git_repository",
                $"Could not resolve a Git repository from '{fullPath}': {root.Stderr.Trim()}");
        }

        return Path.GetFullPath(root.Stdout.Trim());
    }

    private async Task<ProcessRunOutcome> RunGitAsync(
        string root,
        IReadOnlyList<string> arguments,
        int maxOutputChars,
        CancellationToken cancellationToken)
    {
        var outcome = await _processes.RunAsync(
            new ProcessRunSpec(
                "git.exe",
                arguments,
                root,
                60_000,
                maxOutputChars),
            cancellationToken);

        if (outcome.TimedOut)
        {
            throw new BridgeToolException("git_timeout", "Git command timed out.");
        }

        if (outcome.Stopped || outcome.Cancelled)
        {
            throw new BridgeToolException("git_cancelled", "Git command was cancelled.");
        }

        if (outcome.ExitCode != 0)
        {
            throw new BridgeToolException(
                "git_failed",
                string.IsNullOrWhiteSpace(outcome.Stderr)
                    ? $"Git command failed with exit code {outcome.ExitCode}."
                    : outcome.Stderr.Trim());
        }

        return outcome;
    }

    private static bool IsMapCandidate(string relativePath)
    {
        var extension = Path.GetExtension(relativePath);
        return TextExtensions.Contains(extension);
    }

    private static IReadOnlyList<string> ExtractSymbols(string text)
    {
        var symbols = new List<string>();
        foreach (var rawLine in text.Split('\n'))
        {
            if (symbols.Count >= 64)
            {
                break;
            }

            var line = rawLine.TrimEnd('\r');
            var trimmed = line.Trim();
            if (trimmed.Length == 0 || trimmed.Length > 240)
            {
                continue;
            }

            if (SymbolLinePattern.IsMatch(line))
            {
                symbols.Add(trimmed);
            }
        }

        return symbols;
    }

    private static int Score(
        string relativePath,
        string text,
        IReadOnlyList<string> symbols,
        IReadOnlyList<string> terms)
    {
        var score = Math.Min(symbols.Count, 20);

        if (relativePath.EndsWith("README.md", StringComparison.OrdinalIgnoreCase) ||
            relativePath.EndsWith(".sln", StringComparison.OrdinalIgnoreCase) ||
            relativePath.EndsWith(".csproj", StringComparison.OrdinalIgnoreCase))
        {
            score += 10;
        }

        foreach (var term in terms)
        {
            if (relativePath.Contains(term, StringComparison.OrdinalIgnoreCase))
            {
                score += 40;
            }

            foreach (var symbol in symbols)
            {
                if (symbol.Contains(term, StringComparison.OrdinalIgnoreCase))
                {
                    score += 16;
                }
            }

            var index = 0;
            var hits = 0;
            while (hits < 10 &&
                   (index = text.IndexOf(term, index, StringComparison.OrdinalIgnoreCase)) >= 0)
            {
                score += 2;
                hits++;
                index += term.Length;
            }
        }

        return score;
    }

    private sealed record RepoMapEntry(
        string Path,
        int Score,
        IReadOnlyList<string> Symbols);
}