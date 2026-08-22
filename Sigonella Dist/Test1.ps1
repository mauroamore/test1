$body = @{
  form = @{
    orderId = "ef420295-9a50-11f1-a08e-b02628212d8e"
    terminalId = "POS-001"
  }
} | ConvertTo-Json

try {
    $response = Invoke-WebRequest `
        -Uri "https://servizi.thaiprincess.it/StandardOrderService.asmx/ReservePosOrder" `
        -Method POST `
        -Headers @{ "X-Api-Key" = "SA3VkVgxOtYfv/s5dU+vG4pb+f8qGb6b7J9lXAXZjAY=" } `
        -ContentType "application/json; charset=utf-8" `
        -Body $body `
        -TimeoutSec 30

    Write-Host "HTTP:" $response.StatusCode
    Write-Host "RISPOSTA:"
    Write-Host $response.Content
}
catch {
    Write-Host "ERRORE:"
    Write-Host $_.Exception.Message
    if ($_.Exception.Response) {
        $reader = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
        Write-Host $reader.ReadToEnd()
    }
}


pause