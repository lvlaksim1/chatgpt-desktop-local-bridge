using System.Diagnostics;
using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.IdentityModel.Tokens;

namespace ChatGptPlanTransportProbe;

internal static class Program
{
    private const string AuthorizationEndpoint = "https://auth.openai.com/api/accounts/authorize";
    private const string TokenEndpoint = "https://auth.openai.com/api/accounts/oauth/token";
    private const string DiscoveryEndpoint = "https://auth.openai.com/.well-known/openid-configuration";
    private const string Resource = "https://api.openai.com/v1";
    private const string ModelsEndpoint = "https://api.openai.com/v1/models";
    private const string ResponsesEndpoint = "https://api.openai.com/v1/responses";
    private const string DynamicClientId = "dynamic_agent_client";
    private const string AgentName = "ChatGPT Desktop Local Bridge";
    private const string RequiredPlanScope = "chatgpt.tokens.use.direct";
    private const string RequestedScopes =
        "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };

    public static async Task<int> Main(string[] args)
    {
        try
        {
            var options = ProbeOptions.Parse(args);
            Console.WriteLine("ChatGPT plan transport probe (experimental)");
            Console.WriteLine("This probe uses the official Sign in with ChatGPT open-source flow.");
            Console.WriteLine("It never asks for or stores an OpenAI API key.");
            Console.WriteLine();

            using var http = new HttpClient
            {
                Timeout = TimeSpan.FromMinutes(10)
            };

            var discovery = await LoadDiscoveryAsync(http);
            var registration = LoadOrCreateRegistration();

            using var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            var port = ((IPEndPoint)listener.LocalEndpoint).Port;
            var redirectUri = $"http://127.0.0.1:{port}/auth/callback";

            var state = RandomBase64Url(32);
            var nonce = RandomBase64Url(32);
            var verifier = RandomBase64Url(64);
            var challenge = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));

            var clientIdForAuthorize = registration.ClientId ?? DynamicClientId;
            var authorizationUrl = BuildAuthorizationUrl(
                clientIdForAuthorize,
                registration,
                redirectUri,
                state,
                nonce,
                challenge);

            Console.WriteLine($"Host ID: {registration.HostId}");
            Console.WriteLine(
                registration.ClientId is null
                    ? "Starting first-time dynamic registration."
                    : $"Reusing issued client registration: {registration.ClientId}");
            Console.WriteLine("Opening the system browser for ChatGPT sign-in and consent...");

            Process.Start(
                new ProcessStartInfo(authorizationUrl)
                {
                    UseShellExecute = true
                });

            var callback = await ReceiveCallbackAsync(
                listener,
                state,
                TimeSpan.FromMinutes(5));

            var issuedClientId = registration.ClientId;
            if (issuedClientId is null)
            {
                issuedClientId = callback.ClientId;
                if (string.IsNullOrWhiteSpace(issuedClientId) ||
                    string.Equals(issuedClientId, DynamicClientId, StringComparison.Ordinal))
                {
                    throw new InvalidOperationException(
                        "Dynamic registration did not return an issued client_id.");
                }
            }
            else if (!string.IsNullOrWhiteSpace(callback.ClientId) &&
                     !string.Equals(
                         callback.ClientId,
                         issuedClientId,
                         StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    "The callback returned a client_id different from the saved registration.");
            }

            var tokens = await ExchangeCodeAsync(
                http,
                callback.Code,
                issuedClientId,
                verifier,
                redirectUri);

            var scopes = (tokens.Scope ?? string.Empty)
                .Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

            if (!scopes.Contains(RequiredPlanScope, StringComparer.Ordinal))
            {
                throw new InvalidOperationException(
                    $"Sign-in completed but required scope '{RequiredPlanScope}' was not granted.");
            }

            if (string.IsNullOrWhiteSpace(tokens.IdToken) ||
                string.IsNullOrWhiteSpace(tokens.AccessToken))
            {
                throw new InvalidOperationException(
                    "Token response did not contain both id_token and access_token.");
            }

            var identity = await ValidateIdTokenAsync(
                http,
                discovery,
                tokens.IdToken,
                issuedClientId,
                nonce);

            if (registration.Subject is not null &&
                !string.Equals(
                    registration.Subject,
                    identity.Subject,
                    StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    "The validated ChatGPT account differs from the account bound to this saved client registration.");
            }

            registration = registration with
            {
                ClientId = issuedClientId,
                Subject = identity.Subject,
                Email = identity.Email
            };
            SaveRegistration(registration);

            Console.WriteLine(
                identity.Email is null
                    ? $"Authenticated subject: {identity.Subject}"
                    : $"Authenticated ChatGPT account: {identity.Email}");

            var models = await ListModelsAsync(http, tokens.AccessToken);
            if (models.Count == 0)
            {
                throw new InvalidOperationException(
                    "The account returned no list-visible ChatGPT plan models.");
            }

            Console.WriteLine("Available models:");
            foreach (var model in models.Take(20))
            {
                Console.WriteLine($"  {model.Slug} — {model.DisplayName}");
            }

            var selectedModel = options.Model ??
                                models.First().Slug;

            if (!models.Any(model =>
                    string.Equals(
                        model.Slug,
                        selectedModel,
                        StringComparison.Ordinal)))
            {
                throw new InvalidOperationException(
                    $"Requested model '{selectedModel}' was not returned by the signed-in account.");
            }

            Console.WriteLine();
            Console.WriteLine($"Inference model: {selectedModel}");
            Console.WriteLine($"Prompt: {options.Prompt}");
            Console.WriteLine("--- response ---");

            await StreamResponseAsync(
                http,
                tokens.AccessToken,
                selectedModel,
                options.Prompt);

            Console.WriteLine();
            Console.WriteLine("--- completed ---");
            Console.WriteLine(
                "PASS: official ChatGPT-plan OAuth + public Responses transport completed.");

            return 0;
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine("Probe cancelled or timed out.");
            return 2;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"FAIL: {ex.Message}");
            return 1;
        }
    }

    private static async Task<OpenIdDiscovery> LoadDiscoveryAsync(HttpClient http)
    {
        using var response = await http.GetAsync(DiscoveryEndpoint);
        response.EnsureSuccessStatusCode();

        var discovery = await response.Content.ReadFromJsonAsync<OpenIdDiscovery>(
            JsonOptions);

        if (discovery is null ||
            string.IsNullOrWhiteSpace(discovery.Issuer) ||
            string.IsNullOrWhiteSpace(discovery.JwksUri))
        {
            throw new InvalidOperationException(
                "OpenAI OpenID discovery document is incomplete.");
        }

        return discovery;
    }

    private static string BuildAuthorizationUrl(
        string clientId,
        ProbeRegistration registration,
        string redirectUri,
        string state,
        string nonce,
        string codeChallenge)
    {
        var parameters = new Dictionary<string, string>
        {
            ["client_id"] = clientId,
            ["ext_agent_host_id"] = registration.HostId,
            ["response_type"] = "code",
            ["redirect_uri"] = redirectUri,
            ["scope"] = RequestedScopes,
            ["resource"] = Resource,
            ["state"] = state,
            ["nonce"] = nonce,
            ["code_challenge_method"] = "S256",
            ["code_challenge"] = codeChallenge
        };

        if (registration.ClientId is null)
        {
            parameters["agent_name_hint"] = AgentName;
        }

        var query = string.Join(
            "&",
            parameters.Select(
                pair =>
                    $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value)}"));

        return AuthorizationEndpoint + "?" + query;
    }

    private static async Task<AuthorizationCallback> ReceiveCallbackAsync(
        TcpListener listener,
        string expectedState,
        TimeSpan timeout)
    {
        using var timeoutCts = new CancellationTokenSource(timeout);
        using var client = await listener.AcceptTcpClientAsync(timeoutCts.Token);
        await using var stream = client.GetStream();
        using var reader = new StreamReader(
            stream,
            Encoding.ASCII,
            detectEncodingFromByteOrderMarks: false,
            leaveOpen: true);

        var requestLine = await reader.ReadLineAsync(timeoutCts.Token);
        if (string.IsNullOrWhiteSpace(requestLine))
        {
            throw new InvalidOperationException("OAuth callback contained no HTTP request line.");
        }

        string? line;
        do
        {
            line = await reader.ReadLineAsync(timeoutCts.Token);
        } while (!string.IsNullOrEmpty(line));

        var parts = requestLine.Split(' ', 3);
        if (parts.Length < 2 ||
            !string.Equals(parts[0], "GET", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("OAuth callback was not an HTTP GET.");
        }

        var target = parts[1];
        var callbackUri = new Uri("http://127.0.0.1" + target);
        if (!string.Equals(
                callbackUri.AbsolutePath,
                "/auth/callback",
                StringComparison.Ordinal))
        {
            await WriteBrowserResponseAsync(
                stream,
                HttpStatusCode.NotFound,
                "Unexpected callback path.");
            throw new InvalidOperationException("OAuth callback path did not match /auth/callback.");
        }

        var query = ParseQuery(callbackUri.Query);

        if (!query.TryGetValue("state", out var returnedState) ||
            !CryptographicOperations.FixedTimeEquals(
                Encoding.UTF8.GetBytes(expectedState),
                Encoding.UTF8.GetBytes(returnedState)))
        {
            await WriteBrowserResponseAsync(
                stream,
                HttpStatusCode.BadRequest,
                "Invalid OAuth state. You can close this tab.");
            throw new InvalidOperationException("OAuth state validation failed.");
        }

        if (query.TryGetValue("error", out var oauthError))
        {
            var description = query.TryGetValue("error_description", out var value)
                ? value
                : oauthError;
            await WriteBrowserResponseAsync(
                stream,
                HttpStatusCode.BadRequest,
                "ChatGPT authorization was not completed. You can close this tab.");
            throw new InvalidOperationException(
                $"OpenAI authorization returned '{oauthError}': {description}");
        }

        if (!query.TryGetValue("code", out var code) ||
            string.IsNullOrWhiteSpace(code))
        {
            await WriteBrowserResponseAsync(
                stream,
                HttpStatusCode.BadRequest,
                "Authorization code missing. You can close this tab.");
            throw new InvalidOperationException(
                "OAuth callback did not contain an authorization code.");
        }

        query.TryGetValue("client_id", out var clientId);

        await WriteBrowserResponseAsync(
            stream,
            HttpStatusCode.OK,
            "ChatGPT authorization completed. You can close this tab and return to the probe.");

        return new AuthorizationCallback(code, clientId);
    }

    private static async Task WriteBrowserResponseAsync(
        NetworkStream stream,
        HttpStatusCode status,
        string message)
    {
        var body =
            "<!doctype html><html><meta charset=\"utf-8\"><title>ChatGPT Desktop Local Bridge</title>" +
            "<body><h2>ChatGPT Desktop Local Bridge</h2><p>" +
            WebUtility.HtmlEncode(message) +
            "</p></body></html>";
        var bytes = Encoding.UTF8.GetBytes(body);
        var headers =
            $"HTTP/1.1 {(int)status} {status}\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            $"Content-Length: {bytes.Length}\r\n" +
            "Connection: close\r\n\r\n";

        var headerBytes = Encoding.ASCII.GetBytes(headers);
        await stream.WriteAsync(headerBytes);
        await stream.WriteAsync(bytes);
        await stream.FlushAsync();
    }

    private static async Task<TokenResponse> ExchangeCodeAsync(
        HttpClient http,
        string code,
        string clientId,
        string verifier,
        string redirectUri)
    {
        using var content = new FormUrlEncodedContent(
            new Dictionary<string, string>
            {
                ["grant_type"] = "authorization_code",
                ["code"] = code,
                ["redirect_uri"] = redirectUri,
                ["client_id"] = clientId,
                ["code_verifier"] = verifier,
                ["resource"] = Resource
            });

        using var response = await http.PostAsync(TokenEndpoint, content);
        var json = await response.Content.ReadAsStringAsync();

        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                $"OpenAI token exchange failed with HTTP {(int)response.StatusCode}.");
        }

        return JsonSerializer.Deserialize<TokenResponse>(json, JsonOptions)
               ?? throw new InvalidOperationException("OpenAI token response was empty.");
    }

    private static async Task<ValidatedIdentity> ValidateIdTokenAsync(
        HttpClient http,
        OpenIdDiscovery discovery,
        string idToken,
        string clientId,
        string expectedNonce)
    {
        var jwksJson = await http.GetStringAsync(discovery.JwksUri);
        var keySet = new JsonWebKeySet(jwksJson);

        var validationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = discovery.Issuer,
            ValidateAudience = true,
            ValidAudience = clientId,
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true,
            RequireSignedTokens = true,
            RequireExpirationTime = true,
            IssuerSigningKeys = keySet.GetSigningKeys(),
            ClockSkew = TimeSpan.FromSeconds(5)
        };

        var handler = new JwtSecurityTokenHandler
        {
            MapInboundClaims = false
        };

        var principal = handler.ValidateToken(
            idToken,
            validationParameters,
            out _);

        var nonce = principal.FindFirst("nonce")?.Value;
        if (string.IsNullOrWhiteSpace(nonce) ||
            !CryptographicOperations.FixedTimeEquals(
                Encoding.UTF8.GetBytes(expectedNonce),
                Encoding.UTF8.GetBytes(nonce)))
        {
            throw new SecurityTokenValidationException(
                "ID token nonce did not match the authorization request.");
        }

        var subject = principal.FindFirst("sub")?.Value;
        if (string.IsNullOrWhiteSpace(subject))
        {
            throw new SecurityTokenValidationException(
                "ID token does not contain a subject.");
        }

        return new ValidatedIdentity(
            subject,
            principal.FindFirst("email")?.Value,
            principal.FindFirst("name")?.Value);
    }

    private static async Task<IReadOnlyList<ModelInfo>> ListModelsAsync(
        HttpClient http,
        string accessToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, ModelsEndpoint);
        request.Headers.Authorization =
            new AuthenticationHeaderValue("Bearer", accessToken);

        using var response = await http.SendAsync(request);
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                $"Model discovery failed with HTTP {(int)response.StatusCode}.");
        }

        using var document = JsonDocument.Parse(
            await response.Content.ReadAsStringAsync());

        if (!document.RootElement.TryGetProperty("models", out var modelsElement) ||
            modelsElement.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidOperationException(
                "Model discovery response did not contain a models array.");
        }

        var models = new List<ModelInfo>();
        foreach (var model in modelsElement.EnumerateArray())
        {
            if (!model.TryGetProperty("visibility", out var visibility) ||
                !string.Equals(
                    visibility.GetString(),
                    "list",
                    StringComparison.Ordinal))
            {
                continue;
            }

            var slug = model.TryGetProperty("slug", out var slugElement)
                ? slugElement.GetString()
                : null;
            var displayName = model.TryGetProperty(
                    "display_name",
                    out var displayNameElement)
                ? displayNameElement.GetString()
                : null;

            if (!string.IsNullOrWhiteSpace(slug))
            {
                models.Add(
                    new ModelInfo(
                        slug,
                        string.IsNullOrWhiteSpace(displayName)
                            ? slug
                            : displayName));
            }
        }

        return models;
    }

    private static async Task StreamResponseAsync(
        HttpClient http,
        string accessToken,
        string model,
        string prompt)
    {
        var body = JsonSerializer.Serialize(
            new
            {
                model,
                input = new[]
                {
                    new
                    {
                        role = "user",
                        content = prompt
                    }
                },
                store = false,
                stream = true
            });

        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            ResponsesEndpoint);
        request.Headers.Authorization =
            new AuthenticationHeaderValue("Bearer", accessToken);
        request.Headers.Accept.Add(
            new MediaTypeWithQualityHeaderValue("text/event-stream"));
        request.Content = new StringContent(
            body,
            Encoding.UTF8,
            "application/json");

        using var response = await http.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead);

        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                $"Responses request failed with HTTP {(int)response.StatusCode}.");
        }

        await using var responseStream =
            await response.Content.ReadAsStreamAsync();
        using var reader = new StreamReader(responseStream);

        var completed = false;
        while (await reader.ReadLineAsync() is { } line)
        {
            if (!line.StartsWith("data:", StringComparison.Ordinal))
            {
                continue;
            }

            var data = line[5..].TrimStart();
            if (data.Length == 0 || data == "[DONE]")
            {
                continue;
            }

            using var eventDocument = JsonDocument.Parse(data);
            var root = eventDocument.RootElement;

            if (!root.TryGetProperty("type", out var typeElement))
            {
                continue;
            }

            var type = typeElement.GetString();
            switch (type)
            {
                case "response.output_text.delta":
                    if (root.TryGetProperty("delta", out var delta))
                    {
                        Console.Write(delta.GetString());
                    }

                    break;

                case "response.failed":
                    var code = "unknown_error";
                    if (root.TryGetProperty("response", out var failedResponse) &&
                        failedResponse.TryGetProperty("error", out var error) &&
                        error.ValueKind == JsonValueKind.Object &&
                        error.TryGetProperty("code", out var codeElement))
                    {
                        code = codeElement.GetString() ?? code;
                    }

                    throw new InvalidOperationException(
                        $"Responses stream reported failure: {code}");

                case "response.incomplete":
                    throw new InvalidOperationException(
                        "Responses stream ended with response.incomplete.");

                case "response.completed":
                    completed = true;
                    break;
            }
        }

        if (!completed)
        {
            throw new InvalidOperationException(
                "Responses stream ended without response.completed.");
        }
    }

    private static ProbeRegistration LoadOrCreateRegistration()
    {
        var path = GetRegistrationPath();
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);

        if (File.Exists(path))
        {
            var stored = JsonSerializer.Deserialize<ProbeRegistration>(
                File.ReadAllText(path),
                JsonOptions);

            if (stored is not null &&
                stored.HostId.StartsWith("urn:uuid:", StringComparison.Ordinal))
            {
                return stored;
            }
        }

        var registration = new ProbeRegistration(
            "urn:uuid:" + Guid.NewGuid().ToString(),
            null,
            null,
            null);
        SaveRegistration(registration);
        return registration;
    }

    private static void SaveRegistration(ProbeRegistration registration)
    {
        var path = GetRegistrationPath();
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";

        try
        {
            File.WriteAllText(
                temp,
                JsonSerializer.Serialize(registration, JsonOptions));
            File.Move(temp, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temp))
            {
                File.Delete(temp);
            }
        }
    }

    private static string GetRegistrationPath() =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ChatGptDesktopLocalBridge",
            "experiments",
            "chatgpt-plan-transport",
            "registration.json");

    private static Dictionary<string, string> ParseQuery(string query)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        var trimmed = query.StartsWith('?') ? query[1..] : query;

        foreach (var pair in trimmed.Split(
                     '&',
                     StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = pair.Split('=', 2);
            var key = UrlDecode(parts[0]);
            var value = parts.Length == 2
                ? UrlDecode(parts[1])
                : string.Empty;
            result[key] = value;
        }

        return result;
    }

    private static string UrlDecode(string value) =>
        Uri.UnescapeDataString(value.Replace("+", " ", StringComparison.Ordinal));

    private static string RandomBase64Url(int bytes)
    {
        var data = RandomNumberGenerator.GetBytes(bytes);
        return Base64Url(data);
    }

    private static string Base64Url(byte[] data) =>
        Convert.ToBase64String(data)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');

    private sealed record AuthorizationCallback(
        string Code,
        string? ClientId);

    private sealed record ValidatedIdentity(
        string Subject,
        string? Email,
        string? Name);

    private sealed record ModelInfo(
        string Slug,
        string DisplayName);

    private sealed record ProbeRegistration(
        [property: JsonPropertyName("ext_agent_host_id")] string HostId,
        [property: JsonPropertyName("client_id")] string? ClientId,
        [property: JsonPropertyName("subject")] string? Subject,
        [property: JsonPropertyName("email")] string? Email);

    private sealed class OpenIdDiscovery
    {
        [JsonPropertyName("issuer")]
        public string Issuer { get; set; } = string.Empty;

        [JsonPropertyName("jwks_uri")]
        public string JwksUri { get; set; } = string.Empty;
    }

    private sealed class TokenResponse
    {
        [JsonPropertyName("access_token")]
        public string? AccessToken { get; set; }

        [JsonPropertyName("id_token")]
        public string? IdToken { get; set; }

        [JsonPropertyName("refresh_token")]
        public string? RefreshToken { get; set; }

        [JsonPropertyName("token_type")]
        public string? TokenType { get; set; }

        [JsonPropertyName("expires_in")]
        public int ExpiresIn { get; set; }

        [JsonPropertyName("scope")]
        public string? Scope { get; set; }
    }

    private sealed record ProbeOptions(
        string Prompt,
        string? Model)
    {
        public static ProbeOptions Parse(string[] args)
        {
            string? model = null;
            var promptParts = new List<string>();

            for (var index = 0; index < args.Length; index++)
            {
                if (string.Equals(
                        args[index],
                        "--model",
                        StringComparison.OrdinalIgnoreCase))
                {
                    if (++index >= args.Length)
                    {
                        throw new ArgumentException("--model requires a value.");
                    }

                    model = args[index];
                    continue;
                }

                promptParts.Add(args[index]);
            }

            var prompt = promptParts.Count == 0
                ? "Say exactly: ChatGPT plan transport works."
                : string.Join(" ", promptParts);

            return new ProbeOptions(prompt, model);
        }
    }
}
