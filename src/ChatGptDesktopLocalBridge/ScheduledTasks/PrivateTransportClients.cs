using System.Text.Json;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

public sealed class ScheduledTasksClient
{
    private readonly ChatGptPrivateTransport _transport;

    public ScheduledTasksClient(ChatGptPrivateTransport transport)
    {
        _transport = transport;
    }

    public Task<PrivateTransportResult> ListAsync(
        string filter)
    {
        var allowed = filter switch
        {
            "scheduled" => "scheduled",
            "paused" => "paused",
            "finished" => "finished",
            _ => throw new ArgumentOutOfRangeException(
                nameof(filter),
                "Filter must be scheduled, paused, or finished.")
        };

        return _transport.GetAsync(
            $"/backend-api/automations?filter={allowed}");
    }

    public Task<PrivateTransportResult> GetLatestRunAsync(
        string automationId)
    {
        if (string.IsNullOrWhiteSpace(automationId))
        {
            throw new ArgumentException(
                "Automation ID is required.",
                nameof(automationId));
        }

        return _transport.GetAsync(
            "/backend-api/automation/" +
            Uri.EscapeDataString(automationId.Trim()) +
            "/latest_backing_run?include_snapshot=true");
    }
}

public sealed class LibraryClient
{
    private readonly ChatGptPrivateTransport _transport;

    public LibraryClient(ChatGptPrivateTransport transport)
    {
        _transport = transport;
    }

    public Task<PrivateTransportResult> ListAsync(
        int limit = 100)
    {
        limit = Math.Clamp(limit, 1, 100);

        return _transport.PostReadAsync(
            "/backend-api/files/library",
            JsonSerializer.Serialize(new { limit }));
    }

    public Task<PrivateTransportResult> GetStorageUsageAsync()
        => _transport.GetAsync(
            "/backend-api/files/library/storage/usage");
}
