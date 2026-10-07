using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace ChatGptDesktopLocalBridge.Bridge;

public sealed record ProcessRunSpec(
    string File,
    IReadOnlyList<string> Arguments,
    string? WorkingDirectory,
    int TimeoutMs,
    int MaxOutputChars);

public sealed record ProcessRunOutcome(
    string ExecutionId,
    string File,
    IReadOnlyList<string> Arguments,
    string? WorkingDirectory,
    int? ExitCode,
    string Stdout,
    string Stderr,
    bool StdoutTruncated,
    bool StderrTruncated,
    bool TimedOut,
    bool Stopped,
    bool Cancelled,
    long ElapsedMs,
    int TimeoutMs,
    int MaxOutputChars);

public sealed class ProcessExecutionManager : IDisposable
{
    private readonly ConcurrentDictionary<string, ActiveExecution> _active =
        new(StringComparer.Ordinal);

    public int ActiveCount => _active.Count;

    public IReadOnlyList<string> ActiveExecutionIds =>
        _active.Keys.OrderBy(value => value, StringComparer.Ordinal).ToArray();

    public async Task<ProcessRunOutcome> RunAsync(
        ProcessRunSpec spec,
        CancellationToken cancellationToken = default)
    {
        var executionId = Guid.NewGuid().ToString("N");
        var startInfo = new ProcessStartInfo
        {
            FileName = Environment.ExpandEnvironmentVariables(spec.File),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = false,
            CreateNoWindow = true
        };

        if (!string.IsNullOrWhiteSpace(spec.WorkingDirectory))
        {
            startInfo.WorkingDirectory = spec.WorkingDirectory;
        }

        foreach (var argument in spec.Arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = new Process { StartInfo = startInfo };
        var stopwatch = Stopwatch.StartNew();

        try
        {
            if (!process.Start())
            {
                throw new BridgeToolException(
                    "process_start_failed",
                    $"Could not start process: {spec.File}");
            }
        }
        catch (BridgeToolException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new BridgeToolException(
                "process_start_failed",
                $"Could not start process '{spec.File}': {ex.Message}");
        }

        WindowsJobObject? job = null;
        try
        {
            try
            {
                job = WindowsJobObject.CreateKillOnClose();
                job.Assign(process);
            }
            catch (Exception ex)
            {
                TryKillProcessTree(process);
                throw new BridgeToolException(
                    "process_containment_failed",
                    $"Process started but could not be attached to a Windows Job Object: {ex.Message}");
            }

            using var stopCts = new CancellationTokenSource();
            var active = new ActiveExecution(process, job, stopCts);
            if (!_active.TryAdd(executionId, active))
            {
                TryKillProcessTree(process);
                throw new BridgeToolException(
                    "process_tracking_failed",
                    "Could not register the active process execution.");
            }

            var stdoutTask = ReadCappedAsync(process.StandardOutput, spec.MaxOutputChars);
            var stderrTask = ReadCappedAsync(process.StandardError, spec.MaxOutputChars);

            var timedOut = false;
            var stopped = false;
            var cancelled = false;

            using var timeoutCts = spec.TimeoutMs > 0
                ? new CancellationTokenSource(spec.TimeoutMs)
                : new CancellationTokenSource();
            using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(
                timeoutCts.Token,
                stopCts.Token,
                cancellationToken);

            try
            {
                await process.WaitForExitAsync(linkedCts.Token);
            }
            catch (OperationCanceledException)
            {
                timedOut = timeoutCts.IsCancellationRequested &&
                           !stopCts.IsCancellationRequested &&
                           !cancellationToken.IsCancellationRequested;
                stopped = stopCts.IsCancellationRequested;
                cancelled = cancellationToken.IsCancellationRequested;

                try
                {
                    job.Terminate(1);
                }
                catch
                {
                    TryKillProcessTree(process);
                }

                try
                {
                    await process.WaitForExitAsync()
                        .WaitAsync(TimeSpan.FromSeconds(5));
                }
                catch
                {
                    TryKillProcessTree(process);
                }
            }
            finally
            {
                _active.TryRemove(executionId, out _);
            }

            var stdout = await stdoutTask;
            var stderr = await stderrTask;
            stopwatch.Stop();

            int? exitCode = null;
            try
            {
                if (process.HasExited)
                {
                    exitCode = process.ExitCode;
                }
            }
            catch
            {
                // The process may have disappeared between observation and ExitCode access.
            }

            return new ProcessRunOutcome(
                executionId,
                spec.File,
                spec.Arguments,
                spec.WorkingDirectory,
                exitCode,
                stdout.Text,
                stderr.Text,
                stdout.Truncated,
                stderr.Truncated,
                timedOut,
                stopped,
                cancelled,
                stopwatch.ElapsedMilliseconds,
                spec.TimeoutMs,
                spec.MaxOutputChars);
        }
        finally
        {
            job?.Dispose();
        }
    }

    public bool Stop(string executionId)
    {
        if (!_active.TryGetValue(executionId, out var active))
        {
            return false;
        }

        active.StopCts.Cancel();

        try
        {
            active.Job.Terminate(1);
        }
        catch
        {
            TryKillProcessTree(active.Process);
        }

        return true;
    }

    public int StopAll()
    {
        var executions = _active.ToArray();
        var stopped = 0;

        foreach (var pair in executions)
        {
            if (Stop(pair.Key))
            {
                stopped++;
            }
        }

        return stopped;
    }

    public void Dispose()
    {
        StopAll();
        foreach (var active in _active.Values)
        {
            active.StopCts.Dispose();
            active.Job.Dispose();
        }

        _active.Clear();
    }

    private static async Task<CappedTextResult> ReadCappedAsync(
        StreamReader reader,
        int maxChars)
    {
        var builder = new StringBuilder(Math.Min(maxChars, 16_384));
        var buffer = new char[8_192];
        var truncated = false;

        while (true)
        {
            var read = await reader.ReadAsync(buffer, 0, buffer.Length);
            if (read <= 0)
            {
                break;
            }

            var remaining = maxChars - builder.Length;
            if (remaining > 0)
            {
                builder.Append(buffer, 0, Math.Min(read, remaining));
            }

            if (read > remaining)
            {
                truncated = true;
            }
        }

        return new CappedTextResult(builder.ToString(), truncated);
    }

    private static void TryKillProcessTree(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch
        {
            // Last-resort best effort only.
        }
    }

    private sealed record CappedTextResult(string Text, bool Truncated);

    private sealed record ActiveExecution(
        Process Process,
        WindowsJobObject Job,
        CancellationTokenSource StopCts);
}

internal sealed class WindowsJobObject : IDisposable
{
    private const uint JobObjectLimitKillOnJobClose = 0x00002000;
    private IntPtr _handle;

    private WindowsJobObject(IntPtr handle)
    {
        _handle = handle;
    }

    public static WindowsJobObject CreateKillOnClose()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Windows Job Objects require Windows.");
        }

        var handle = CreateJobObject(IntPtr.Zero, null);
        if (handle == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed.");
        }

        var job = new WindowsJobObject(handle);
        try
        {
            var info = new JobObjectExtendedLimitInformation
            {
                BasicLimitInformation = new JobObjectBasicLimitInformation
                {
                    LimitFlags = JobObjectLimitKillOnJobClose
                }
            };

            var length = Marshal.SizeOf<JobObjectExtendedLimitInformation>();
            var pointer = Marshal.AllocHGlobal(length);
            try
            {
                Marshal.StructureToPtr(info, pointer, false);
                if (!SetInformationJobObject(
                        handle,
                        JobObjectInfoType.ExtendedLimitInformation,
                        pointer,
                        (uint)length))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "SetInformationJobObject failed.");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(pointer);
            }

            return job;
        }
        catch
        {
            job.Dispose();
            throw;
        }
    }

    public void Assign(Process process)
    {
        Assign(process.Handle);
    }

    public void Assign(IntPtr processHandle)
    {
        ThrowIfDisposed();

        if (processHandle == IntPtr.Zero)
        {
            throw new ArgumentException("Process handle must not be null.", nameof(processHandle));
        }

        if (!AssignProcessToJobObject(_handle, processHandle))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "AssignProcessToJobObject failed.");
        }
    }

    public void Terminate(uint exitCode)
    {
        ThrowIfDisposed();

        if (!TerminateJobObject(_handle, exitCode))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "TerminateJobObject failed.");
        }
    }

    public void Dispose()
    {
        var handle = Interlocked.Exchange(ref _handle, IntPtr.Zero);
        if (handle != IntPtr.Zero)
        {
            CloseHandle(handle);
        }
    }

    private void ThrowIfDisposed()
    {
        if (_handle == IntPtr.Zero)
        {
            throw new ObjectDisposedException(nameof(WindowsJobObject));
        }
    }

    private enum JobObjectInfoType
    {
        ExtendedLimitInformation = 9
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformation
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr job,
        JobObjectInfoType infoType,
        IntPtr jobObjectInfo,
        uint jobObjectInfoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
}