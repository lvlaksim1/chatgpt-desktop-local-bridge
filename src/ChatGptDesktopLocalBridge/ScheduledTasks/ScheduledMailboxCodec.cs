using System.Text.Json;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

public sealed record ScheduledMailboxMessage(
    int Schema,
    string Channel,
    int Generation,
    long Seq,
    string MessageId,
    string From,
    string To,
    string State,
    string Type,
    string Payload,
    string? Ack);

public static class ScheduledMailboxCodec
{
    public const string Channel = "desktop-local-bridge-probe";

    public static string CreateReady(
        long seq,
        string payload,
        out string messageId)
    {
        messageId = $"msg-{seq}-{Guid.NewGuid():N}"[..Math.Min(
            24,
            $"msg-{seq}-{Guid.NewGuid():N}".Length)];

        var message = new ScheduledMailboxMessage(
            1,
            Channel,
            1,
            seq,
            messageId,
            "desktop",
            "worker",
            "READY",
            "PING",
            payload,
            null);

        return JsonSerializer.Serialize(
            message,
            new JsonSerializerOptions
            {
                PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
                WriteIndented = true
            });
    }

    public static bool TryReadAck(
        string body,
        string expectedMessageId,
        string expectedPayload,
        out string detail)
    {
        detail = string.Empty;

        var candidates = new List<string> { body };

        try
        {
            using var outer = JsonDocument.Parse(body);
            ExtractStrings(outer.RootElement, candidates);
        }
        catch
        {
        }

        foreach (var candidate in candidates)
        {
            if (!candidate.Contains(expectedMessageId, StringComparison.Ordinal) ||
                !candidate.Contains(expectedPayload, StringComparison.Ordinal))
            {
                continue;
            }

            if (candidate.Contains(""state"", StringComparison.OrdinalIgnoreCase) &&
                candidate.Contains("ACK", StringComparison.OrdinalIgnoreCase))
            {
                detail = candidate;
                return true;
            }
        }

        detail = "ACK matching message_id and payload was not found in the response.";
        return false;
    }

    private static void ExtractStrings(
        JsonElement element,
        ICollection<string> output)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.String:
                var value = element.GetString();
                if (!string.IsNullOrWhiteSpace(value) &&
                    (value.Contains("READY", StringComparison.OrdinalIgnoreCase) ||
                     value.Contains("ACK", StringComparison.OrdinalIgnoreCase) ||
                     value.Contains(Channel, StringComparison.OrdinalIgnoreCase)))
                {
                    output.Add(value);
                }
                break;

            case JsonValueKind.Object:
                foreach (var property in element.EnumerateObject())
                {
                    ExtractStrings(property.Value, output);
                }
                break;

            case JsonValueKind.Array:
                foreach (var item in element.EnumerateArray())
                {
                    ExtractStrings(item, output);
                }
                break;
        }
    }
}
