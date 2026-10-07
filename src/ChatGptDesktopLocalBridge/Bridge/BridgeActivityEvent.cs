using System.Text.Json;

namespace ChatGptDesktopLocalBridge.Bridge;

public sealed record BridgeActivityEvent(
    DateTimeOffset Timestamp,
    string Phase,
    string RequestId,
    string Tool,
    JsonElement Args,
    bool? Ok = null,
    long? ElapsedMs = null,
    JsonElement? Result = null,
    string? ErrorCode = null,
    string? ErrorMessage = null);
