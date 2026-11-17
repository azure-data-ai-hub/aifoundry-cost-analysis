# Build and test C# helpers and query construction without making Azure requests.
$ErrorActionPreference = 'Stop'
dotnet build "$PSScriptRoot/FoundryCosts.csproj" --nologo
if ($LASTEXITCODE -ne 0) { throw 'C# build failed.' }
# Load bytes rather than the file itself so repeated builds do not lock the DLL.
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes((Resolve-Path "$PSScriptRoot/bin/Debug/net9.0/FoundryCosts.dll")))
$methods = $assembly.GetType('FoundryCosts').GetMethods([System.Reflection.BindingFlags]'Static,NonPublic')
function Get-Helper([string]$Name) {
    $method = @($methods | Where-Object Name -EQ $Name)
    if ($method.Count -ne 1) { throw "Could not locate C# helper $Name." }
    return $method[0]
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message. Expected '$Expected', got '$Actual'." }
}
$tokens = Get-Helper 'Tokens'
$quantity = [System.Text.Json.Nodes.JsonNode]::Parse('0.256217')
Assert-Equal ($tokens.Invoke($null, @('Input 1M Tokens', $quantity))) 256217 'Million-token conversion'
Assert-Equal ($tokens.Invoke($null, @('Input 1M Tokens', [System.Text.Json.Nodes.JsonNode]::Parse('-0.01')))) -10000 'Negative tokens'
if ($null -ne $tokens.Invoke($null, @('Input Tokens', $quantity))) { throw 'Unknown token units must be unavailable.' }
if ($null -ne $tokens.Invoke($null, @('Input 1 Tokens', [System.Text.Json.Nodes.JsonNode]::Parse('0.5')))) { throw 'Fractional tokens must be unavailable.' }
$infer = Get-Helper 'InferModel'
$deployments = [System.Text.Json.Nodes.JsonNode]::Parse('[{"properties":{"model":{"name":"gpt-4o"}}},{"properties":{"model":{"name":"gpt-4o-mini"}}}]')
Assert-Equal ($infer.Invoke($null, @('GPT-4o-mini Input Tokens', $deployments))) 'gpt-4o-mini' 'Model prefix matching'
Assert-Equal ($infer.Invoke($null, @('shared capacity', $deployments))) '' 'Unknown model'
$amount = Get-Helper 'Amount'
Assert-Equal ($amount.Invoke($null, @([System.Text.Json.Nodes.JsonNode]::Parse('0.19216275')))) ([decimal]::Parse('0.19216275', [cultureinfo]::InvariantCulture)) 'Billing decimal precision'
if (-not $assembly.GetType('FoundryCosts').GetMethod('GetReportAsync')) { throw 'Public report API is missing.' }
$publicPayload = $assembly.GetType('FoundryCosts').GetMethod('BuildPayload').Invoke($null, @('2026-10-01', '2026-10-31', $true))
Assert-Equal $publicPayload['timePeriod']['to'].ToString() '2026-10-31T23:59:59+00:00' 'Public payload API'
if ($null -ne $publicPayload['dataset']['filter']) { throw 'Public all-resources payload should not have a filter.' }
# Payload-only mode validates the CLI without authentication or network access.
$payload = (& dotnet run --no-build --project "$PSScriptRoot/FoundryCosts.csproj" -- --start 2026-10-01 --end 2026-10-31 --all-resources --print-payload | Out-String) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'C# payload command failed.' }
Assert-Equal $payload.timePeriod.to '2026-10-31T23:59:59+00:00' 'Inclusive end'
if ($payload.dataset.PSObject.Properties.Name -contains 'filter') { throw 'All-resources payload should not have a filter.' }
Write-Output 'C# tests passed.'