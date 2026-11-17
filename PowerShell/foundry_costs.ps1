# Query billed costs and token quantities, then combine them with the current
# AI Services/OpenAI deployment inventory for best-effort model attribution.
param(
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [string]$Start,
    [string]$End,
    [string]$Mapping,
    [switch]$AllResources,
    [string]$Json,
    [string]$Csv,
    [switch]$PrintPayload
)

$ErrorActionPreference = 'Stop'
$script:Arm = 'https://management.azure.com'
# Cache the Azure CLI token within this script to avoid launching az for every page.
$script:Token = $null
$script:TokenTime = [datetime]::MinValue
$script:Culture = [System.Globalization.CultureInfo]::InvariantCulture

function Convert-JsonValue([System.Text.Json.JsonElement]$Element) {
    # Preserve decimal precision instead of converting billing amounts to floating point.
    switch ($Element.ValueKind) {
        'Object' {
            $object = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) { $object[$property.Name] = Convert-JsonValue $property.Value }
            return ,$object
        }
        'Array' {
            $items = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) { $items.Add((Convert-JsonValue $item)) }
            return ,$items.ToArray()
        }
        'String' { return $Element.GetString() }
        'Number' { return $Element.GetDecimal() }
        'True' { return $true }
        'False' { return $false }
        default { return $null }
    }
}

function Read-Json([string]$Content) {
    # Convert through System.Text.Json so JSON numbers remain decimal values.
    $document = [System.Text.Json.JsonDocument]::Parse($Content)
    try { return Convert-JsonValue $document.RootElement }
    finally { $document.Dispose() }
}

function Get-Payload([string]$First, [string]$Last, [bool]$IncludeAll) {
    # The two grouping dimensions are the resource ID and billing meter.
    if ([bool]$First -ne [bool]$Last) { throw 'Supply both -Start and -End.' }
    $payload = [ordered]@{
        type = 'ActualCost'; timeframe = 'MonthToDate'
        dataset = [ordered]@{
            granularity = 'Daily'
            aggregation = [ordered]@{ totalCost = @{ name = 'Cost'; function = 'Sum' }; totalUsage = @{ name = 'UsageQuantity'; function = 'Sum' } }
            grouping = @(@{ type = 'Dimension'; name = 'ResourceId' }, @{ type = 'Dimension'; name = 'Meter' })
        }
    }
    # By default, totals cover Cognitive Services accounts rather than all charges.
    if (-not $IncludeAll) { $payload.dataset.filter = @{ dimensions = @{ name = 'ResourceType'; operator = 'In'; values = @('microsoft.cognitiveservices/accounts') } } }
    if ($First -and $Last) {
        $firstDate = [datetime]::ParseExact($First, 'yyyy-MM-dd', $script:Culture)
        $lastDate = [datetime]::ParseExact($Last, 'yyyy-MM-dd', $script:Culture)
        if ($firstDate -gt $lastDate) { throw '-Start must not be after -End.' }
        $payload.timeframe = 'Custom'
        $payload.timePeriod = @{ from = "${First}T00:00:00+00:00"; to = "${Last}T23:59:59+00:00" }
    }
    return $payload
}

function Invoke-Arm([string]$Method, [string]$Url, $Payload = $null) {
    $uri = [uri]$Url
    # Validate continuation URLs before obtaining or sending an access token.
    if ($uri.Scheme -cne 'https' -or $uri.Authority -cne 'management.azure.com') { throw 'Refusing to send credentials outside Azure Resource Manager.' }
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        if (-not $script:Token -or [datetime]::UtcNow - $script:TokenTime -gt [timespan]::FromMinutes(30)) {
            $script:Token = (& az account get-access-token --resource 'https://management.azure.com/' --query accessToken -o tsv | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $script:Token) { throw 'Azure CLI authentication failed. Run az login.' }
            $script:TokenTime = [datetime]::UtcNow
        }
        $parameters = @{ Method = $Method; Uri = $Url; Headers = @{ Authorization = "Bearer $script:Token" }; ContentType = 'application/json'; TimeoutSec = 90; SkipHttpErrorCheck = $true }
        if ($null -ne $Payload) { $parameters.Body = ConvertTo-Json -InputObject $Payload -Depth 30 -Compress }
        $response = Invoke-WebRequest @parameters
        if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300) {
            if ($response.Content) { return Read-Json $response.Content }
            return @{}
        }
        # Honor Azure's retry delay when provided; stop rather than waiting over two minutes.
        if ([int]$response.StatusCode -in @(429, 500, 502, 503, 504) -and $attempt -lt 4) {
            $retry = [string]($response.Headers['x-ms-ratelimit-microsoft.consumption-retry-after'] | Select-Object -First 1)
            if (-not $retry) { $retry = [string]($response.Headers['Retry-After'] | Select-Object -First 1) }
            $seconds = 0
            if (-not [int]::TryParse($retry, [ref]$seconds)) { $seconds = [math]::Pow(2, $attempt) }
            if ($seconds -gt 120) { throw "Azure throttled the query; retry after $retry seconds." }
            [System.Threading.Thread]::Sleep([timespan]::FromSeconds([math]::Max(0, $seconds)))
            continue
        }
        throw "ARM HTTP $($response.StatusCode): $($response.Content)"
    }
    throw 'ARM retry limit exceeded.'
}

function Get-Resources([string]$Url) {
    # Resource-list pages use GET, unlike the billing query's POST continuation.
    $resources = [System.Collections.Generic.List[object]]::new()
    while ($Url) {
        $page = Invoke-Arm 'GET' $Url
        foreach ($resource in $page.value) { $resources.Add($resource) }
        $Url = $page.nextLink
    }
    return ,$resources.ToArray()
}

function Get-Costs([string]$Subscription, $Payload) {
    $url = "$script:Arm/subscriptions/$Subscription/providers/Microsoft.CostManagement/query?api-version=2025-03-01"
    $result = [System.Collections.Generic.List[object]]::new()
    while ($url) {
        # Cost Management continuation pages use POST and the original query body.
        $page = Invoke-Arm 'POST' $url $Payload
        $properties = $page.properties
        # Billing rows are positional, so resolve values using the returned column names.
        $columns = @($properties.columns | ForEach-Object { $_.name })
        foreach ($values in $properties.rows) {
            if (@('ResourceId', 'Meter', 'Currency').Where({ $_ -cnotin $columns }).Count) { throw 'Unexpected billing columns.' }
            if ($values.Count -ne $columns.Count) { throw 'Billing row length does not match columns.' }
            $row = @{}
            for ($index = 0; $index -lt $columns.Count; $index++) { $row[$columns[$index]] = $values[$index] }
            $cost = if ($null -ne $row.PreTaxCost) { $row.PreTaxCost } elseif ($null -ne $row.Cost) { $row.Cost } else { $row.totalCost }
            if ($null -eq $cost -or -not $row.Currency) { throw 'Billing row is missing its cost or currency.' }
            $row.cost = [decimal]$cost
            $result.Add($row)
        }
        $url = $properties.nextLink
    }
    return ,$result.ToArray()
}

function Get-TokenUsage([string]$Meter, $Quantity) {
    # Only convert explicitly labeled token units; unknown units are not zero.
    $match = [regex]::Match($Meter, '(?<![\w.,])(\d+(?:,\d{3})*(?:\.\d+)?)\s*([KMB]?)\s+tokens?\s*$', 'IgnoreCase')
    if (-not $match.Success -or $null -eq $Quantity) { return $null }
    try {
        $unit = [decimal]::Parse($match.Groups[1].Value.Replace(',', ''), $script:Culture)
        $multiplier = switch ($match.Groups[2].Value.ToUpperInvariant()) { 'K' { 1000 } 'M' { 1000000 } 'B' { 1000000000 } default { 1 } }
        # Parse directly as decimal to avoid floating-point rounding in token counts.
        $amount = [decimal]::Parse([string]$Quantity, [System.Globalization.NumberStyles]::Float, $script:Culture)
        $count = $amount * $unit * $multiplier
        if ([decimal]::Truncate($count) -ne $count) { return $null }
        return [decimal]::Truncate($count)
    } catch { return $null }
}

function Get-Model([string]$Meter, $Deployments) {
    $label = ' ' + ([regex]::Replace($Meter.ToLowerInvariant(), '[^a-z0-9]+', ' ').Trim()) + ' '
    $candidates = @($Deployments | ForEach-Object { $_.properties.model.name } | Where-Object { $_ } | Select-Object -Unique)
    $matches = @($candidates | Where-Object { $normalized = [regex]::Replace($_.ToLowerInvariant(), '[^a-z0-9]+', ' ').Trim(); $label.Contains(" $normalized ") })
    # Prefer a more specific nested model name, but leave ambiguous matches unassigned.
    $longest = @($matches | Where-Object {
        $current = [regex]::Replace($_.ToLowerInvariant(), '[^a-z0-9]+', ' ').Trim()
        $nested = @($matches | Where-Object { $other = [regex]::Replace($_.ToLowerInvariant(), '[^a-z0-9]+', ' ').Trim(); $current -cne $other -and " $other ".Contains(" $current ") })
        $nested.Count -eq 0
    })
    if ($longest.Count -eq 1) { return $longest[0] }
    return $null
}

function Get-Summary($Rows, [string[]]$Dimensions) {
    $groups = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($row in $Rows) {
        # Always group by currency so unlike currencies are never added together.
        $fields = @($Dimensions) + @('currency')
        $values = @($fields | ForEach-Object { $row[$_] })
        $key = ConvertTo-Json -InputObject $values -Compress
        if (-not $groups.ContainsKey($key)) {
            $total = [ordered]@{}
            foreach ($field in $fields) { $total[$field] = $row[$field] }
            $total.cost = [decimal]0
            $total.tokens_consumed = $null
            $groups[$key] = $total
        }
        $groups[$key].cost += $row.cost
        # Null means no convertible token rows; zero is a valid billed count.
        if ($null -ne $row.tokens_consumed) {
            if ($null -eq $groups[$key].tokens_consumed) { $groups[$key].tokens_consumed = [decimal]0 }
            $groups[$key].tokens_consumed += $row.tokens_consumed
        }
    }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($key in @($groups.Keys | Sort-Object)) {
        $total = $groups[$key]
        $total.cost = $total.cost.ToString($script:Culture)
        $result.Add($total)
    }
    return ,$result.ToArray()
}

function New-Report([string]$Subscription, $Payload, $Costs, $Accounts, $MappingData) {
    $inventory = @{}
    foreach ($account in $Accounts) { $inventory[$account.id.TrimEnd('/').ToLowerInvariant()] = $account }
    $details = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $Costs) {
        $resourceId = [string]$row.ResourceId
        $key = $resourceId.TrimEnd('/').ToLowerInvariant()
        # A deployment or project billing ID belongs to its parent account.
        $accountKey = ($key -split '/deployments/')[0] -split '/projects/' | Select-Object -First 1
        $entry = $MappingData[$key]
        $foundryId = if ($entry) { [string]$entry.foundry_id } elseif ($inventory[$accountKey]) { [string]$inventory[$accountKey].id } else { '' }
        if (-not $foundryId -and $key.Contains('/providers/microsoft.cognitiveservices/accounts/')) { $foundryId = $resourceId.Substring(0, $accountKey.Length) }
        $account = $inventory[$foundryId.TrimEnd('/').ToLowerInvariant()]
        $meter = [string]$row.Meter
        # Exact mappings take precedence over inference from current deployments.
        $model = if ($entry -and $entry.meters.ContainsKey($meter)) { [string]$entry.meters[$meter] } else { '' }
        $attribution = if ($model) { 'explicit_mapping' } else { 'unassigned' }
        if (-not $model -and $account) {
            $model = Get-Model $meter $account.deployments
            if ($model) { $attribution = 'inferred_from_meter' }
        }
        $quantity = if ($null -ne $row.UsageQuantity) { $row.UsageQuantity } else { $row.totalUsage }
        # Keep unmatched charges as unassigned so report totals remain complete.
        $details.Add([ordered]@{
            foundry_id = $foundryId; foundry = $(if ($foundryId) { ($foundryId -split '/')[-1] } else { 'Unassigned subscription charges' })
            resource_id = $resourceId; model = $(if ($model) { $model } else { 'Unassigned model' }); meter = $meter
            usage_date = [string]$row.UsageDate; tokens_consumed = Get-TokenUsage $meter $quantity
            attribution = $attribution; currency = [string]$row.Currency; cost = [decimal]$row.cost
        })
    }
    $warnings = @(
        'Model matches inferred from meter names are not authoritative billing attribution.'
        'Current deployments do not describe deleted or historical models; use exact meter mappings.'
        'Foundry means the billing AI Services/OpenAI account, not an individual project or classic hub.'
        'Totals cover only queried resource types. The default filter excludes Marketplace and shared infrastructure, and can include non-Foundry Cognitive Services accounts.'
        'Billing data can be delayed. No billing row does not establish zero usage or zero cost.'
        'Tokens are net billed usage calculated from meter labels, not Azure Monitor measurements. Totals may be partial when token units or quantities are unavailable.'
    )
    $deploymentInventory = @($Accounts | ForEach-Object {
        @{ foundry_id = $_.id; foundry = $_.name; deployments = @($_.deployments | ForEach-Object { @{ name = $_.name; model = $(if ($_.properties.model) { $_.properties.model } else { @{} }) } }) }
    })
    $subscriptionTotals = Get-Summary $details @()
    $foundryTotals = Get-Summary $details @('foundry_id', 'foundry')
    $modelTotals = Get-Summary $details @('foundry_id', 'foundry', 'model', 'attribution')
    # Sum decimal costs first, then serialize them as invariant strings.
    foreach ($detail in $details) { $detail.cost = $detail.cost.ToString($script:Culture) }
    return [ordered]@{
        subscription_id = $Subscription; query = $Payload
        totals_scope = $(if ($Payload.dataset.Contains('filter')) { 'Filtered Cognitive Services accounts' } else { 'All subscription resources' })
        warnings = $warnings; subscription_totals = $subscriptionTotals; foundry_totals = $foundryTotals
        model_totals = $modelTotals; details = $details.ToArray(); inventory = $deploymentInventory
    }
}

<#
.SYNOPSIS
Returns billing and token consumption for Foundry accounts in a subscription.
.DESCRIPTION
Queries Azure Cost Management and the current account and deployment inventory.
Returns a report object without printing or writing files. Token totals can be
partial, and inferred model attribution is not authoritative. Requires Azure CLI
login, Cost Management Reader, and Reader access to account deployments.
.PARAMETER SubscriptionId
Azure subscription ID. Defaults to AZURE_SUBSCRIPTION_ID.
.PARAMETER Start
First UTC date in yyyy-MM-dd format. Supply both Start and End, or neither.
.PARAMETER End
Inclusive last UTC date in yyyy-MM-dd format.
.PARAMETER Mapping
Path to a JSON file mapping billing resource IDs and exact meters to models.
.PARAMETER AllResources
Include all resource types instead of filtering to Cognitive Services accounts.
.EXAMPLE
$report = Get-FoundryCostReport -SubscriptionId '<subscription-guid>'
$report.model_totals
#>
function Get-FoundryCostReport {
    param(
        [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
        [string]$Start,
        [string]$End,
        [string]$Mapping,
        [switch]$AllResources
    )

    $ErrorActionPreference = 'Stop'
    $payload = Get-Payload $Start $End $AllResources.IsPresent
    if (-not $SubscriptionId) { throw '-SubscriptionId or AZURE_SUBSCRIPTION_ID is required.' }
    $subscription = ([guid]::Parse($SubscriptionId)).ToString()
    $mappingData = @{}
    # Resource IDs are normalized for lookup; exact meter names retain their case.
    if ($Mapping) {
        $parsed = Read-Json ([System.IO.File]::ReadAllText((Resolve-Path $Mapping)))
        if ($parsed -isnot [System.Collections.IDictionary]) { throw 'Mapping must be an object keyed by billing resource ID.' }
        foreach ($resourceId in $parsed.Keys) {
            $entry = $parsed[$resourceId]
            if ($entry -isnot [System.Collections.IDictionary] -or $entry.foundry_id -isnot [string] -or $entry.meters -isnot [System.Collections.IDictionary]) { throw 'Each mapping needs a foundry_id and a meters object.' }
            foreach ($model in $entry.meters.Values) { if ($model -isnot [string] -or [string]::IsNullOrWhiteSpace($model)) { throw 'Mapping meters must map exact meter names to nonempty model names.' } }
            $mappingData[$resourceId.TrimEnd('/').ToLowerInvariant()] = $entry
        }
    }
    $costs = Get-Costs $subscription $payload
    $accounts = [System.Collections.Generic.List[object]]::new()
    # Inventory is current, so it cannot identify deleted or historical deployments.
    $resources = Get-Resources "$script:Arm/subscriptions/$subscription/providers/Microsoft.CognitiveServices/accounts?api-version=2024-10-01"
    foreach ($account in $resources) {
        if ($account.kind -notin @('AIServices', 'OpenAI')) { continue }
        $account['deployments'] = Get-Resources "$script:Arm$($account.id)/deployments?api-version=2024-10-01"
        $accounts.Add($account)
    }
    return New-Report $subscription $payload $costs $accounts $mappingData
}

function Main {
    # Inspect the query without authenticating or querying Azure.
    if ($PrintPayload) {
        $payload = Get-Payload $Start $End $AllResources.IsPresent
        ConvertTo-Json -InputObject $payload -Depth 30
        return
    }
    $report = Get-FoundryCostReport -SubscriptionId $SubscriptionId -Start $Start -End $End -Mapping $Mapping -AllResources:$AllResources
    $subscription = $report.subscription_id
    Write-Output "Subscription: $subscription"
    Write-Output "Cost scope: $($report.totals_scope)"
    foreach ($total in $report.subscription_totals) { Write-Output "Queried resource total: $($total.cost) $($total.currency)" }
    foreach ($total in $report.foundry_totals) { Write-Output "Foundry total: $($total.foundry) | $($total.cost) $($total.currency) | $($total.foundry_id)" }
    Write-Output "`nFoundry | Model | Attribution | Cost | Currency | Tokens Consumed | Foundry ID"
    foreach ($total in $report.model_totals) {
        $tokenValue = if ($null -eq $total.tokens_consumed) { 'N/A' } else { $total.tokens_consumed }
        Write-Output "$($total.foundry) | $($total.model) | $($total.attribution) | $($total.cost) | $($total.currency) | $tokenValue | $($total.foundry_id)"
    }
    if (-not $report.details.Count) { Write-Output 'No billing rows returned for this period.' }
    foreach ($account in $report.inventory) {
        $models = @($account.deployments | ForEach-Object { if ($_.model.name) { $_.model.name } else { 'Unknown' } } | Sort-Object -Unique)
        $modelText = if ($models.Count) { $models -join ', ' } else { 'No deployments' }
        Write-Output "Inventory: $($account.foundry) | $modelText"
    }
    foreach ($warning in $report.warnings) { [Console]::Error.WriteLine("Warning: $warning") }
    if ($Json) { [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($Json), (ConvertTo-Json -InputObject $report -Depth 100), [System.Text.UTF8Encoding]::new($false)) }
    if ($Csv) {
        $fields = @('foundry_id', 'foundry', 'resource_id', 'model', 'meter', 'usage_date', 'attribution', 'currency', 'cost', 'tokens_consumed')
        if ($report.details.Count) { $report.details | ForEach-Object { [pscustomobject]$_ } | Select-Object $fields | Export-Csv -Path $Csv -Encoding utf8 }
        else { [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($Csv), ($fields -join ',') + "`n", [System.Text.UTF8Encoding]::new($false)) }
    }
}

# Dot-sourcing defines the functions without launching the command-line workflow.
if ($MyInvocation.InvocationName -ne '.') {
    try { Main }
    catch { [Console]::Error.WriteLine("Error: $($_.Exception.Message)"); exit 1 }
}