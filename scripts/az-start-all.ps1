# Start all lab VMs again.
param(
    [string] $ResourceGroup = "rg-monlab-monitoring"
)

$vms = @("win-web-1", "win-web-2", "mon-linux-1")
foreach ($vm in $vms) {
    Write-Host "Starting $vm ..."
    az vm start --resource-group $ResourceGroup --name $vm --no-wait
}
Write-Host "Start requested for: $($vms -join ', ')"
Write-Host "Give them ~1-2 minutes, then check: http://<monitoring-ip>:3000"
