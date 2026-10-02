namespace ChatGptDesktopLocalBridge.Bridge;

public enum BridgeExecutionSemantics
{
    ReadOnly,
    Mutating
}

public sealed record BridgeCapabilityDefinition(
    string Tool,
    string Capability,
    BridgeExecutionSemantics Semantics,
    int MaxResultBytes,
    bool Known = true);

public static class BridgeCapabilityRegistry
{
    private static readonly IReadOnlyDictionary<string, BridgeCapabilityDefinition> Definitions =
        new Dictionary<string, BridgeCapabilityDefinition>(StringComparer.Ordinal)
        {
            ["system.info"] = new(
                "system.info",
                "system.info",
                BridgeExecutionSemantics.ReadOnly,
                64 * 1024),
            ["fs.list"] = new(
                "fs.list",
                "fs.list",
                BridgeExecutionSemantics.ReadOnly,
                512 * 1024),
            ["fs.read_text"] = new(
                "fs.read_text",
                "fs.read_text",
                BridgeExecutionSemantics.ReadOnly,
                1024 * 1024)
        };

    public static BridgeCapabilityDefinition Resolve(string tool)
    {
        if (Definitions.TryGetValue(tool, out var definition))
        {
            return definition;
        }

        return new BridgeCapabilityDefinition(
            tool,
            tool,
            BridgeExecutionSemantics.ReadOnly,
            64 * 1024,
            Known: false);
    }

    public static IReadOnlyCollection<BridgeCapabilityDefinition> All =>
        Definitions.Values.ToArray();
}
