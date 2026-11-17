# Foundry Model Cost Analysis

Command-line reports for one Azure subscription, implemented in Python, C#, and
PowerShell. Queries Cognitive Services
account charges across all resource groups, discovers AI Services/OpenAI accounts and
their current model deployments, and displays filtered, Foundry account, and model
totals. JSON includes the deployment inventory and daily billing rows; CSV contains
daily billing rows with the usage date and tokens consumed.
Currency totals are never combined. Credits retain their negative amounts.

## Correct API

The supplied `Microsoft.Insights/metrics?api-version=2023-10-01` URL is an Azure
Monitor **GET** endpoint for operational metrics, not billing. Its response's
`cost` field represents relative query complexity, not a monetary charge.
It does not accept a Cost Management POST payload.

This program instead sends a JSON body to:

```text
POST https://management.azure.com/subscriptions/{subscriptionId}/providers/Microsoft.CostManagement/query?api-version=2025-03-01
```

The default body retrieves month-to-date actual costs across the subscription,
filtered to `microsoft.cognitiveservices/accounts`:

```json
{
  "type": "ActualCost",
  "timeframe": "MonthToDate",
  "dataset": {
    "granularity": "Daily",
    "aggregation": {
      "totalCost": { "name": "Cost", "function": "Sum" },
      "totalUsage": { "name": "UsageQuantity", "function": "Sum" }
    },
    "grouping": [
      { "type": "Dimension", "name": "ResourceId" },
      { "type": "Dimension", "name": "Meter" }
    ],
    "filter": {
      "dimensions": {
        "name": "ResourceType",
        "operator": "In",
        "values": ["microsoft.cognitiveservices/accounts"]
      }
    }
  }
}
```

Cost Management permits at most two grouping clauses. The program resolves
Foundry accounts from resource IDs locally and follows all billing and inventory
pages. Billing continuation requests use POST with the original body. Transient
HTTP failures are retried with bounded attempts and throttling delays.

This is a resource-type filter, not a resource-group filter: matching accounts in
different resource groups remain included. It also includes other Cognitive Services
account kinds, not only Foundry/OpenAI. Daily rows are summed for period totals.
The JSON `subscription_totals` field is retained for compatibility but represents
only queried charges; `totals_scope` states the scope explicitly.

## Run

Run these commands from the repository root. The Python version requires Python
3.10+ and uses Azure Identity (Azure CLI, managed identity, or a configured service
principal):

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r Python/requirements.txt
az login
python Python/foundry_costs.py --subscription-id "<subscription-guid>" --json report.json --csv report.csv
```

The C# version requires the .NET 9 SDK and Azure CLI; the PowerShell version
requires PowerShell 7.5+ and Azure CLI. Both use the signed-in Azure CLI account:

```powershell
az login
dotnet run --project CSharp/FoundryCosts.csproj -- --subscription-id "<subscription-guid>" --json report.json --csv report.csv
./PowerShell/foundry_costs.ps1 -SubscriptionId "<subscription-guid>" -Json report.json -Csv report.csv
```

For PowerShell, use `-Start`, `-End`, `-Mapping`, `-AllResources`, and
`-PrintPayload` in place of the Python/C# options shown below. Paths for reports
and mappings are relative to the current working directory. Each command writes
to the specified files; use different filenames to retain multiple reports.

### Script Workflows

Each implementation separates report generation from printing and file output.
To extend a workflow in the same file, call `get_cost_report` in Python,
`GetReportAsync` in C#, or `Get-FoundryCostReport` in PowerShell. These functions
return the report data, including `model_totals`, `details`, and `warnings`.
Query building, model matching, and token conversion are also separate functions
in each implementation.

Alternatively set `AZURE_SUBSCRIPTION_ID`. Python authentication uses
`DefaultAzureCredential`, supporting Azure CLI login, managed identities, and
service principals configured through Azure Identity environment variables.
Never put credentials in the script or mappings.

Grant the identity **Cost Management Reader** at subscription scope and **Reader**
for account/deployment discovery. Your billing agreement must support Cost
Management and allow access to charges; EA/MCA billing policies may impose
additional restrictions. A discovery failure stops the report instead of silently
presenting partial inventory as complete.

For a custom UTC date range (both dates inclusive):

```powershell
python Python/foundry_costs.py --subscription-id "<subscription-guid>" --start 2026-10-01 --end 2026-10-31 --json report.json
```

To inspect the exact POST body without credentials or network calls:

```powershell
python Python/foundry_costs.py --print-payload
```

To include every subscription resource type (including Marketplace and shared
infrastructure), explicitly disable the default filter:

```powershell
python Python/foundry_costs.py --subscription-id "<subscription-guid>" --all-resources --json report.json
```

## Tokens Consumed

The console model table, JSON details and totals, and CSV include tokens consumed.
No additional Azure Monitor permissions are needed.

Token counts are calculated from billed `UsageQuantity`, using an explicit token
unit at the end of the meter name. For example, `0.256217` units of a meter labeled
`1M Tokens` converts to **256,217 tokens**. Supported labels include `1K Tokens`,
`1M Tokens`, `1000 Tokens`, and `1,000 Tokens`. Counts are not derived from cost
or public model prices. Validate meter-label units against your Cost Details
`UnitOfMeasure` for authoritative reconciliation.

Unknown token units, missing/invalid quantities, and conversions yielding fractional
tokens are unavailable, never zero or rounded. Non-token charges such as hosting
hours have no token count. Unavailable counts display as `N/A` in the console,
`null` in JSON, and blank in CSV. Totals include only available counts and may
therefore be partial when token units or quantities are missing.

Each billing row contributes once, including separate input, output, and cached-input
meters. These are **net billed token quantities**, not independent measurements of
actual inference usage: refunds and billing adjustments can produce negative counts,
and billing data can lag. Unknown model attribution remains unassigned even when its
token unit can be converted. The existing date range and resource filter apply to
both costs and quantities.

## Attribution Limits

In this report, a "Foundry" is the billing `Microsoft.CognitiveServices/accounts`
resource of kind `AIServices` or `OpenAI`, not an individual project or classic
Machine Learning hub. Current account/deployment inventory uses API `2024-10-01`.
Project-level, classic hub, dedicated compute, and Marketplace costs do not have a
universal automatic join to that account.

Cost Management does not universally expose a model or deployment dimension.
The script matches model names from current deployments against meter names,
using word boundaries and preferring the more specific nested model name. Such
rows are labeled **inferred_from_meter**, not authoritative per-model billing.
Versions/deployments of the same model cannot be split from these billing rows.
Historical, renamed, deleted, abbreviated, or shared meters may not match.

Unmatched rows remain **Unassigned model**. Unrelated or unmapped resources remain
**Unassigned subscription charges**. No charge is discarded or evenly distributed
between models. Non-model account charges can be included in Foundry account
totals. Model totals are attributed billed amounts, not necessarily complete model
costs. Inventory-only models are shown without inventing a zero-cost billing row.

To resolve ambiguous meters, provide a JSON mapping with this shape. To associate
a Marketplace billing resource with a Foundry account, also use `--all-resources`,
since the default filter excludes Marketplace and shared infrastructure:

```json
{
  "/subscriptions/SUB/resourceGroups/RG/providers/Microsoft.CognitiveServices/accounts/ACCOUNT": {
    "foundry_id": "/subscriptions/SUB/resourceGroups/RG/providers/Microsoft.CognitiveServices/accounts/ACCOUNT",
    "meters": {
      "EXACT INPUT METER NAME FROM REPORT": "gpt-4o",
      "EXACT OUTPUT METER NAME FROM REPORT": "gpt-4o"
    }
  }
}
```

Use the full billing resource ID as the key. IDs are matched case-insensitively;
meter names must match exactly. For Marketplace or classic resources, replace the
key with that billing resource's ID, use `--all-resources`, and set `foundry_id` to the intended owning
account, project, or hub. These associations are user-supplied, not discovered.
Mappings may identify historical models absent from the current inventory.
Validate them against your billing details for the selected period.

```powershell
python Python/foundry_costs.py --subscription-id "<subscription-guid>" --mapping mapping.json --json report.json
```

Mapped model rows are labeled **explicit_mapping**. Review the JSON/CSV detail
rows for unassigned charges. Billing data can lag usage and remains subject to
adjustment. Empty billing results are not proof of zero cost. For authoritative
attribution unavailable in these dimensions, use Cost Details/Exports and billing
metadata or maintain a verified resource/meter mapping.

## Tests

```powershell
python -m unittest discover -s Python -v
./PowerShell/test_foundry_costs.ps1
./CSharp/test_foundry_costs.ps1
```

Tests are offline. Live execution requires an accessible subscription and the
permissions above. C# and PowerShell use .NET decimal arithmetic (up to 28-29
significant digits); Python uses its decimal context.

References:

- [Cost Management Query API](https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage?view=rest-cost-management-2025-03-01)
- [Azure Monitor Metrics API](https://learn.microsoft.com/en-us/rest/api/monitor/metrics/list?view=rest-monitor-2023-10-01)
- [Foundry hub and Marketplace cost considerations](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/costs-plan-manage)