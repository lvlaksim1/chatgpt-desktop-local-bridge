using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace ChatGptDesktopLocalBridge.Bridge;

public sealed record TerminalOpenSpec(
    string File,
    IReadOnlyList<string> Arguments,
    string? WorkingDirectory,
    int Columns,
    int Rows);

public sealed record TerminalOpenOutcome(
    string SessionId,
    int ProcessId,
    string File,
    IReadOnlyList<string> Arguments,
    string? WorkingDirectory,
    int Columns,
    int Rows,
    long Cursor);

public sealed record TerminalReadOutcome(
    string SessionId,
    string Text,
    long Cursor,
    long NextCursor,
    long BaseCursor,
    bool TruncatedBeforeCursor,
    bool Running,
    int? ExitCode);

public sealed record TerminalStatusOutcome(
    string SessionId,
    int ProcessId,
    string File,
    string? WorkingDirectory,
    bool Running,
    int? ExitCode,
    int Columns,
    int Rows,
    long BaseCursor,
    long EndCursor,
    DateTimeOffset CreatedUtc,
    DateTimeOffset LastActivityUtc);

public sealed record TerminalCloseOutcome(
    string SessionId,
    bool AlreadyClosed,
    int? ExitCode);

/// <summary>
/// Owns persistent Windows pseudo-console sessions. A session is a real ConPTY-backed
/// terminal, so shell working directory, environment and interactive state survive
/// across bridge requests.
/// </summary>
public sealed class TerminalSessionManager : IDisposable
{
    private const int MaxSessions = 8;
    private const int MaxWriteBytes = 65_536;
    private const int RingBytes = 512 * 1024;

    private readonly ConcurrentDictionary<string, TerminalSession> _sessions =
        new(StringComparer.Ordinal);

    public int ActiveCount => _sessions.Values.Count(session => session.Running);

    public async Task<TerminalOpenOutcome> OpenAsync(
        TerminalOpenSpec spec,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (_sessions.Values.Count(session => session.Running) >= MaxSessions)
        {
            throw new BridgeToolException(
                "terminal_limit_reached",
                $"At most {MaxSessions} terminal sessions may be active at once.");
        }

        var sessionId = Guid.NewGuid().ToString("N");
        TerminalSession session;
        try
        {
            session = TerminalSession.Start(sessionId, spec);
        }
        catch (BridgeToolException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new BridgeToolException(
                "terminal_start_failed",
                $"Could not start terminal '{spec.File}': {ex.Message}");
        }

        if (!_sessions.TryAdd(sessionId, session))
        {
            session.Dispose();
            throw new BridgeToolException(
                "terminal_tracking_failed",
                "Could not register the terminal session.");
        }

        await Task.Yield();
        return session.OpenOutcome;
    }

    public async Task<object> WriteAsync(
        string sessionId,
        string data,
        CancellationToken cancellationToken = default)
    {
        var session = GetSession(sessionId);
        var bytes = Encoding.UTF8.GetByteCount(data);
        if (bytes > MaxWriteBytes)
        {
            throw new BridgeToolException(
                "terminal_input_too_large",
                $"Terminal input is {bytes} bytes; maximum is {MaxWriteBytes} bytes.");
        }

        await session.WriteAsync(data, cancellationToken);
        return new
        {
            sessionId,
            bytesWritten = bytes,
            cursor = session.EndCursor,
            running = session.Running
        };
    }

    public Task<TerminalReadOutcome> ReadAsync(
        string sessionId,
        long cursor,
        int maxBytes,
        int waitMs,
        bool stripAnsi,
        bool collapseCarriageReturns,
        CancellationToken cancellationToken = default)
    {
        var session = GetSession(sessionId);
        return session.ReadAsync(
            cursor,
            maxBytes,
            waitMs,
            stripAnsi,
            collapseCarriageReturns,
            cancellationToken);
    }

    public TerminalStatusOutcome Status(string sessionId)
        => GetSession(sessionId).Status();

    public IReadOnlyList<TerminalStatusOutcome> List()
        => _sessions.Values
            .Select(session => session.Status())
            .OrderBy(session => session.CreatedUtc)
            .ThenBy(session => session.SessionId, StringComparer.Ordinal)
            .ToArray();

    public object Resize(string sessionId, int columns, int rows)
    {
        var session = GetSession(sessionId);
        session.Resize(columns, rows);
        return new
        {
            sessionId,
            columns,
            rows,
            running = session.Running
        };
    }

    public async Task<TerminalCloseOutcome> CloseAsync(
        string sessionId,
        bool force,
        CancellationToken cancellationToken = default)
    {
        var session = GetSession(sessionId);
        return await session.CloseAsync(force, cancellationToken);
    }

    public int StopAll()
    {
        var stopped = 0;
        foreach (var session in _sessions.Values)
        {
            if (!session.Running)
            {
                continue;
            }

            try
            {
                session.CloseAsync(force: true, CancellationToken.None)
                    .GetAwaiter()
                    .GetResult();
                stopped++;
            }
            catch
            {
                // Best effort during global STOP/disposal.
            }
        }

        return stopped;
    }

    public void Dispose()
    {
        StopAll();

        foreach (var session in _sessions.Values)
        {
            session.Dispose();
        }

        _sessions.Clear();
    }

    private TerminalSession GetSession(string sessionId)
    {
        if (string.IsNullOrWhiteSpace(sessionId) ||
            !_sessions.TryGetValue(sessionId, out var session))
        {
            throw new BridgeToolException(
                "terminal_not_found",
                $"Terminal session does not exist: {sessionId}");
        }

        return session;
    }

    private sealed class TerminalSession : IDisposable
    {
        private static readonly Regex AnsiCsi = new(
            @"\x1B\[[0-?]*[ -/]*[@-~]",
            RegexOptions.Compiled | RegexOptions.CultureInvariant);

        private readonly object _sync = new();
        private readonly SemaphoreSlim _writeGate = new(1, 1);
        private readonly List<byte> _ring = new(RingBytes);
        private readonly CancellationTokenSource _readerCancellation = new();
        private readonly FileStream _input;
        private readonly FileStream _output;
        private readonly Process _process;
        private readonly WindowsJobObject _job;
        private readonly Task _readerTask;
        private TaskCompletionSource<bool> _outputChanged =
            NewOutputSignal();

        private IntPtr _pseudoConsole;
        private IntPtr _inputHostSide;
        private IntPtr _outputHostSide;
        private long _baseCursor;
        private bool _closed;
        private int _columns;
        private int _rows;
        private DateTimeOffset _lastActivityUtc;
        private int? _exitCode;

        private TerminalSession(
            string sessionId,
            TerminalOpenSpec spec,
            IntPtr pseudoConsole,
            IntPtr inputHostSide,
            IntPtr outputHostSide,
            Process process,
            WindowsJobObject job)
        {
            SessionId = sessionId;
            File = spec.File;
            Arguments = spec.Arguments.ToArray();
            WorkingDirectory = spec.WorkingDirectory;
            CreatedUtc = DateTimeOffset.UtcNow;
            _lastActivityUtc = CreatedUtc;
            _columns = spec.Columns;
            _rows = spec.Rows;
            _pseudoConsole = pseudoConsole;
            _inputHostSide = inputHostSide;
            _outputHostSide = outputHostSide;
            _process = process;
            _job = job;

            _input = new FileStream(
                new SafeFileHandle(_inputHostSide, ownsHandle: false),
                FileAccess.Write,
                bufferSize: 4096,
                isAsync: true);
            _output = new FileStream(
                new SafeFileHandle(_outputHostSide, ownsHandle: false),
                FileAccess.Read,
                bufferSize: 4096,
                isAsync: true);

            _process.EnableRaisingEvents = true;
            _process.Exited += (_, _) =>
            {
                TaskCompletionSource<bool> signal;
                lock (_sync)
                {
                    TryCaptureExitCodeLocked();
                    signal = SignalOutputChangedLocked();
                }

                signal.TrySetResult(true);
            };

            _readerTask = Task.Run(ReadLoopAsync);
        }

        public string SessionId { get; }

        public string File { get; }

        public IReadOnlyList<string> Arguments { get; }

        public string? WorkingDirectory { get; }

        public DateTimeOffset CreatedUtc { get; }

        public bool Running
        {
            get
            {
                lock (_sync)
                {
                    return !_closed && !HasExitedLocked();
                }
            }
        }

        public long EndCursor
        {
            get
            {
                lock (_sync)
                {
                    return _baseCursor + _ring.Count;
                }
            }
        }

        public TerminalOpenOutcome OpenOutcome => new(
            SessionId,
            _process.Id,
            File,
            Arguments,
            WorkingDirectory,
            _columns,
            _rows,
            0);

        public static TerminalSession Start(
            string sessionId,
            TerminalOpenSpec spec)
        {
            if (!OperatingSystem.IsWindows())
            {
                throw new BridgeToolException(
                    "terminal_unsupported",
                    "Persistent terminals require Windows ConPTY.");
            }

            IntPtr inputPseudoSide = IntPtr.Zero;
            IntPtr inputHostSide = IntPtr.Zero;
            IntPtr outputHostSide = IntPtr.Zero;
            IntPtr outputPseudoSide = IntPtr.Zero;
            IntPtr pseudoConsole = IntPtr.Zero;
            IntPtr attributeList = IntPtr.Zero;
            IntPtr jobList = IntPtr.Zero;
            IntPtr processHandle = IntPtr.Zero;
            IntPtr threadHandle = IntPtr.Zero;
            WindowsJobObject? job = null;

            try
            {
                (inputPseudoSide, inputHostSide) =
                    CreateConPtyPipe(callerReads: false);
                (outputPseudoSide, outputHostSide) =
                    CreateConPtyPipe(callerReads: true);

                var hr = Native.CreatePseudoConsole(
                    new Native.Coord((short)spec.Columns, (short)spec.Rows),
                    inputPseudoSide,
                    outputPseudoSide,
                    0,
                    out pseudoConsole);

                if (hr != 0)
                {
                    Marshal.ThrowExceptionForHR(hr);
                }

                job = WindowsJobObject.CreateKillOnClose();

                var attributeListSize = IntPtr.Zero;
                _ = Native.InitializeProcThreadAttributeList(
                    IntPtr.Zero,
                    2,
                    0,
                    ref attributeListSize);

                attributeList = Marshal.AllocHGlobal(attributeListSize);
                if (!Native.InitializeProcThreadAttributeList(
                        attributeList,
                        2,
                        0,
                        ref attributeListSize))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "InitializeProcThreadAttributeList failed.");
                }

                if (!Native.UpdateProcThreadAttribute(
                        attributeList,
                        0,
                        (IntPtr)Native.ProcThreadAttributePseudoConsole,
                        pseudoConsole,
                        (IntPtr)IntPtr.Size,
                        IntPtr.Zero,
                        IntPtr.Zero))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "UpdateProcThreadAttribute for ConPTY failed.");
                }

                jobList = Marshal.AllocHGlobal(IntPtr.Size);
                Marshal.WriteIntPtr(jobList, job.Handle);
                if (!Native.UpdateProcThreadAttribute(
                        attributeList,
                        0,
                        (IntPtr)Native.ProcThreadAttributeJobList,
                        jobList,
                        (IntPtr)IntPtr.Size,
                        IntPtr.Zero,
                        IntPtr.Zero))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "UpdateProcThreadAttribute for Job Object failed.");
                }

                var startup = new Native.StartupInfoEx
                {
                    StartupInfo = new Native.StartupInfo
                    {
                        cb = Marshal.SizeOf<Native.StartupInfoEx>(),
                        dwFlags = Native.StartfUseStdHandles,
                        hStdInput = IntPtr.Zero,
                        hStdOutput = IntPtr.Zero,
                        hStdError = IntPtr.Zero
                    },
                    lpAttributeList = attributeList
                };

                var commandLine = new StringBuilder(
                    BuildCommandLine(spec.File, spec.Arguments));

                var creationFlags =
                    Native.ExtendedStartupInfoPresent |
                    Native.CreateUnicodeEnvironment |
                    Native.CreateSuspended;

                if (!Native.CreateProcess(
                        null,
                        commandLine,
                        IntPtr.Zero,
                        IntPtr.Zero,
                        false,
                        creationFlags,
                        IntPtr.Zero,
                        spec.WorkingDirectory,
                        ref startup,
                        out var processInfo))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        $"CreateProcess failed for terminal '{spec.File}'.");
                }

                processHandle = processInfo.hProcess;
                threadHandle = processInfo.hThread;

                // CreateProcessW has completed the ConHost attachment. The local copies
                // of the synchronous ConPTY-facing pipe ends are no longer needed.
                CloseRawHandle(ref inputPseudoSide);
                CloseRawHandle(ref outputPseudoSide);

                var process = Process.GetProcessById((int)processInfo.dwProcessId);
                var session = new TerminalSession(
                    sessionId,
                    spec,
                    pseudoConsole,
                    inputHostSide,
                    outputHostSide,
                    process,
                    job);

                // Transfer ConPTY pipes and Job Object to the live session before
                // the suspended shell is allowed to execute. This guarantees that
                // its input writer and output reader already exist on first instruction.
                pseudoConsole = IntPtr.Zero;
                inputHostSide = IntPtr.Zero;
                outputHostSide = IntPtr.Zero;
                job = null;

                try
                {
                    var resumeResult = Native.ResumeThread(threadHandle);
                    if (resumeResult == uint.MaxValue)
                    {
                        throw new Win32Exception(
                            Marshal.GetLastWin32Error(),
                            "ResumeThread failed for terminal process.");
                    }
                }
                catch
                {
                    session.Dispose();
                    throw;
                }

                return session;
            }
            catch (BridgeToolException)
            {
                throw;
            }
            catch (Exception ex)
            {
                throw new BridgeToolException(
                    "terminal_start_failed",
                    ex.Message);
            }
            finally
            {
                if (threadHandle != IntPtr.Zero)
                {
                    Native.CloseHandle(threadHandle);
                }

                if (processHandle != IntPtr.Zero)
                {
                    Native.CloseHandle(processHandle);
                }

                if (attributeList != IntPtr.Zero)
                {
                    Native.DeleteProcThreadAttributeList(attributeList);
                    Marshal.FreeHGlobal(attributeList);
                }

                if (jobList != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(jobList);
                }

                if (pseudoConsole != IntPtr.Zero)
                {
                    Native.ClosePseudoConsole(pseudoConsole);
                }

                CloseRawHandle(ref inputPseudoSide);
                CloseRawHandle(ref inputHostSide);
                CloseRawHandle(ref outputHostSide);
                CloseRawHandle(ref outputPseudoSide);
                job?.Dispose();
            }
        }

        public async Task WriteAsync(
            string data,
            CancellationToken cancellationToken)
        {
            if (!Running)
            {
                throw new BridgeToolException(
                    "terminal_not_running",
                    $"Terminal session has exited: {SessionId}");
            }

            var bytes = Encoding.UTF8.GetBytes(data);

            await _writeGate.WaitAsync(cancellationToken);
            try
            {
                await _input.WriteAsync(bytes, cancellationToken);
                await _input.FlushAsync(cancellationToken);
                lock (_sync)
                {
                    _lastActivityUtc = DateTimeOffset.UtcNow;
                }
            }
            catch (IOException ex)
            {
                throw new BridgeToolException(
                    "terminal_write_failed",
                    $"Could not write to terminal {SessionId}: {ex.Message}");
            }
            finally
            {
                _writeGate.Release();
            }
        }

        public async Task<TerminalReadOutcome> ReadAsync(
            long cursor,
            int maxBytes,
            int waitMs,
            bool stripAnsi,
            bool collapseCarriageReturns,
            CancellationToken cancellationToken)
        {
            if (cursor < 0)
            {
                throw new BridgeToolException(
                    "invalid_args",
                    "cursor must be zero or greater.");
            }

            if (waitMs > 0)
            {
                Task waitTask;
                lock (_sync)
                {
                    var end = _baseCursor + _ring.Count;
                    waitTask = cursor < end || HasExitedLocked()
                        ? Task.CompletedTask
                        : _outputChanged.Task;
                }

                if (!waitTask.IsCompleted)
                {
                    try
                    {
                        await waitTask.WaitAsync(
                            TimeSpan.FromMilliseconds(waitMs),
                            cancellationToken);
                    }
                    catch (TimeoutException)
                    {
                    }
                }
            }

            byte[] bytes;
            long actualCursor;
            long nextCursor;
            long baseCursor;
            bool truncatedBeforeCursor;
            bool running;
            int? exitCode;

            lock (_sync)
            {
                _lastActivityUtc = DateTimeOffset.UtcNow;
                baseCursor = _baseCursor;
                truncatedBeforeCursor = cursor < _baseCursor;
                actualCursor = Math.Max(cursor, _baseCursor);

                var offsetLong = actualCursor - _baseCursor;
                var offset = offsetLong > int.MaxValue
                    ? _ring.Count
                    : Math.Clamp((int)offsetLong, 0, _ring.Count);
                var count = Math.Min(maxBytes, _ring.Count - offset);
                bytes = count > 0
                    ? _ring.GetRange(offset, count).ToArray()
                    : Array.Empty<byte>();

                nextCursor = actualCursor + count;
                running = !_closed && !HasExitedLocked();
                TryCaptureExitCodeLocked();
                exitCode = _exitCode;
            }

            var text = Encoding.UTF8.GetString(bytes);
            if (stripAnsi)
            {
                text = AnsiCsi.Replace(text, string.Empty);
            }

            if (collapseCarriageReturns)
            {
                text = text.Replace("\r\n", "\n", StringComparison.Ordinal)
                    .Replace('\r', '\n');
            }

            return new TerminalReadOutcome(
                SessionId,
                text,
                actualCursor,
                nextCursor,
                baseCursor,
                truncatedBeforeCursor,
                running,
                exitCode);
        }

        public TerminalStatusOutcome Status()
        {
            lock (_sync)
            {
                TryCaptureExitCodeLocked();
                return new TerminalStatusOutcome(
                    SessionId,
                    _process.Id,
                    File,
                    WorkingDirectory,
                    !_closed && !HasExitedLocked(),
                    _exitCode,
                    _columns,
                    _rows,
                    _baseCursor,
                    _baseCursor + _ring.Count,
                    CreatedUtc,
                    _lastActivityUtc);
            }
        }

        public void Resize(int columns, int rows)
        {
            lock (_sync)
            {
                if (_closed)
                {
                    throw new BridgeToolException(
                        "terminal_closed",
                        $"Terminal session is already closed: {SessionId}");
                }

                var hr = Native.ResizePseudoConsole(
                    _pseudoConsole,
                    new Native.Coord((short)columns, (short)rows));

                if (hr != 0)
                {
                    Marshal.ThrowExceptionForHR(hr);
                }

                _columns = columns;
                _rows = rows;
                _lastActivityUtc = DateTimeOffset.UtcNow;
            }
        }

        public async Task<TerminalCloseOutcome> CloseAsync(
            bool force,
            CancellationToken cancellationToken)
        {
            lock (_sync)
            {
                if (_closed)
                {
                    TryCaptureExitCodeLocked();
                    return new TerminalCloseOutcome(SessionId, true, _exitCode);
                }

                _lastActivityUtc = DateTimeOffset.UtcNow;
            }

            try
            {
                if (!_process.HasExited)
                {
                    if (!force)
                    {
                        try
                        {
                            await _writeGate.WaitAsync(cancellationToken);
                            try
                            {
                                await _input.WriteAsync(
                                    Encoding.UTF8.GetBytes("\u0003"),
                                    cancellationToken);
                                await _input.FlushAsync(cancellationToken);
                            }
                            finally
                            {
                                _writeGate.Release();
                            }

                            await Task.Delay(250, cancellationToken);
                        }
                        catch
                        {
                        }
                    }

                    if (!_process.HasExited)
                    {
                        _job.Terminate(1);
                    }
                }
            }
            catch
            {
                try
                {
                    if (!_process.HasExited)
                    {
                        _process.Kill(entireProcessTree: true);
                    }
                }
                catch
                {
                }
            }

            try
            {
                await _process.WaitForExitAsync(cancellationToken)
                    .WaitAsync(TimeSpan.FromSeconds(5), cancellationToken);
            }
            catch
            {
            }

            TaskCompletionSource<bool> signal;
            lock (_sync)
            {
                _closed = true;
                TryCaptureExitCodeLocked();
                signal = SignalOutputChangedLocked();
            }

            signal.TrySetResult(true);
            return new TerminalCloseOutcome(SessionId, false, _exitCode);
        }

        public void Dispose()
        {
            try
            {
                if (Running)
                {
                    CloseAsync(force: true, CancellationToken.None)
                        .GetAwaiter()
                        .GetResult();
                }
            }
            catch
            {
            }

            _readerCancellation.Cancel();

            try
            {
                _input.Dispose();
            }
            catch
            {
            }

            try
            {
                _output.Dispose();
            }
            catch
            {
            }

            try
            {
                _readerTask.Wait(TimeSpan.FromSeconds(1));
            }
            catch
            {
            }

            lock (_sync)
            {
                if (_pseudoConsole != IntPtr.Zero)
                {
                    Native.ClosePseudoConsole(_pseudoConsole);
                    _pseudoConsole = IntPtr.Zero;
                }

                CloseRawHandle(ref _inputHostSide);
                CloseRawHandle(ref _outputHostSide);
            }

            _readerCancellation.Dispose();
            _writeGate.Dispose();
            _job.Dispose();
            _process.Dispose();
        }

        private async Task ReadLoopAsync()
        {
            var buffer = new byte[8192];

            try
            {
                while (!_readerCancellation.IsCancellationRequested)
                {
                    var read = await _output.ReadAsync(
                        buffer,
                        _readerCancellation.Token);

                    if (read <= 0)
                    {
                        break;
                    }

                    TaskCompletionSource<bool> signal;
                    lock (_sync)
                    {
                        for (var index = 0; index < read; index++)
                        {
                            _ring.Add(buffer[index]);
                        }

                        if (_ring.Count > RingBytes)
                        {
                            var remove = _ring.Count - RingBytes;
                            _ring.RemoveRange(0, remove);
                            _baseCursor += remove;
                        }

                        _lastActivityUtc = DateTimeOffset.UtcNow;
                        signal = SignalOutputChangedLocked();
                    }

                    signal.TrySetResult(true);
                }
            }
            catch (OperationCanceledException)
            {
            }
            catch (ObjectDisposedException)
            {
            }
            catch (IOException)
            {
            }
            finally
            {
                TaskCompletionSource<bool> signal;
                lock (_sync)
                {
                    TryCaptureExitCodeLocked();
                    signal = SignalOutputChangedLocked();
                }

                signal.TrySetResult(true);
            }
        }

        private bool HasExitedLocked()
        {
            try
            {
                return _process.HasExited;
            }
            catch
            {
                return true;
            }
        }

        private void TryCaptureExitCodeLocked()
        {
            if (_exitCode.HasValue)
            {
                return;
            }

            try
            {
                if (_process.HasExited)
                {
                    _exitCode = _process.ExitCode;
                }
            }
            catch
            {
            }
        }

        private TaskCompletionSource<bool> SignalOutputChangedLocked()
        {
            var previous = _outputChanged;
            _outputChanged = NewOutputSignal();
            return previous;
        }

        private static TaskCompletionSource<bool> NewOutputSignal()
            => new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private static (IntPtr PtySide, IntPtr CallerSide) CreateConPtyPipe(
        bool callerReads)
    {
        var pipeName = @"\\.\pipe\ChatGptDesktopLocalBridge-ConPTY-" +
                       Guid.NewGuid().ToString("N");

        var serverAccess = callerReads
            ? Native.PipeAccessOutbound
            : Native.PipeAccessInbound;

        var clientAccess = callerReads
            ? Native.GenericRead
            : Native.GenericWrite;

        var ptySide = Native.CreateNamedPipe(
            pipeName,
            serverAccess,
            Native.PipeTypeByte | Native.PipeReadModeByte | Native.PipeWait,
            1,
            4096,
            4096,
            0,
            IntPtr.Zero);

        if (ptySide == IntPtr.Zero || ptySide == new IntPtr(-1))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "CreateNamedPipeW failed for ConPTY.");
        }

        var callerSide = Native.CreateFile(
            pipeName,
            clientAccess,
            0,
            IntPtr.Zero,
            Native.OpenExisting,
            Native.FileAttributeNormal | Native.FileFlagOverlapped,
            IntPtr.Zero);

        if (callerSide == IntPtr.Zero || callerSide == new IntPtr(-1))
        {
            var error = Marshal.GetLastWin32Error();
            Native.CloseHandle(ptySide);
            throw new Win32Exception(
                error,
                "CreateFileW failed for ConPTY caller endpoint.");
        }

        return (ptySide, callerSide);
    }

    private static string BuildCommandLine(
        string file,
        IReadOnlyList<string> arguments)
    {
        var parts = new List<string> { QuoteWindowsArgument(file) };
        parts.AddRange(arguments.Select(QuoteWindowsArgument));
        return string.Join(" ", parts);
    }

    private static string QuoteWindowsArgument(string value)
    {
        if (value.Length == 0)
        {
            return "\"\"";
        }

        if (!value.Any(ch => char.IsWhiteSpace(ch) || ch == '"'))
        {
            return value;
        }

        var builder = new StringBuilder();
        builder.Append('"');
        var slashCount = 0;

        foreach (var ch in value)
        {
            if (ch == '\\')
            {
                slashCount++;
                continue;
            }

            if (ch == '"')
            {
                builder.Append('\\', slashCount * 2 + 1);
                builder.Append('"');
                slashCount = 0;
                continue;
            }

            builder.Append('\\', slashCount);
            slashCount = 0;
            builder.Append(ch);
        }

        builder.Append('\\', slashCount * 2);
        builder.Append('"');
        return builder.ToString();
    }

    private static void CloseRawHandle(ref IntPtr handle)
    {
        var value = Interlocked.Exchange(ref handle, IntPtr.Zero);
        if (value != IntPtr.Zero && value != new IntPtr(-1))
        {
            Native.CloseHandle(value);
        }
    }

    private static class Native
    {
        public const uint ExtendedStartupInfoPresent = 0x00080000;
        public const uint CreateUnicodeEnvironment = 0x00000400;
        public const uint CreateSuspended = 0x00000004;
        public const uint StartfUseStdHandles = 0x00000100;
        public const uint FileFlagOverlapped = 0x40000000;
        public const uint FileAttributeNormal = 0x00000080;
        public const uint PipeAccessInbound = 0x00000001;
        public const uint PipeAccessOutbound = 0x00000002;
        public const uint PipeTypeByte = 0x00000000;
        public const uint PipeReadModeByte = 0x00000000;
        public const uint PipeWait = 0x00000000;
        public const uint GenericRead = 0x80000000;
        public const uint GenericWrite = 0x40000000;
        public const uint OpenExisting = 3;
        public const int ProcThreadAttributePseudoConsole = 0x00020016;
        public const int ProcThreadAttributeJobList = 0x0002000D;

        [StructLayout(LayoutKind.Sequential)]
        public readonly struct Coord(short x, short y)
        {
            public readonly short X = x;
            public readonly short Y = y;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct StartupInfo
        {
            public int cb;
            public string? lpReserved;
            public string? lpDesktop;
            public string? lpTitle;
            public int dwX;
            public int dwY;
            public int dwXSize;
            public int dwYSize;
            public int dwXCountChars;
            public int dwYCountChars;
            public int dwFillAttribute;
            public int dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct StartupInfoEx
        {
            public StartupInfo StartupInfo;
            public IntPtr lpAttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct ProcessInformation
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public uint dwProcessId;
            public uint dwThreadId;
        }

        [DllImport(
            "kernel32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true,
            EntryPoint = "CreateNamedPipeW")]
        public static extern IntPtr CreateNamedPipe(
            string lpName,
            uint dwOpenMode,
            uint dwPipeMode,
            uint nMaxInstances,
            uint nOutBufferSize,
            uint nInBufferSize,
            uint nDefaultTimeOut,
            IntPtr lpSecurityAttributes);

        [DllImport(
            "kernel32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true,
            EntryPoint = "CreateFileW")]
        public static extern IntPtr CreateFile(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            IntPtr lpSecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = false)]
        public static extern int CreatePseudoConsole(
            Coord size,
            IntPtr hInput,
            IntPtr hOutput,
            uint dwFlags,
            out IntPtr phPC);

        [DllImport("kernel32.dll", SetLastError = false)]
        public static extern int ResizePseudoConsole(
            IntPtr hPC,
            Coord size);

        [DllImport("kernel32.dll", SetLastError = false)]
        public static extern void ClosePseudoConsole(IntPtr hPC);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool InitializeProcThreadAttributeList(
            IntPtr lpAttributeList,
            int dwAttributeCount,
            int dwFlags,
            ref IntPtr lpSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool UpdateProcThreadAttribute(
            IntPtr lpAttributeList,
            uint dwFlags,
            IntPtr attribute,
            IntPtr lpValue,
            IntPtr cbSize,
            IntPtr lpPreviousValue,
            IntPtr lpReturnSize);

        [DllImport("kernel32.dll", SetLastError = false)]
        public static extern void DeleteProcThreadAttributeList(
            IntPtr lpAttributeList);

        [DllImport(
            "kernel32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true,
            EntryPoint = "CreateProcessW")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CreateProcess(
            string? lpApplicationName,
            StringBuilder lpCommandLine,
            IntPtr lpProcessAttributes,
            IntPtr lpThreadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool bInheritHandles,
            uint dwCreationFlags,
            IntPtr lpEnvironment,
            string? lpCurrentDirectory,
            ref StartupInfoEx lpStartupInfo,
            out ProcessInformation lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint ResumeThread(IntPtr hThread);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseHandle(IntPtr hObject);
    }
}
