using System.Text;
using System.Text.Json;

namespace ChatGptDesktopLocalBridge.Bridge;

public sealed record BridgeSerializedResult(
    string Json,
    BridgeResult Envelope,
    int OriginalBytes,
    bool WasBounded);

public static class BridgeResultCodec
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower
    };

    public static BridgeSerializedResult SerializeBounded(
        BridgeResult result,
        int maxResultBytes)
    {
        if (maxResultBytes < 1024)
        {
            throw new ArgumentOutOfRangeException(
                nameof(maxResultBytes),
                "Bridge result limit must be at least 1024 bytes.");
        }

        var json = JsonSerializer.Serialize(result, JsonOptions);
        var originalBytes = Encoding.UTF8.GetByteCount(json);

        if (originalBytes <= maxResultBytes)
        {
            return new BridgeSerializedResult(
                json,
                result,
                originalBytes,
                WasBounded: false);
        }

        var bounded = result with
        {
            Ok = false,
            Result = null,
            Error = new BridgeError(
                "result_too_large",
                $"Serialized bridge result is {originalBytes} bytes; limit is {maxResultBytes} bytes. Narrow the request.")
        };

        var boundedJson = JsonSerializer.Serialize(bounded, JsonOptions);
        var boundedBytes = Encoding.UTF8.GetByteCount(boundedJson);

        if (boundedBytes > maxResultBytes)
        {
            throw new InvalidOperationException(
                "Bridge result limit is too small to hold the bounded error envelope.");
        }

        return new BridgeSerializedResult(
            boundedJson,
            bounded,
            originalBytes,
            WasBounded: true);
    }
}
