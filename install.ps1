# ==========================================================
# RustDesk installer + config (Windows)  -  v2 (no-hang fix)
# ==========================================================
$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"   # progress bar makes Invoke-WebRequest very slow in PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$IDServer    = "115.240.201.195"
$RelayServer = "115.240.201.195"
$Key         = "NymCTxtQz1kmrYxLH7IYe1uaheTPwsAwyvHU1VPOfx0="
$PwPrefix    = "welcome@"

function Write-Step($m) { Write-Host "`n>>> $m" -ForegroundColor Cyan }

# Find the installed RustDesk executable
function Get-RustDeskPath {
    @("$env:ProgramFiles\RustDesk\rustdesk.exe", "${env:ProgramFiles(x86)}\RustDesk\rustdesk.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}

# Run a RustDesk command with a hard timeout (never hangs)
function Invoke-RD {
    param([string]$Exe, [string]$CmdArgs, [int]$Timeout = 30)
    $o = Join-Path $env:TEMP "rd-out.txt"
    $e = Join-Path $env:TEMP "rd-err.txt"
    Remove-Item $o, $e -Force -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $Exe -ArgumentList $CmdArgs -PassThru -WindowStyle Hidden `
         -RedirectStandardOutput $o -RedirectStandardError $e
    if (-not $p.WaitForExit($Timeout * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    if (Test-Path $o) { return (Get-Content $o -Raw) }
    return ""
}

# Kill every RustDesk process (app, tray, leftover installer)
function Stop-AllRustDesk {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "rustdesk*" } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

try {
    # --- Admin check ---
    Write-Step "Checking administrator privileges"
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (!$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run PowerShell as Administrator."
    }

    # --- Ask for the number first ---
    Write-Step "Password setup"
    do {
        $Num = (Read-Host "Enter the number for the password (${PwPrefix}<number>)").Trim()
        if ($Num -notmatch '^\d+$') { Write-Host "Numbers only, please." -ForegroundColor Red }
    } while ($Num -notmatch '^\d+$')
    $Password = "$PwPrefix$Num"

    # --- Clean up anything left from a cancelled run ---
    Write-Step "Cleaning leftovers from earlier runs"
    Stop-AllRustDesk
    Get-ChildItem $env:TEMP -Filter "rustdesk-*.exe" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # --- Install if missing ---
    Write-Step "Checking RustDesk installation"
    $RustDesk = Get-RustDeskPath

    if (-not $RustDesk) {
        Write-Step "Finding latest RustDesk release"
        $rel   = Invoke-RestMethod "https://api.github.com/repos/rustdesk/rustdesk/releases/latest" -Headers @{ "User-Agent" = "ps" } -TimeoutSec 60
        $asset = $rel.assets | Where-Object { $_.name -match '^rustdesk-[\d\.]+-x86_64\.exe$' } | Select-Object -First 1
        if (-not $asset) { throw "Could not find Windows installer in latest release." }

        $Installer = Join-Path $env:TEMP $asset.name
        Write-Step "Downloading $($asset.name)"
        Invoke-WebRequest $asset.browser_download_url -OutFile $Installer -UseBasicParsing -TimeoutSec 600
        if ((Get-Item $Installer).Length -lt 1MB) { throw "Downloaded installer looks invalid." }

        $sig = Get-AuthenticodeSignature $Installer
        if ($sig.Status -ne "Valid") { throw "Installer signature is not valid ($($sig.Status))." }

        Write-Step "Installing RustDesk (silent, max 3 minutes)"
        # NOTE: no -Wait. The installer launches RustDesk and Start-Process -Wait
        # would wait for that child forever. We poll for the result instead.
        $inst = Start-Process -FilePath $Installer -ArgumentList "--silent-install" -PassThru
        $deadline = (Get-Date).AddSeconds(180)
        $done = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            $RustDesk = Get-RustDeskPath
            $svcNow   = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
            if ($RustDesk -and $svcNow)                { $done = $true; break }
            if ($RustDesk -and $inst.HasExited)        { $done = $true; break }
            Write-Host "  ...installing" -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 5
        Stop-AllRustDesk
        Remove-Item $Installer -Force -ErrorAction SilentlyContinue

        $RustDesk = Get-RustDeskPath
        if (-not $RustDesk) { throw "RustDesk executable not found after install (timed out)." }
        Write-Host "RustDesk installed: $RustDesk" -ForegroundColor Green
    } else {
        Write-Host "RustDesk already installed: $RustDesk" -ForegroundColor Green
    }

    # --- Service ---
    Write-Step "Ensuring RustDesk service exists"
    $svc = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Host "Installing service..."
        Invoke-RD -Exe $RustDesk -CmdArgs "--install-service" -Timeout 40 | Out-Null
        for ($i = 0; $i -lt 10 -and -not $svc; $i++) {
            Start-Sleep -Seconds 3
            $svc = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
        }
    }
    if (-not $svc) {
        Write-Host "Falling back to manual service creation..." -ForegroundColor Yellow
        & sc.exe create RustDesk binPath= "`"$RustDesk`" --service" start= auto DisplayName= "RustDesk Service" | Out-Null
        Start-Sleep -Seconds 3
        $svc = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    }
    if (-not $svc) { throw "RustDesk service could not be created." }

    Stop-Service -Name "RustDesk" -Force -ErrorAction SilentlyContinue
    Stop-AllRustDesk

    # --- Write server config (service profile + current user profile) ---
    Write-Step "Writing server configuration"
    $Toml = @"
rendezvous_server = '${IDServer}:21116'
nat_type = 1
serial = 0

[options]
custom-rendezvous-server = '$IDServer'
relay-server = '$RelayServer'
key = '$Key'
"@
    $ConfigDirs = @(
        "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config",
        "$env:APPDATA\RustDesk\config"
    )
    foreach ($d in $ConfigDirs) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        [IO.File]::WriteAllText((Join-Path $d "RustDesk2.toml"), $Toml, (New-Object Text.UTF8Encoding($false)))
        Write-Host "Config written: $d"
    }

    # --- Start service ---
    Write-Step "Starting service"
    Start-Service -Name "RustDesk"
    for ($i = 0; $i -lt 10; $i++) {
        if ((Get-Service -Name "RustDesk").Status -eq "Running") { break }
        Start-Sleep -Seconds 2
    }
    if ((Get-Service -Name "RustDesk").Status -ne "Running") { throw "RustDesk service did not start." }
    Start-Sleep -Seconds 5

    # --- Permanent password ---
    Write-Step "Setting permanent password"
    $r = Invoke-RD -Exe $RustDesk -CmdArgs "--password $Password" -Timeout 30
    if ($null -eq $r) { throw "Setting the password timed out." }
    Start-Sleep -Seconds 2

    # --- Get ID (retry a few times, service may still be starting) ---
    Write-Step "Retrieving RustDesk ID"
    $RustDeskID = $null
    for ($i = 1; $i -le 6 -and -not $RustDeskID; $i++) {
        $out = Invoke-RD -Exe $RustDesk -CmdArgs "--get-id" -Timeout 20
        if ($out) {
            $RustDeskID = ($out -split '\r?\n' | Where-Object { $_.Trim() -match '^\d{6,}$' } | Select-Object -First 1)
        }
        if (-not $RustDeskID) { Write-Host "  retry $i/6..." -ForegroundColor DarkGray; Start-Sleep -Seconds 4 }
    }
    if (-not $RustDeskID) { throw "Could not read RustDesk ID." }

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host " RUSTDESK SETUP COMPLETE" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "ID          : $RustDeskID"
    Write-Host "Password    : $Password"
    Write-Host "ID Server   : $IDServer"
    Write-Host "Relay Server: $RelayServer"
    Write-Host "Key         : $Key"
}
catch {
    Write-Host "`nSETUP FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
