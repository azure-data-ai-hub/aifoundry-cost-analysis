# Offline checks for query construction, attribution, token counts, and reporting.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/foundry_costs.ps1"

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message. Expected '$Expected', got '$Actual'." }
}

$payload = Get-Payload '' '' $false
Assert-Equal $payload.dataset.aggregation.totalUsage.name 'UsageQuantity' 'Usage aggregation'
Assert-Equal $payload.dataset.filter.dimensions.values[0] 'microsoft.cognitiveservices/accounts' 'Default filter'
$custom = Get-Payload '2026-10-01' '2026-10-31' $true
Assert-Equal $custom.timePeriod.to '2026-10-31T23:59:59+00:00' 'Inclusive end'
if ($custom.dataset.Contains('filter')) { throw 'All-resources payload should not have a filter.' }
try { Get-Payload '2026-10-02' '2026-10-01' $false; throw 'Expected invalid date range to fail.' }
catch { if ($_.Exception.Message -eq 'Expected invalid date range to fail.') { throw } }

Assert-Equal (Get-TokenUsage '5.4 mini Inp Gl 1M Tokens' '0.256217') 256217 'Million-token conversion'
Assert-Equal (Get-TokenUsage 'Input 1,000 Tokens' '0.02') 20 'Thousand-token conversion'
Assert-Equal (Get-TokenUsage 'Input 1 Tokens' '0') 0 'Zero token count'
Assert-Equal (Get-TokenUsage 'Input 1M Tokens' '-0.01') -10000 'Negative token count'
if ($null -ne (Get-TokenUsage 'Input Tokens' '10')) { throw 'Unknown token units must be unavailable.' }
if ($null -ne (Get-TokenUsage 'Input 1 Tokens' '0.5')) { throw 'Fractional tokens must be unavailable.' }
if ($null -ne (Get-TokenUsage 'Capacity 1K Tokens per second' '10')) { throw 'Token rates must be unavailable.' }

$deployments = @(
    @{ name = 'first'; properties = @{ model = @{ name = 'gpt-4o' } } }
    @{ name = 'second'; properties = @{ model = @{ name = 'gpt-4o-mini' } } }
)
Assert-Equal (Get-Model 'GPT-4o-mini Input Tokens' $deployments) 'gpt-4o-mini' 'Model prefix matching'
if ($null -ne (Get-Model 'shared capacity' $deployments)) { throw 'Unknown model must remain unassigned.' }

$account = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/ai'
$accounts = @(@{ id = $account; name = 'ai'; deployments = $deployments })
$costs = @(
    @{ ResourceId = $account; Meter = 'gpt-4o Input 1M Tokens'; Currency = 'USD'; cost = [decimal]::Parse('1.10', $script:Culture); UsageQuantity = [decimal]::Parse('0.256217', $script:Culture) }
    @{ ResourceId = $account; Meter = 'gpt-4o Input Tokens'; Currency = 'USD'; cost = [decimal]::Parse('-0.10', $script:Culture) }
    @{ ResourceId = ''; Meter = 'other'; Currency = 'EUR'; cost = [decimal]'3' }
)
$report = New-Report 'sub' $payload $costs $accounts @{}
Assert-Equal $report.details.Count 3 'All cost rows retained'
Assert-Equal $report.details[0].tokens_consumed 256217 'Detail tokens'
Assert-Equal $report.details[0].model 'gpt-4o' 'Model attribution'
Assert-Equal ($report.subscription_totals | Where-Object currency -eq 'USD').cost '1.00' 'USD total preserves credits'
Assert-Equal ($report.subscription_totals | Where-Object currency -eq 'EUR').cost '3' 'Currency totals remain separate'
if ($report.details[0].Contains('token_status') -or $report.details[0].Contains('usage_quantity')) { throw 'Unexpected token metadata in detail.' }

$parsed = Read-Json '{"amount":0.19216275,"values":[0,1.25],"empty":[]}'
Assert-Equal $parsed.amount ([decimal]::Parse('0.19216275', $script:Culture)) 'JSON decimal precision'
Assert-Equal $parsed.values.Count 2 'JSON arrays'
Assert-Equal $parsed.empty.Count 0 'Empty JSON arrays'

# Replace ARM calls with two fixture pages to check pagination without Azure access.
$script:Calls = [System.Collections.Generic.List[object]]::new()
function Invoke-Arm([string]$Method, [string]$Url, $RequestPayload = $null) {
    $script:Calls.Add(@{ method = $Method; url = $Url; payload = $RequestPayload })
    if ($script:Calls.Count -eq 1) {
        return Read-Json '{"properties":{"columns":[{"name":"Currency"},{"name":"Cost"},{"name":"Meter"},{"name":"ResourceId"},{"name":"UsageQuantity"}],"rows":[["USD",0.1,"Input 1M Tokens","account",0.1]],"nextLink":"https://management.azure.com/next"}}'
    }
    return Read-Json '{"properties":{"columns":[{"name":"Currency"},{"name":"Cost"},{"name":"Meter"},{"name":"ResourceId"},{"name":"UsageQuantity"}],"rows":[["USD",0.2,"Output 1M Tokens","account",0.2]]}}'
}
$paged = Get-Costs 'sub' $payload
Assert-Equal $paged.Count 2 'Billing pagination'
Assert-Equal ($paged[0].cost + $paged[1].cost) ([decimal]::Parse('0.3', $script:Culture)) 'Paged cost precision'
Assert-Equal $script:Calls[1].method 'POST' 'Continuation method'
Assert-Equal $script:Calls[1].url 'https://management.azure.com/next' 'Continuation URL'
if (-not [object]::ReferenceEquals($script:Calls[1].payload, $payload)) { throw 'Continuation must reuse the query payload.' }

# Exercise report orchestration with fixture costs and deployment inventory.
function Get-Costs([string]$Subscription, $Payload) { return ,$costs }
function Get-Resources([string]$Url) {
    if ($Url -like '*/deployments?*') { return ,$deployments }
    return ,@(@{ id = $account; name = 'ai'; kind = 'AIServices' })
}
$subscription = '00000000-0000-0000-0000-000000000001'
$workflowReport = Get-FoundryCostReport -SubscriptionId $subscription
Assert-Equal $workflowReport.subscription_id $subscription 'Workflow report subscription'
Assert-Equal $workflowReport.details.Count 3 'Workflow report returns structured data'
Assert-Equal $workflowReport.details[0].tokens_consumed 256217 'Workflow report token count'
Write-Output 'PowerShell tests passed.'