# Stop (deallocate) all lab VMs to save money.
# Deallocated VMs only cost their disks (~a few $/month).
param(
    [string] $ResourceGroup = "rg-monlab-monitoring"
)

$vms = @("win-web-1", "win-web-2", "mon-linux-1")
foreach ($vm in $vms) {
    Write-Host "Deallocating $vm ..."
    az vm deallocate --resource-group $ResourceGroup --name $vm --no-wait
}
Write-Host "Deallocation started for: $($vms -join ', ')"
Write-Host "Note: public IPs are Static SKU, so they stay reserved while stopped."
