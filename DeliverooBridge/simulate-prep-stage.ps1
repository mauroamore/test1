param(
    [Parameter(Mandatory = $true)]
    [string]$OrderId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('in_kitchen', 'ready_for_collection_soon', 'ready_for_collection', 'collected')]
    [string]$Stage,

    [Parameter(Mandatory = $true)]
    [securestring]$PrepStageKey
)

$credential = New-Object System.Management.Automation.PSCredential('prep-stage', $PrepStageKey)
$key = $credential.GetNetworkCredential().Password
$headers = @{
    'X-Prep-Stage-Key' = $key
    'Content-Type' = 'application/json'
}
$body = @{
    order_id = $OrderId
    stage = $Stage
} | ConvertTo-Json -Compress

Invoke-RestMethod `
    -Uri 'https://thaiprincess.it/DeliverooPrepStage.ashx' `
    -Method Post `
    -Headers $headers `
    -Body $body
