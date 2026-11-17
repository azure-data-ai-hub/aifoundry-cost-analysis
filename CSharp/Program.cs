using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

// Billing comes from Cost Management; current deployments provide only
// best-effort model attribution, and token counts may be partial.
public static class FoundryCosts
{
const string Arm = "https://management.azure.com";
const string AccountVersion = "2024-10-01";

public static async Task<int> Main(string[] args)
{
var options = new Dictionary<string, string?>(StringComparer.Ordinal);
try
{
    for (int index = 0; index < args.Length; index++)
    {
        string option = args[index];
        if (option is "--all-resources" or "--print-payload") options[option] = "true";
        else if (option is "--subscription-id" or "--start" or "--end" or "--mapping" or "--json" or "--csv")
        {
            if (++index == args.Length) throw new ArgumentException($"Missing value for {option}.");
            options[option] = args[index];
        }
        else throw new ArgumentException($"Unknown argument: {option}");
    }
    string? start = options.GetValueOrDefault("--start"), end = options.GetValueOrDefault("--end");
    var payload = BuildPayload(start, end, options.ContainsKey("--all-resources"));
    // Payload inspection is available without acquiring credentials.
    if (options.ContainsKey("--print-payload"))
    {
        Console.WriteLine(payload.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        return 0;
    }
    string subscription = options.GetValueOrDefault("--subscription-id") ?? Environment.GetEnvironmentVariable("AZURE_SUBSCRIPTION_ID") ?? throw new ArgumentException("--subscription-id or AZURE_SUBSCRIPTION_ID is required.");
    var report = await GetReportAsync(subscription, payload, options.GetValueOrDefault("--mapping"));
    PrintReport(report, options);
    return 0;
}
catch (Exception error) when (error is ArgumentException or IOException or HttpRequestException or JsonException or FormatException or InvalidOperationException or OverflowException or TaskCanceledException or System.ComponentModel.Win32Exception)
{
    Console.Error.WriteLine($"Error: {error.Message}");
    return 1;
}
}

/// <summary>Builds a daily Cost Management query without authenticating.</summary>
/// <param name="start">Optional first UTC date in yyyy-MM-dd format; requires end.</param>
/// <param name="end">Optional inclusive last UTC date in yyyy-MM-dd format; requires start.</param>
/// <param name="allResources">Whether to include all resource types.</param>
public static JsonNode BuildPayload(string? start = null, string? end = null, bool allResources = false)
{
    if ((start is null) != (end is null)) throw new ArgumentException("Supply both --start and --end.");
    var payload = JsonNode.Parse("""
        {"type":"ActualCost","timeframe":"MonthToDate","dataset":{"granularity":"Daily",
         "aggregation":{"totalCost":{"name":"Cost","function":"Sum"},"totalUsage":{"name":"UsageQuantity","function":"Sum"}},
         "grouping":[{"type":"Dimension","name":"ResourceId"},{"type":"Dimension","name":"Meter"}]}}
        """)!;
    // Default totals cover Cognitive Services account charges, not the entire subscription.
    if (!allResources)
        payload["dataset"]!["filter"] = JsonNode.Parse("""{"dimensions":{"name":"ResourceType","operator":"In","values":["microsoft.cognitiveservices/accounts"]}}""");
    if (start is not null && end is not null)
    {
        DateOnly first = DateOnly.ParseExact(start, "yyyy-MM-dd", CultureInfo.InvariantCulture);
        DateOnly last = DateOnly.ParseExact(end, "yyyy-MM-dd", CultureInfo.InvariantCulture);
        if (first > last) throw new ArgumentException("--start must not be after --end.");
        payload["timeframe"] = "Custom";
        payload["timePeriod"] = new JsonObject { ["from"] = $"{start}T00:00:00+00:00", ["to"] = $"{end}T23:59:59+00:00" };
    }
    return payload;
}

/// <summary>Queries billing and deployment inventory and returns a report without writing output.</summary>
/// <param name="subscriptionId">Azure subscription ID.</param>
/// <param name="payload">Cost Management request body returned by <see cref="BuildPayload"/>.</param>
/// <param name="mappingPath">Optional JSON file containing exact resource and meter mappings.</param>
/// <remarks>Requires Azure CLI login and Azure permissions. Token totals can be partial; model inference is not authoritative.</remarks>
public static async Task<Dictionary<string, object?>> GetReportAsync(string subscriptionId, JsonNode payload, string? mappingPath = null)
{
    string subscription = Guid.Parse(subscriptionId).ToString();
    // Resource IDs are case-insensitive, while exact meter mapping keys retain their case.
    var mapping = new Dictionary<string, JsonNode>(StringComparer.OrdinalIgnoreCase);
    if (mappingPath is not null)
    {
        var parsed = JsonNode.Parse(File.ReadAllText(mappingPath)) as JsonObject ?? throw new ArgumentException("Mapping must be an object keyed by billing resource ID.");
        foreach (var (resourceId, entry) in parsed)
        {
            if (entry is not JsonObject || entry["foundry_id"] is not JsonValue id || !id.TryGetValue<string>(out _) || entry["meters"] is not JsonObject meters ||
                meters.Any(pair => pair.Value is not JsonValue value || !value.TryGetValue<string>(out var model) || string.IsNullOrWhiteSpace(model)))
                throw new ArgumentException("Each mapping needs a foundry_id and an object mapping exact meter names to nonempty model names.");
            mapping[Key(resourceId)] = entry;
        }
    }
    using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(90) };
    var costs = new List<Dictionary<string, JsonNode?>>();
    string? url = $"{Arm}/subscriptions/{subscription}/providers/Microsoft.CostManagement/query?api-version=2025-03-01";
    // Cost Management continuation pages reuse the original POST body.
    while (!string.IsNullOrEmpty(url))
    {
        JsonNode page = await Request(client, HttpMethod.Post, url, payload);
        JsonNode? properties = page["properties"];
        // Billing rows are positional; use the response's column names rather than fixed indexes.
        var columns = (properties?["columns"] as JsonArray)?.Select(column => Text(column?["name"])).ToArray() ?? [];
        foreach (JsonNode? item in properties?["rows"] as JsonArray ?? [])
        {
            if (!new[] { "ResourceId", "Meter", "Currency" }.All(columns.Contains)) throw new InvalidDataException("Unexpected billing columns.");
            var values = item as JsonArray ?? throw new InvalidDataException("Invalid billing row.");
            if (values.Count != columns.Length) throw new InvalidDataException("Billing row length does not match columns.");
            var row = columns.Select((column, index) => (column, value: values[index])).ToDictionary(pair => pair.column, pair => pair.value);
            JsonNode? cost = row.GetValueOrDefault("PreTaxCost") ?? row.GetValueOrDefault("Cost") ?? row.GetValueOrDefault("totalCost");
            if (cost is null || string.IsNullOrEmpty(Text(row["Currency"]))) throw new InvalidDataException("Billing row is missing its cost or currency.");
            _ = Amount(cost);
            row["cost"] = cost;
            costs.Add(row);
        }
        url = Text(properties?["nextLink"]);
    }
    // Current inventory may omit models from deleted or historical deployments.
    var accounts = new Dictionary<string, JsonNode>(StringComparer.OrdinalIgnoreCase);
    foreach (JsonNode account in await ListResources(client, $"{Arm}/subscriptions/{subscription}/providers/Microsoft.CognitiveServices/accounts?api-version={AccountVersion}"))
    {
        if (!new[] { "aiservices", "openai" }.Contains(Text(account["kind"]).ToLowerInvariant())) continue;
        var deployments = await ListResources(client, $"{Arm}{Text(account["id"])}/deployments?api-version={AccountVersion}");
        account["deployments"] = new JsonArray(deployments.Select(deployment => deployment.DeepClone()).ToArray());
        accounts[Key(Text(account["id"]))] = account;
    }
    var details = new List<Dictionary<string, object?>>();
    foreach (var row in costs)
    {
        string resource = Text(row.GetValueOrDefault("ResourceId")), key = Key(resource);
        // Attribute deployment and project charges to their parent account.
        string accountKey = key.Split("/deployments/")[0].Split("/projects/")[0];
        mapping.TryGetValue(key, out JsonNode? entry);
        string foundryId = entry is not null ? Text(entry["foundry_id"]) : accounts.TryGetValue(accountKey, out var owner) ? Text(owner["id"]) : "";
        if (foundryId.Length == 0 && key.Contains("/providers/microsoft.cognitiveservices/accounts/")) foundryId = resource[..accountKey.Length];
        accounts.TryGetValue(Key(foundryId), out JsonNode? account);
        string meter = Text(row.GetValueOrDefault("Meter"));
        // Prefer an exact mapping, then try a conservative current-inventory match.
        string model = Text(entry?["meters"]?[meter]);
        string attribution = model.Length > 0 ? "explicit_mapping" : "unassigned";
        if (model.Length == 0 && account is not null)
        {
            model = InferModel(meter, account["deployments"] as JsonArray ?? []);
            if (model.Length > 0) attribution = "inferred_from_meter";
        }
        // Preserve unassigned charges so attribution uncertainty does not change totals.
        details.Add(new() {
            ["foundry_id"] = foundryId, ["foundry"] = foundryId.Length > 0 ? foundryId.Split('/').Last() : "Unassigned subscription charges",
            ["resource_id"] = resource, ["model"] = model.Length > 0 ? model : "Unassigned model", ["meter"] = meter,
            ["usage_date"] = Text(row.GetValueOrDefault("UsageDate")), ["tokens_consumed"] = Tokens(meter, row.GetValueOrDefault("UsageQuantity") ?? row.GetValueOrDefault("totalUsage")),
            ["attribution"] = attribution, ["currency"] = Text(row["Currency"]), ["cost"] = Amount(row["cost"])
        });
    }
    string[] warnings = [
        "Model matches inferred from meter names are not authoritative billing attribution.",
        "Current deployments do not describe deleted or historical models; use exact meter mappings.",
        "Foundry means the billing AI Services/OpenAI account, not an individual project or classic hub.",
        "Totals cover only queried resource types. The default filter excludes Marketplace and shared infrastructure, and can include non-Foundry Cognitive Services accounts.",
        "Billing data can be delayed. No billing row does not establish zero usage or zero cost.",
        "Tokens are net billed usage calculated from meter labels, not Azure Monitor measurements. Totals may be partial when token units or quantities are unavailable."
    ];
    // Sum decimal costs before converting detail amounts to invariant strings for export.
    var report = new Dictionary<string, object?> {
        ["subscription_id"] = subscription, ["query"] = payload, ["totals_scope"] = payload["dataset"]?["filter"] is null ? "All subscription resources" : "Filtered Cognitive Services accounts", ["warnings"] = warnings,
        ["subscription_totals"] = Summarize(details, []), ["foundry_totals"] = Summarize(details, ["foundry_id", "foundry"]), ["model_totals"] = Summarize(details, ["foundry_id", "foundry", "model", "attribution"]),
        ["details"] = details.Select(row => row.ToDictionary(pair => pair.Key, pair => pair.Key == "cost" ? (object?)((decimal)pair.Value!).ToString(CultureInfo.InvariantCulture) : pair.Value)).ToArray(),
        ["inventory"] = accounts.Values.Select(account => new { foundry_id = Text(account["id"]), foundry = Text(account["name"]), deployments = (account["deployments"] as JsonArray ?? []).Select(deployment => new { name = Text(deployment?["name"]), model = deployment?["properties"]?["model"]?.DeepClone() ?? new JsonObject() }).ToArray() }).ToArray()
    };
    return report;
}

static void PrintReport(Dictionary<string, object?> report, Dictionary<string, string?> options)
{
    // Presentation and optional exports are separate from collecting the report.
    string subscription = (string)report["subscription_id"]!;
    var details = (Dictionary<string, object?>[])report["details"]!;
    var warnings = (string[])report["warnings"]!;
    Console.WriteLine($"Subscription: {subscription}\nCost scope: {report["totals_scope"]}");
    foreach (var total in (List<Dictionary<string, object?>>)report["subscription_totals"]!) Console.WriteLine($"Queried resource total: {total["cost"]} {total["currency"]}");
    foreach (var total in (List<Dictionary<string, object?>>)report["foundry_totals"]!) Console.WriteLine($"Foundry total: {total["foundry"]} | {total["cost"]} {total["currency"]} | {total["foundry_id"]}");
    Console.WriteLine("\nFoundry | Model | Attribution | Cost | Currency | Tokens Consumed | Foundry ID");
    foreach (var total in (List<Dictionary<string, object?>>)report["model_totals"]!) Console.WriteLine(string.Join(" | ", new[] { "foundry", "model", "attribution", "cost", "currency", "tokens_consumed", "foundry_id" }.Select(name => total[name]?.ToString() ?? "N/A")));
    if (details.Length == 0) Console.WriteLine("No billing rows returned for this period.");
    foreach (JsonNode? account in JsonSerializer.SerializeToNode(report["inventory"])!.AsArray())
    {
        var models = (account?["deployments"] as JsonArray ?? []).Select(deployment => Text(deployment?["model"]?["name"])).Select(name => name.Length > 0 ? name : "Unknown").Distinct().Order().ToArray();
        Console.WriteLine($"Inventory: {Text(account?["foundry"])} | {(models.Length > 0 ? string.Join(", ", models) : "No deployments")}");
    }
    foreach (string warning in warnings) Console.Error.WriteLine($"Warning: {warning}");
    if (options.GetValueOrDefault("--json") is string jsonPath) File.WriteAllText(jsonPath, JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
    if (options.GetValueOrDefault("--csv") is string csvPath)
    {
        string[] fields = ["foundry_id", "foundry", "resource_id", "model", "meter", "usage_date", "attribution", "currency", "cost", "tokens_consumed"];
        using var output = new StreamWriter(csvPath, false, new UTF8Encoding(false));
        output.WriteLine(string.Join(",", fields));
        foreach (var row in details) output.WriteLine(string.Join(",", fields.Select(field => Csv(row[field]))));
    }
}

static string Text(JsonNode? value) => value?.ToString() ?? "";
static string Key(string value) => value.TrimEnd('/').ToLowerInvariant();
static decimal Amount(JsonNode? value) => decimal.Parse(Text(value), NumberStyles.Float, CultureInfo.InvariantCulture);
static string Csv(object? value)
{
    string text = Convert.ToString(value, CultureInfo.InvariantCulture) ?? "";
    return text.IndexOfAny([',', '"', '\r', '\n']) >= 0 ? $"\"{text.Replace("\"", "\"\"")}\"" : text;
}
static decimal? Tokens(string meter, JsonNode? quantity)
{
    // Unknown token units and fractional token counts remain unavailable, not zero.
    Match unit = Regex.Match(meter, @"(?<![\w.,])(\d+(?:,\d{3})*(?:\.\d+)?)\s*([KMB]?)\s+tokens?\s*$", RegexOptions.IgnoreCase);
    if (!unit.Success || quantity is null || !decimal.TryParse(Text(quantity), NumberStyles.Float, CultureInfo.InvariantCulture, out decimal amount)) return null;
    decimal multiplier = unit.Groups[2].Value.ToUpperInvariant() switch { "K" => 1000m, "M" => 1000000m, "B" => 1000000000m, _ => 1m };
    try { decimal count = amount * decimal.Parse(unit.Groups[1].Value.Replace(",", ""), CultureInfo.InvariantCulture) * multiplier; return decimal.Truncate(count) == count ? decimal.Truncate(count) : null; }
    catch (OverflowException) { return null; }
}
static string InferModel(string meter, JsonArray deployments)
{
    static string Normalize(string label) => Regex.Replace(label.ToLowerInvariant(), "[^a-z0-9]+", " ").Trim();
    string label = $" {Normalize(meter)} ";
    var candidates = deployments.Select(item => Text(item?["properties"]?["model"]?["name"])).Where(name => name.Length > 0).Distinct().Select(name => (name, normalized: Normalize(name))).Where(item => label.Contains($" {item.normalized} ")).ToArray();
    // Prefer a longer nested model name; unrelated multiple matches are ambiguous.
    var matches = candidates.Where(item => !candidates.Any(other => item.normalized != other.normalized && $" {other.normalized} ".Contains($" {item.normalized} "))).ToArray();
    return matches.Length == 1 ? matches[0].name : "";
}
static List<Dictionary<string, object?>> Summarize(List<Dictionary<string, object?>> rows, string[] dimensions)
{
    // Currency is always part of the grouping key; never combine unlike currencies.
    return rows.GroupBy(row => JsonSerializer.Serialize(dimensions.Append("currency").Select(name => row[name]).ToArray())).OrderBy(group => group.Key, StringComparer.Ordinal).Select(group => {
        var result = dimensions.Append("currency").ToDictionary(name => name, name => group.First()[name]);
        result["cost"] = group.Sum(row => (decimal)row["cost"]!).ToString(CultureInfo.InvariantCulture);
        // No known counts is null, while a known zero is a valid total.
        var tokens = group.Where(row => row["tokens_consumed"] is not null).Select(row => (decimal)row["tokens_consumed"]!).ToArray();
        result["tokens_consumed"] = tokens.Length > 0 ? tokens.Sum() : null;
        return result;
    }).ToList();
}
static async Task<List<JsonNode>> ListResources(HttpClient client, string? url)
{
    // ARM inventory pages use GET; billing pages use POST with the query body.
    var result = new List<JsonNode>();
    while (!string.IsNullOrEmpty(url))
    {
        var page = await Request(client, HttpMethod.Get, url, null);
        result.AddRange((page["value"] as JsonArray ?? []).Where(item => item is not null).Select(item => item!.DeepClone()));
        url = Text(page["nextLink"]);
    }
    return result;
}
static async Task<JsonNode> Request(HttpClient client, HttpMethod method, string url, JsonNode? payload)
{
    var uri = new Uri(url);
    // Validate pagination links before obtaining or sending an ARM access token.
    if (uri.Scheme != Uri.UriSchemeHttps || uri.Authority != "management.azure.com") throw new ArgumentException("Refusing to send credentials outside Azure Resource Manager.");
    for (int attempt = 0; attempt < 5; attempt++)
    {
        using var request = new HttpRequestMessage(method, uri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await AzureToken.Get());
        if (payload is not null) request.Content = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json");
        using var response = await client.SendAsync(request);
        string content = await response.Content.ReadAsStringAsync();
        if (response.IsSuccessStatusCode) return string.IsNullOrWhiteSpace(content) ? new JsonObject() : JsonNode.Parse(content) ?? new JsonObject();
        // Retry transient responses using Azure's delay or exponential backoff.
        if ((int)response.StatusCode is 429 or 500 or 502 or 503 or 504 && attempt < 4)
        {
            string retry = response.Headers.TryGetValues("x-ms-ratelimit-microsoft.consumption-retry-after", out var values) ? values.First() : response.Headers.RetryAfter?.Delta?.TotalSeconds.ToString(CultureInfo.InvariantCulture) ?? "";
            int delay = int.TryParse(retry, out int seconds) ? seconds : 1 << attempt;
            if (delay > 120) throw new HttpRequestException($"Azure throttled the query; retry after {retry} seconds.");
            await Task.Delay(TimeSpan.FromSeconds(Math.Max(0, delay)));
            continue;
        }
        throw new HttpRequestException($"ARM HTTP {(int)response.StatusCode}: {content}");
    }
    throw new HttpRequestException("ARM retry limit exceeded.");
}
}

static class AzureToken
{
    private static string? token;
    private static DateTime acquiredAt;

    public static async Task<string> Get()
    {
        // Reuse a recently acquired token instead of invoking Azure CLI for each page.
        if (token is not null && DateTime.UtcNow - acquiredAt < TimeSpan.FromMinutes(30)) return token;
        string executable = OperatingSystem.IsWindows() ? "az.cmd" : "az";
        // Resolve the Windows wrapper on PATH so its bundled Python is found correctly.
        string? executablePath = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Select(directory => Path.Combine(directory.Trim('"'), executable)).FirstOrDefault(File.Exists);
        var startInfo = new ProcessStartInfo { FileName = executablePath ?? executable, RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
        foreach (string argument in new[] { "account", "get-access-token", "--resource", "https://management.azure.com/", "--query", "accessToken", "-o", "tsv" }) startInfo.ArgumentList.Add(argument);
        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("Could not start Azure CLI.");
        string value = (await process.StandardOutput.ReadToEndAsync()).Trim();
        await process.WaitForExitAsync();
        if (process.ExitCode != 0 || value.Length == 0) throw new InvalidOperationException($"Azure CLI authentication failed (exit code {process.ExitCode}). Run az login.");
        token = value;
        acquiredAt = DateTime.UtcNow;
        return value;
    }
}