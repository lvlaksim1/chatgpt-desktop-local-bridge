namespace ChatGptDesktopLocalBridge.Bridge;

public static class BridgeConversationIdentity
{
    public static string? TryGetConversationKey(Uri? uri)
    {
        if (uri is null ||
            uri.Scheme != Uri.UriSchemeHttps ||
            !(uri.Host.Equals("chatgpt.com", StringComparison.OrdinalIgnoreCase) ||
              uri.Host.EndsWith(".chatgpt.com", StringComparison.OrdinalIgnoreCase)))
        {
            return null;
        }

        var segments = uri.AbsolutePath
            .Split('/', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        for (var i = 0; i < segments.Length - 1; i++)
        {
            if (!segments[i].Equals("c", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var conversationId = segments[i + 1];
            if (conversationId.Length < 8 ||
                conversationId.Any(ch => !(char.IsLetterOrDigit(ch) || ch is '-' or '_')))
            {
                return null;
            }

            return "chatgpt:conversation:" + conversationId.ToLowerInvariant();
        }

        return null;
    }
}
