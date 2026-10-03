using System.Text;
using System.Text.Json;

namespace ChatGptDesktopLocalBridge.Bridge;

public sealed record PreparedBridgeResult(
    bool Ok,
    string? ErrorCode,
    string EnvelopeJson,
    string Message,
    bool ReplacedOversizeResult);

public static class BridgeResultTransport
{
    public const string ResultStart = "[[LOCAL_BRIDGE_RESULT_V1]]";
    public const string ResultEnd = "[[/LOCAL_BRIDGE_RESULT_V1]]";
    public const int MaxMessageBytes = 256 * 1024;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower
    };

    public static PreparedBridgeResult Prepare(
        BridgeResult result,
        bool ok,
        string? errorCode)
    {
        var envelopeJson = JsonSerializer.Serialize(result, JsonOptions);
        var message = FormatMessage(envelopeJson);

        if (Encoding.UTF8.GetByteCount(message) <= MaxMessageBytes)
        {
            return new PreparedBridgeResult(
                ok,
                errorCode,
                envelopeJson,
                message,
                false);
        }

        const string oversizedCode = "result_too_large_after_execution";
        var bounded = new BridgeResult(
            result.Session,
            result.RequestId,
            false,
            Error: new BridgeError(
                oversizedCode,
                $"The local tool completed, but its serialized result exceeded the {MaxMessageBytes} byte bridge transport limit. Retry with a smaller requested result."));

        envelopeJson = JsonSerializer.Serialize(bounded, JsonOptions);
        message = FormatMessage(envelopeJson);

        if (Encoding.UTF8.GetByteCount(message) > MaxMessageBytes)
        {
            throw new InvalidOperationException("Bridge oversized-result error envelope exceeded the transport limit.");
        }

        return new PreparedBridgeResult(
            false,
            oversizedCode,
            envelopeJson,
            message,
            true);
    }

    public static string FormatMessage(string envelopeJson)
    {
        if (string.IsNullOrWhiteSpace(envelopeJson))
        {
            throw new ArgumentException("Bridge result envelope JSON must not be empty.", nameof(envelopeJson));
        }

        using (JsonDocument.Parse(envelopeJson))
        {
        }

        return $"{ResultStart}\n{envelopeJson}\n{ResultEnd}";
    }
}