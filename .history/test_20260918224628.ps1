$body = Get-Content "C:\Users\AS RUMON\Desktop\buphack\buphackathon\test.json" -Raw
$response = Invoke-RestMethod -Uri "https://smart-campus-energy-optimizer.asrumon.workers.dev/optimize-energy" -Method Post -ContentType "application/json" -Body $body
$response | ConvertTo-Json -Depth 10