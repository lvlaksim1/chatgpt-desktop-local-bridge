using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace ChatGptDesktopLocalBridge.Bridge;

public sealed record TerminalOpenSpec(
    string File,
    IReadOnlyList<string> Arguments,
    string? WorkingDirectory,
    int Columns,
    int Rows,
    int MaxBufferBytes);

public sealed record TerminalOpenOutcome(
    string TerminalId,
    int ProcessId,
    string File,
    IReadOnlyList<string> Arguments,
    string? WorkingDirectory,
    int Columns,
    int Rows,
    int MaxBufferBytes,
    long Cursor);

public sealed record TerminalReadOutcome(
    string TerminalId,
    long Cursor,
    long NextCursor,
    string Text,
    long LostBytes,
    bool Truncated,
    long TotalBytes,
    int RetainedBytes,
    bool Exited,
    int? ExitCode);

public sealed record TerminalStatusOutcome(
    string TerminalId,
    int ProcessId,
    string File,
    IReadOnlyList<string> Arguments,
    string? WorkingDirectory,
    int Columns,
    int Rows,
    long TotalBytes,
    int RetainedBytes,
    bool Exited,
    int? ExitCode);

public sealed class TerminalSessionManager : IDisposable
{
    private const int MaxSessions = 4;
    private const int MaxWriteBytes = 64 * 1024;

    private readonly ConcurrentDictionary<string, TerminalSession> _sessions =
        new(StringComparer.Ordinal);

    public int ActiveCount => _sessions.Values.Count(session => !session.Exited);

    public async Task<TerminalOpenOutcome> OpenAsync(
        TerminalOpenSpec spec,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (_sessions.Count >= MaxSessions)
        {
            throw new BridgeToolException(
                "terminal_session_limit",
                $"At most {MaxSessions} terminal sessions may exist at once. Close an existing terminal first.");
        }

        var session = TerminalSession.Start(spec);
        if (!_sessions.TryAdd(session.Id, session))
        {
            session.Dispose();
            throw new BridgeToolException(
                "terminal_tracking_failed",
                "Could not register the terminal session.");
        }

        try
        {
            await Task.Yield();
            return session.OpenOutcome();
        }
        catch
        {
            _sessions.TryRemove(session.Id, out _);
            session.Dispose();
            throw;
        }
    }

    public TerminalReadOutcome Read(
        string terminalId,
        long cursor,
        int maxBytes)
        => Get(terminalId).Read(cursor, maxBytes);

    public Task<object> WriteAsync(
        string terminalId,
        string data,
        CancellationToken cancellationToken = default)
        => Get(terminalId).WriteAsync(data, MaxWriteBytes, cancellationToken);

    public object Resize(
        string terminalId,
        int columns,
        int rows)
        => Get(terminalId).Resize(columns, rows);

    public TerminalStatusOutcome Status(string terminalId)
        => Get(terminalId).Status();

    public async Task<object> CloseAsync(
        string terminalId,
        CancellationToken cancellationToken = default)
    {
        if (!_sessions.TryRemove(terminalId, out var session))
        {
            throw new BridgeToolException(
                "terminal_not_found",
                $"Terminal session does not exist: {terminalId}");
        }

        try
        {
            return await session.CloseAsync(cancellationToken);
        }
        finally
        {
            session.Dispose();
        }
    }

    public int CloseAll()
    {
        var sessions = _sessions.ToArray();
        var closed = 0;

        foreach (var pair in sessions)
        {
            if (!_sessions.TryRemove(pair.Key, out var session))
            {
                continue;
            }

            try
            {
                session.CloseAsync(CancellationToken.None)
                    .GetAwaiter()
                    .GetResult();
            }
            catch
            {
                // Dispose below still closes the Job Object and ConPTY handles.
            }
            finally
            {
                session.Dispose();
            }

            closed++;
        }

        return closed;
    }

    public void Dispose()
    {
        CloseAll();
    }

    private TerminalSession Get(string terminalId)
    {
        if (string.IsNullOrWhiteSpace(terminalId) ||
            !_sessions.TryGetValue(terminalId, out var session))
        {
            throw new BridgeToolException(
                "terminal_not_found",
                $"Terminal session does not exist: {terminalId}");
        }

        return session;
    }

    private sealed class TerminalSession : IDisposable
    {
        private readonly object _stateSync = new();
        private readonly SemaphoreSlim _writeGate = new(1, 1);
        private readonly TerminalOutputRing _output;
        private readonly WindowsJobObject _job;
        private readonly Process _process;
        private readonly SafeFileHandle _inputRead;
        private readonly SafeFileHandle _inputWrite;
        private readonly SafeFileHandle _outputRead;
        private readonly SafeFileHandle _outputWrite;
        private readonly FileStream _inputStream;
        private readonly FileStream _outputStream;
        private IntPtr _pseudoConsole;
        private readonly IntPtr _attributeList;
        private readonly Task _readerTask;
        private readonly Task _exitTask;
        private bool _closed;
        private bool _exited;
        private int? _exitCode;
        private int _columns;
        private int _rows;

        private TerminalSession(
            string id,
            TerminalOpenSpec spec,
            WindowsJobObject job,
            Process process,
            SafeFileHandle inputRead,
            SafeFileHandle inputWrite,
            SafeFileHandle outputRead,
            SafeFileHandle outputWrite,
            FileStream inputStream,
            FileStream outputStream,
            IntPtr pseudoConsole,
            IntPtr attributeList)
        {
            Id = id;
            Spec = spec;
            _job = job;
            _process = process;
            _inputRead = inputRead;
            _inputWrite = inputWrite;
            _outputRead = outputRead;
            _outputWrite = outputWrite;
            _inputStream = inputStream;
            _outputStream = outputStream;
            _pseudoConsole = pseudoConsole;
            _attributeList = attributeList;
            _columns = spec.Columns;
            _rows = spec.Rows;
            _output = new TerminalOutputRing(spec.MaxBufferBytes);

            _readerTask = PumpOutputAsync();
            _exitTask = ObserveExitAsync();
        }

        public string Id { get; }

        public TerminalOpenSpec Spec { get; }

        public bool Exited
        {
            get
            {
                lock (_stateSync)
                {
                    return _exited;
                }
            }
        }

        public static TerminalSession Start(TerminalOpenSpec spec)
        {
            if (!OperatingSystem.IsWindows())
            {
                throw new BridgeToolException(
                    "terminal_platform_unsupported",
                    "Persistent terminal sessions require Windows ConPTY.");
            }

            SafeFileHandle? inputRead = null;
            SafeFileHandle? inputWrite = null;
            SafeFileHandle? outputRead = null;
            SafeFileHandle? outputWrite = null;
            FileStream? inputStream = null;
            FileStream? outputStream = null;
            WindowsJobObject? job = null;
            Process? process = null;
            IntPtr pseudoConsole = IntPtr.Zero;
            IntPtr attributeList = IntPtr.Zero;
            NativeMethods.PROCESS_INFORMATION processInfo = default;
            var success = false;

            try
            {
                NativeMethods.CreateAnonymousPipe(out inputRead, out inputWrite);
                NativeMethods.CreateAnonymousPipe(out outputRead, out outputWrite);

                var createResult = NativeMethods.CreatePseudoConsole(
                    new NativeMethods.COORD(
                        checked((short)spec.Columns),
                        checked((short)spec.Rows)),
                    inputRead,
                    outputWrite,
                    0,
                    out pseudoConsole);

                if (createResult != 0)
                {
                    throw new Win32Exception(
                        createResult,
                        "CreatePseudoConsole failed.");
                }

                attributeList = NativeMethods.CreatePseudoConsoleAttributeList(
                    pseudoConsole);

                var commandLine = BuildCommandLine(spec.File, spec.Arguments);
                var startupInfo = new NativeMethods.STARTUPINFOEX
                {
                    StartupInfo = new NativeMethods.STARTUPINFO
                    {
                        cb = Marshal.SizeOf<NativeMethods.STARTUPINFOEX>()
                    },
                    lpAttributeList = attributeList
                };

                var workingDirectory =
                    string.IsNullOrWhiteSpace(spec.WorkingDirectory)
                        ? null
                        : spec.WorkingDirectory;

                if (!NativeMethods.CreateProcessW(
                        null,
                        commandLine,
                        IntPtr.Zero,
                        IntPtr.Zero,
                        false,
                        NativeMethods.ExtendedStartupInfoPresent |
                        NativeMethods.CreateSuspended,
                        IntPtr.Zero,
                        workingDirectory,
                        ref startupInfo,
                        out processInfo))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        $"Could not start terminal process '{spec.File}'.");
                }

                job = WindowsJobObject.CreateKillOnClose();
                job.Assign(processInfo.hProcess);

                process = Process.GetProcessById(processInfo.dwProcessId);

                if (NativeMethods.ResumeThread(processInfo.hThread) == uint.MaxValue)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "ResumeThread failed for terminal process.");
                }

                NativeMethods.CloseHandle(processInfo.hThread);
                processInfo.hThread = IntPtr.Zero;
                NativeMethods.CloseHandle(processInfo.hProcess);
                processInfo.hProcess = IntPtr.Zero;

                inputStream = new FileStream(
                    inputWrite,
                    FileAccess.Write,
                    4096,
                    isAsync: true);
                outputStream = new FileStream(
                    outputRead,
                    FileAccess.Read,
                    8192,
                    isAsync: true);

                var session = new TerminalSession(
                    Guid.NewGuid().ToString("N"),
                    spec,
                    job,
                    process,
                    inputRead,
                    inputWrite,
                    outputRead,
                    outputWrite,
                    inputStream,
                    outputStream,
                    pseudoConsole,
                    attributeList);
                success = true;
                return session;
            }
            catch (BridgeToolException)
            {
                throw;
            }
            catch (Exception ex)
            {
                try
                {
                    job?.Terminate(1);
                }
                catch
                {
                }

                throw new BridgeToolException(
                    "terminal_start_failed",
                    ex.Message);
            }
            finally
            {
                if (processInfo.hThread != IntPtr.Zero)
                {
                    NativeMethods.CloseHandle(processInfo.hThread);
                }

                if (processInfo.hProcess != IntPtr.Zero)
                {
                    NativeMethods.CloseHandle(processInfo.hProcess);
                }

                if (!success)
                {
                    inputStream?.Dispose();
                    outputStream?.Dispose();
                    inputRead?.Dispose();
                    inputWrite?.Dispose();
                    outputRead?.Dispose();
                    outputWrite?.Dispose();

                    if (attributeList != IntPtr.Zero)
                    {
                        NativeMethods.DeleteProcThreadAttributeList(attributeList);
                        Marshal.FreeHGlobal(attributeList);
                    }

                    if (pseudoConsole != IntPtr.Zero)
                    {
                        NativeMethods.ClosePseudoConsole(pseudoConsole);
                    }

                    process?.Dispose();
                    job?.Dispose();
                }
            }
        }

        public TerminalOpenOutcome OpenOutcome()
            => new(
                Id,
                _process.Id,
                Spec.File,
                Spec.Arguments,
                Spec.WorkingDirectory,
                _columns,
                _rows,
                Spec.MaxBufferBytes,
                0);

        public TerminalReadOutcome Read(long cursor, int maxBytes)
        {
            var slice = _output.Read(cursor, maxBytes);
            bool exited;
            int? exitCode;

            lock (_stateSync)
            {
                exited = _exited;
                exitCode = _exitCode;
            }

            return new TerminalReadOutcome(
                Id,
                cursor,
                slice.NextCursor,
                Encoding.UTF8.GetString(slice.Bytes),
                slice.LostBytes,
                slice.Truncated,
                slice.TotalBytes,
                slice.RetainedBytes,
                exited,
                exitCode);
        }

        public async Task<object> WriteAsync(
            string data,
            int maxWriteBytes,
            CancellationToken cancellationToken)
        {
            var bytes = Encoding.UTF8.GetBytes(data);
            if (bytes.Length > maxWriteBytes)
            {
                throw new BridgeToolException(
                    "terminal_write_too_large",
                    $"Terminal input is {bytes.Length} bytes; maximum is {maxWriteBytes} bytes.");
            }

            await _writeGate.WaitAsync(cancellationToken);
            try
            {
                lock (_stateSync)
                {
                    if (_closed)
                    {
                        throw new BridgeToolException(
                            "terminal_closed",
                            $"Terminal session is closed: {Id}");
                    }

                    if (_exited)
                    {
                        throw new BridgeToolException(
                            "terminal_exited",
                            $"Terminal process has exited: {Id}");
                    }
                }

                await _inputStream.WriteAsync(bytes, cancellationToken);
                await _inputStream.FlushAsync(cancellationToken);

                return new
                {
                    terminalId = Id,
                    bytesWritten = bytes.Length
                };
            }
            catch (BridgeToolException)
            {
                throw;
            }
            catch (Exception ex)
            {
                throw new BridgeToolException(
                    "terminal_write_failed",
                    ex.Message);
            }
            finally
            {
                _writeGate.Release();
            }
        }

        public object Resize(int columns, int rows)
        {
            lock (_stateSync)
            {
                if (_closed)
                {
                    throw new BridgeToolException(
                        "terminal_closed",
                        $"Terminal session is closed: {Id}");
                }
            }

            var result = NativeMethods.ResizePseudoConsole(
                _pseudoConsole,
                new NativeMethods.COORD(
                    checked((short)columns),
                    checked((short)rows)));

            if (result != 0)
            {
                throw new BridgeToolException(
                    "terminal_resize_failed",
                    $"ResizePseudoConsole failed with HRESULT 0x{result:X8}.");
            }

            lock (_stateSync)
            {
                _columns = columns;
                _rows = rows;
            }

            return new
            {
                terminalId = Id,
                columns,
                rows
            };
        }

        public TerminalStatusOutcome Status()
        {
            bool exited;
            int? exitCode;
            int columns;
            int rows;

            lock (_stateSync)
            {
                exited = _exited;
                exitCode = _exitCode;
                columns = _columns;
                rows = _rows;
            }

            var (totalBytes, retainedBytes) = _output.Status();

            return new TerminalStatusOutcome(
                Id,
                _process.Id,
                Spec.File,
                Spec.Arguments,
                Spec.WorkingDirectory,
                columns,
                rows,
                totalBytes,
                retainedBytes,
                exited,
                exitCode);
        }

        public async Task<object> CloseAsync(CancellationToken cancellationToken)
        {
            bool alreadyClosed;
            lock (_stateSync)
            {
                alreadyClosed = _closed;
                _closed = true;
            }

            if (alreadyClosed)
            {
                return new
                {
                    terminalId = Id,
                    closed = true,
                    alreadyClosed = true
                };
            }

            try
            {
                if (!_process.HasExited)
                {
                    try
                    {
                        _job.Terminate(1);
                    }
                    catch
                    {
                        try
                        {
                            _process.Kill(entireProcessTree: true);
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
                }
            }
            finally
            {
                TryClosePseudoConsole();
            }

            return new
            {
                terminalId = Id,
                closed = true,
                alreadyClosed = false,
                exitCode = TryGetExitCode()
            };
        }

        private async Task PumpOutputAsync()
        {
            var buffer = new byte[8192];

            try
            {
                while (true)
                {
                    var read = await _outputStream.ReadAsync(buffer);
                    if (read <= 0)
                    {
                        break;
                    }

                    _output.Append(buffer.AsSpan(0, read));
                }
            }
            catch (ObjectDisposedException)
            {
            }
            catch (IOException)
            {
            }
        }

        private async Task ObserveExitAsync()
        {
            try
            {
                await _process.WaitForExitAsync();
            }
            catch
            {
            }

            lock (_stateSync)
            {
                _exited = true;
                _exitCode = TryGetExitCode();
            }
        }

        private int? TryGetExitCode()
        {
            try
            {
                return _process.HasExited
                    ? _process.ExitCode
                    : null;
            }
            catch
            {
                return null;
            }
        }

        private void TryClosePseudoConsole()
        {
            var handle = Interlocked.Exchange(ref _pseudoConsole, IntPtr.Zero);
            if (handle == IntPtr.Zero)
            {
                return;
            }

            try
            {
                NativeMethods.ClosePseudoConsole(handle);
            }
            catch
            {
            }
        }

        public void Dispose()
        {
            lock (_stateSync)
            {
                _closed = true;
            }

            try
            {
                if (!_process.HasExited)
                {
                    _job.Terminate(1);
                }
            }
            catch
            {
            }

            TryClosePseudoConsole();

            _inputStream.Dispose();
            _outputStream.Dispose();

            _inputRead.Dispose();
            _inputWrite.Dispose();
            _outputRead.Dispose();
            _outputWrite.Dispose();

            if (_attributeList != IntPtr.Zero)
            {
                NativeMethods.DeleteProcThreadAttributeList(_attributeList);
                Marshal.FreeHGlobal(_attributeList);
            }

            _process.Dispose();
            _job.Dispose();
            _writeGate.Dispose();

            _ = _readerTask;
            _ = _exitTask;
        }

        private static StringBuilder BuildCommandLine(
            string file,
            IReadOnlyList<string> arguments)
        {
            var parts = new List<string>(arguments.Count + 1)
            {
                QuoteWindowsArgument(
                    Environment.ExpandEnvironmentVariables(file))
            };

            parts.AddRange(arguments.Select(QuoteWindowsArgument));
            return new StringBuilder(string.Join(" ", parts));
        }

        private static string QuoteWindowsArgument(string value)
        {
            if (value.Length > 0 &&
                !value.Any(ch => char.IsWhiteSpace(ch) || ch == '"'))
            {
                return value;
            }

            var builder = new StringBuilder();
            builder.Append('"');
            var backslashes = 0;

            foreach (var ch in value)
            {
                if (ch == '\\')
                {
                    backslashes++;
                    continue;
                }

                if (ch == '"')
                {
                    builder.Append('\\', backslashes * 2 + 1);
                    builder.Append('"');
                    backslashes = 0;
                    continue;
                }

                builder.Append('\\', backslashes);
                backslashes = 0;
                builder.Append(ch);
            }

            builder.Append('\\', backslashes * 2);
            builder.Append('"');
            return builder.ToString();
        }
    }

    private sealed class TerminalOutputRing
    {
        private readonly byte[] _buffer;
        private readonly object _sync = new();
        private int _start;
        private int _count;
        private long _totalBytes;

        public TerminalOutputRing(int capacity)
        {
            _buffer = new byte[capacity];
        }

        public void Append(ReadOnlySpan<byte> data)
        {
            lock (_sync)
            {
                var originalLength = data.Length;
                if (originalLength == 0)
                {
                    return;
                }

                if (originalLength >= _buffer.Length)
                {
                    data = data[^_buffer.Length..];
                    data.CopyTo(_buffer);
                    _start = 0;
                    _count = _buffer.Length;
                    _totalBytes += originalLength;
                    return;
                }

                var overflow = Math.Max(0, _count + data.Length - _buffer.Length);
                if (overflow > 0)
                {
                    _start = (_start + overflow) % _buffer.Length;
                    _count -= overflow;
                }

                var writeIndex = (_start + _count) % _buffer.Length;
                var first = Math.Min(data.Length, _buffer.Length - writeIndex);
                data[..first].CopyTo(_buffer.AsSpan(writeIndex, first));

                if (first < data.Length)
                {
                    data[first..].CopyTo(_buffer);
                }

                _count += data.Length;
                _totalBytes += originalLength;
            }
        }

        public TerminalOutputSlice Read(long cursor, int maxBytes)
        {
            lock (_sync)
            {
                var normalizedCursor = Math.Max(0, cursor);
                var earliest = _totalBytes - _count;
                var lostBytes = Math.Max(0, earliest - normalizedCursor);
                var actualCursor = Math.Clamp(
                    normalizedCursor,
                    earliest,
                    _totalBytes);
                var available = _totalBytes - actualCursor;
                var length = checked((int)Math.Min(available, maxBytes));
                var bytes = new byte[length];

                if (length > 0)
                {
                    var retainedOffset = checked((int)(actualCursor - earliest));
                    var readIndex = (_start + retainedOffset) % _buffer.Length;
                    var first = Math.Min(length, _buffer.Length - readIndex);
                    _buffer.AsSpan(readIndex, first).CopyTo(bytes);

                    if (first < length)
                    {
                        _buffer.AsSpan(0, length - first)
                            .CopyTo(bytes.AsSpan(first));
                    }
                }

                return new TerminalOutputSlice(
                    bytes,
                    actualCursor + length,
                    lostBytes,
                    available > length,
                    _totalBytes,
                    _count);
            }
        }

        public (long TotalBytes, int RetainedBytes) Status()
        {
            lock (_sync)
            {
                return (_totalBytes, _count);
            }
        }
    }

    private sealed record TerminalOutputSlice(
        byte[] Bytes,
        long NextCursor,
        long LostBytes,
        bool Truncated,
        long TotalBytes,
        int RetainedBytes);

    private static class NativeMethods
    {
        public const uint ExtendedStartupInfoPresent = 0x00080000;
        public const uint CreateSuspended = 0x00000004;
        private const uint ProcThreadAttributePseudoConsole = 0x00020016;

        [StructLayout(LayoutKind.Sequential)]
        public readonly struct COORD
        {
            public COORD(short x, short y)
            {
                X = x;
                Y = y;
            }

            public readonly short X;
            public readonly short Y;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct STARTUPINFOEX
        {
            public STARTUPINFO StartupInfo;
            public IntPtr lpAttributeList;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct STARTUPINFO
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
        public struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public int dwProcessId;
            public int dwThreadId;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern int CreatePseudoConsole(
            COORD size,
            SafeFileHandle hInput,
            SafeFileHandle hOutput,
            uint dwFlags,
            out IntPtr phPC);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern int ResizePseudoConsole(
            IntPtr hPC,
            COORD size);

        [DllImport("kernel32.dll")]
        public static extern void ClosePseudoConsole(IntPtr hPC);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreatePipe(
            out SafeFileHandle hReadPipe,
            out SafeFileHandle hWritePipe,
            IntPtr lpPipeAttributes,
            int nSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool InitializeProcThreadAttributeList(
            IntPtr lpAttributeList,
            int dwAttributeCount,
            int dwFlags,
            ref IntPtr lpSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateProcThreadAttribute(
            IntPtr lpAttributeList,
            uint dwFlags,
            IntPtr attribute,
            IntPtr lpValue,
            IntPtr cbSize,
            IntPtr lpPreviousValue,
            IntPtr lpReturnSize);

        [DllImport("kernel32.dll")]
        public static extern void DeleteProcThreadAttributeList(
            IntPtr lpAttributeList);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CreateProcessW(
            string? lpApplicationName,
            StringBuilder lpCommandLine,
            IntPtr lpProcessAttributes,
            IntPtr lpThreadAttributes,
            bool bInheritHandles,
            uint dwCreationFlags,
            IntPtr lpEnvironment,
            string? lpCurrentDirectory,
            ref STARTUPINFOEX lpStartupInfo,
            out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint ResumeThread(IntPtr hThread);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseHandle(IntPtr hObject);

        public static void CreateAnonymousPipe(
            out SafeFileHandle read,
            out SafeFileHandle write)
        {
            if (!CreatePipe(out read, out write, IntPtr.Zero, 0))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "CreatePipe failed.");
            }
        }

        public static IntPtr CreatePseudoConsoleAttributeList(
            IntPtr pseudoConsole)
        {
            var size = IntPtr.Zero;
            InitializeProcThreadAttributeList(
                IntPtr.Zero,
                1,
                0,
                ref size);

            if (size == IntPtr.Zero)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Could not calculate pseudo-console attribute-list size.");
            }

            var list = Marshal.AllocHGlobal(size);
            try
            {
                if (!InitializeProcThreadAttributeList(
                        list,
                        1,
                        0,
                        ref size))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Could not initialize pseudo-console attribute list.");
                }

                if (!UpdateProcThreadAttribute(
                        list,
                        0,
                        (IntPtr)ProcThreadAttributePseudoConsole,
                        pseudoConsole,
                        (IntPtr)IntPtr.Size,
                        IntPtr.Zero,
                        IntPtr.Zero))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Could not attach pseudo console to process startup attributes.");
                }

                return list;
            }
            catch
            {
                Marshal.FreeHGlobal(list);
                throw;
            }
        }
    }
}
