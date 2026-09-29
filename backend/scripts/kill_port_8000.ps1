$owners = Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique
foreach ($procId in $owners) {
    try {
        Get-Process -Id $procId -ErrorAction Stop | Select-Object Id, ProcessName | Format-Table -HideTableHeaders
        Stop-Process -Id $procId -Force
        Write-Host "Killed PID $procId"
    } catch {
        Write-Host "Process $procId already gone"
    }
}
Start-Sleep -Milliseconds 800
$still = Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue
if ($still) { Write-Host "still-listening" } else { Write-Host "free" }
