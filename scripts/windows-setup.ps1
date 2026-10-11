<#
.SYNOPSIS
  Provisions the monitored application stack on a Windows Server VM:
    * Node.js 24 LTS + demo app (custom /metrics instrumentation)
    * Nginx for Windows (reverse proxy + stub_status)
    * windows_exporter (system metrics on :9182)
    * nginx-prometheus-exporter (:9113)
    * Grafana Alloy (ships Windows Event Logs + Nginx/app logs to Loki)

  Designed to run unattended from the Azure Custom Script Extension.
  Re-running is safe-ish: services are reconfigured and restarted.
#>

param(
    [Parameter(Mandatory = $true)] [string] $RepoRawBase,
    [Parameter(Mandatory = $true)] [string] $LokiUrl,
    [Parameter(Mandatory = $true)] [string] $ServerName,
    [string] $AppDir   = "C:\app",
    [string] $NginxDir = "C:\nginx",
    [string] $ToolsDir = "C:\tools",
    [string] $LogDir   = "C:\setup\logs"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SetupDir = "C:\setup"
New-Item -ItemType Directory -Force -Path $SetupDir, $LogDir, $ToolsDir, $AppDir | Out-Null
Start-Transcript -Path (Join-Path $SetupDir "setup.log") -Append | Out-Null

function Write-Step([string] $Message) {
    Write-Host ("`n==== {0} : {1} ====" -f (Get-Date -Format "HH:mm:ss"), $Message)
}

function Get-FileWithRetry {
    param([string] $Url, [string] $OutFile, [int] $Retries = 3)
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
            return
        }
        catch {
            Write-Warning "Download attempt $i failed for $Url : $_"
            if ($i -eq $Retries) { throw }
            Start-Sleep -Seconds (10 * $i)
        }
    }
}

function Get-GitHubAssetUrl {
    param([string] $Repo, [string] $Tag, [string] $Pattern)
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$Tag" -Headers @{ "User-Agent" = "monlab-setup" }
    $asset = $release.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
    if (-not $asset) { throw "No asset matching '$Pattern' in $Repo@$Tag" }
    return $asset.browser_download_url
}

function Expand-Download {
    param([string] $Url, [string] $DownloadPath, [string] $Destination)
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    if ($Url -match "\.zip$") {
        Get-FileWithRetry -Url $Url -OutFile $DownloadPath
        Expand-Archive -Path $DownloadPath -DestinationPath $Destination -Force
    }
    elseif ($Url -match "\.tar\.gz$") {
        Get-FileWithRetry -Url $Url -OutFile $DownloadPath
        tar.exe -xzf $DownloadPath -C $Destination
    }
    else { throw "Unsupported archive type: $Url" }
}

function Set-NssmService {
    param([string] $Name, [string] $Exe, [string] $Arguments = "", [string] $WorkDir = "")
    $nssm = Join-Path $ToolsDir "nssm.exe"
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        & $nssm install $Name $Exe | Out-Null
    }
    & $nssm set $Name Application $Exe | Out-Null
    if ($Arguments) { & $nssm set $Name AppParameters $Arguments | Out-Null }
    if ($WorkDir)   { & $nssm set $Name AppDirectory $WorkDir | Out-Null }
    & $nssm set $Name Start SERVICE_AUTO_START | Out-Null
    & $nssm set $Name AppStdout (Join-Path $LogDir "$Name.out.log") | Out-Null
    & $nssm set $Name AppStderr (Join-Path $LogDir "$Name.err.log") | Out-Null
    & $nssm set $Name AppRotateFiles 1 | Out-Null
    & $nssm set $Name AppExit Default Restart | Out-Null
    if ($svc -and $svc.Status -ne "Stopped") {
        & $nssm restart $Name | Out-Null
    }
    else {
        & $nssm start $Name | Out-Null
    }
}

function Add-FirewallRuleIfMissing {
    param([string] $DisplayName, [int[]] $Ports, [string] $RemoteAddress = "Any")
    if (-not (Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $DisplayName -Direction Inbound -Protocol TCP `
            -LocalPort $Ports -RemoteAddress $RemoteAddress -Action Allow | Out-Null
    }
}

# -----------------------------------------------------------------------------
Write-Step "Base tooling (NSSM)"
$nssmZip = Join-Path $SetupDir "nssm.zip"
Expand-Download -Url "https://nssm.cc/release/nssm-2.24.zip" -DownloadPath $nssmZip -Destination (Join-Path $SetupDir "nssm")
Copy-Item (Join-Path $SetupDir "nssm\nssm-2.24\win64\nssm.exe") (Join-Path $ToolsDir "nssm.exe") -Force

# -----------------------------------------------------------------------------
Write-Step "Node.js 24 LTS"
$nodeIndex = Invoke-RestMethod -Uri "https://nodejs.org/dist/latest-v24.x/" -Headers @{ "User-Agent" = "monlab-setup" }
$nodeMsi = $nodeIndex | Where-Object { $_.name -match "^node-v[\d.]+-x64\.msi$" } | Select-Object -First 1
if (-not $nodeMsi) { throw "Could not find Node.js x64 MSI in latest-v24.x" }
$nodeMsiPath = Join-Path $SetupDir $nodeMsi.name
Get-FileWithRetry -Url ("https://nodejs.org/dist/latest-v24.x/" + $nodeMsi.name) -OutFile $nodeMsiPath
Start-Process msiexec.exe -ArgumentList "/i", $nodeMsiPath, "/qn", "/norestart" -Wait
$nodeExe = Join-Path $env:ProgramFiles "nodejs\node.exe"
$npmCmd  = Join-Path $env:ProgramFiles "nodejs\npm.cmd"
if (-not (Test-Path $nodeExe)) { throw "Node.js installation failed" }

# -----------------------------------------------------------------------------
Write-Step "windows_exporter"
$weMsi = Join-Path $SetupDir "windows_exporter.msi"
Get-FileWithRetry -Url "https://github.com/prometheus-community/windows_exporter/releases/download/v0.31.9/windows_exporter-0.31.9-amd64.msi" -OutFile $weMsi
Start-Process msiexec.exe -ArgumentList "/i", $weMsi, "/qn", "/norestart" -Wait

# -----------------------------------------------------------------------------
Write-Step "Nginx for Windows"
$nginxZip = Join-Path $SetupDir "nginx.zip"
Expand-Download -Url "https://nginx.org/download/nginx-1.30.5.zip" -DownloadPath $nginxZip -Destination $SetupDir
if (Test-Path $NginxDir) {
    & (Join-Path $ToolsDir "nssm.exe") stop nginx 2>$null | Out-Null
}
Remove-Item -Recurse -Force $NginxDir -ErrorAction SilentlyContinue
Move-Item (Join-Path $SetupDir "nginx-1.30.5") $NginxDir
Get-FileWithRetry -Url "$RepoRawBase/windows/nginx.conf" -OutFile (Join-Path $NginxDir "conf\nginx.conf")
New-Item -ItemType Directory -Force -Path (Join-Path $NginxDir "logs") | Out-Null
Set-NssmService -Name "nginx" -Exe (Join-Path $NginxDir "nginx.exe") -WorkDir $NginxDir

# -----------------------------------------------------------------------------
Write-Step "Node.js demo app"
Get-FileWithRetry -Url "$RepoRawBase/app/server.js"    -OutFile (Join-Path $AppDir "server.js")
Get-FileWithRetry -Url "$RepoRawBase/app/package.json" -OutFile (Join-Path $AppDir "package.json")
Push-Location $AppDir
& $npmCmd install --omit=dev --no-audit --no-fund
Pop-Location
Set-NssmService -Name "node-app" -Exe $nodeExe -Arguments "server.js" -WorkDir $AppDir
& (Join-Path $ToolsDir "nssm.exe") set node-app AppEnvironmentExtra "PORT=3000" "SERVER_NAME=$ServerName" | Out-Null

# -----------------------------------------------------------------------------
Write-Step "nginx-prometheus-exporter"
$npeUrl = Get-GitHubAssetUrl -Repo "nginx/nginx-prometheus-exporter" -Tag "v1.5.3" -Pattern "windows_amd64"
$npeDir = Join-Path $ToolsDir "nginx-exporter"
Remove-Item -Recurse -Force $npeDir -ErrorAction SilentlyContinue
Expand-Download -Url $npeUrl -DownloadPath (Join-Path $SetupDir "npe.archive") -Destination $npeDir
$npeExe = Get-ChildItem $npeDir -Recurse -Filter "nginx-prometheus-exporter.exe" | Select-Object -First 1
if (-not $npeExe) { throw "nginx-prometheus-exporter.exe not found after extraction" }
Set-NssmService -Name "nginx-exporter" -Exe $npeExe.FullName -Arguments "-nginx.scrape-uri=http://127.0.0.1:8081/stub_status -web.listen-address=:9113" -WorkDir $npeExe.DirectoryName

# -----------------------------------------------------------------------------
Write-Step "Grafana Alloy (logs -> Loki)"
$alloyUrl = Get-GitHubAssetUrl -Repo "grafana/alloy" -Tag "v1.20.1" -Pattern "windows_amd64"
$alloyDir = Join-Path $ToolsDir "alloy"
Remove-Item -Recurse -Force $alloyDir -ErrorAction SilentlyContinue
Expand-Download -Url $alloyUrl -DownloadPath (Join-Path $SetupDir "alloy.archive") -Destination $alloyDir
$alloyExe = Get-ChildItem $alloyDir -Recurse -Filter "alloy.exe" | Select-Object -First 1
if (-not $alloyExe) { throw "alloy.exe not found after extraction" }
Copy-Item $alloyExe.FullName (Join-Path $ToolsDir "alloy.exe") -Force

$AlloyData = "C:\ProgramData\alloy"
New-Item -ItemType Directory -Force -Path $AlloyData | Out-Null
$alloyConfPath = Join-Path $AlloyData "config.alloy"
Get-FileWithRetry -Url "$RepoRawBase/windows/alloy/config.windows.alloy" -OutFile $alloyConfPath
(Get-Content $alloyConfPath -Raw) `
    -replace "__LOKI_URL__", $LokiUrl `
    -replace "__SERVER_NAME__", $ServerName | Set-Content -Path $alloyConfPath -Encoding UTF8
Set-NssmService -Name "alloy" -Exe (Join-Path $ToolsDir "alloy.exe") `
    -Arguments "run --disable-reporting --storage.path=$AlloyData $alloyConfPath" -WorkDir $AlloyData

# -----------------------------------------------------------------------------
Write-Step "Firewall rules"
Add-FirewallRuleIfMissing -DisplayName "monlab-http" -Ports @(80) -RemoteAddress "Any"
Add-FirewallRuleIfMissing -DisplayName "monlab-windows-exporter" -Ports @(9182) -RemoteAddress "10.0.2.0/24"
Add-FirewallRuleIfMissing -DisplayName "monlab-nginx-exporter" -Ports @(9113) -RemoteAddress "10.0.2.0/24"
Add-FirewallRuleIfMissing -DisplayName "monlab-node-app" -Ports @(3000) -RemoteAddress "10.0.2.0/24"

# -----------------------------------------------------------------------------
Write-Step "Verification"
Start-Sleep -Seconds 10
$checks = @(
    @{ Name = "Node app /health";   Url = "http://localhost:3000/health" },
    @{ Name = "Node app /metrics";  Url = "http://localhost:3000/metrics" },
    @{ Name = "Nginx proxy";        Url = "http://localhost/" },
    @{ Name = "windows_exporter";   Url = "http://localhost:9182/metrics" },
    @{ Name = "nginx-exporter";     Url = "http://localhost:9113/metrics" }
)
$failed = @()
foreach ($check in $checks) {
    try {
        $response = Invoke-WebRequest -Uri $check.Url -UseBasicParsing -TimeoutSec 20
        Write-Host ("OK   {0} -> {1}" -f $check.Name, $response.StatusCode)
    }
    catch {
        Write-Warning ("FAIL {0} -> {1}" -f $check.Name, $_)
        $failed += $check.Name
    }
}

$marker = Join-Path $SetupDir "DONE.txt"
"Completed: $(Get-Date -Format s)`nFailed checks: $($failed -join ', ')" | Set-Content -Path $marker

Stop-Transcript | Out-Null
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
