# ==========================================================
# RustDesk installer + config (Windows)
# ==========================================================
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$IDServer    = "115.240.201.195"
$RelayServer = "115.240.201.195"
$Key         = "NymCTxtQz1kmrYxLH7IYe1uaheTPwsAwyvHU1VPOfx0="
$PwPrefix    = "welcome@"

function Write-Step($m) { Write-Host "`n>>> $m" -ForegroundColor Cyan }

try {
    # --- Admin check ---
    Write-Step "Checking administrator privileges"
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (!$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run PowerShell as Administrator."
    }

    # --- Ask for the number first, so we fail early ---
    Write-Step "Password setup"
    do {
        $Num = (Read-Host "Enter the number for the password (welcome@<number>)").Trim()
        if ($Num -notmatch '^\d+$') { Write-Host "Numbers only, please." -ForegroundColor Red }
    } while ($Num -notmatch '^\d+$')
    $Password = "$PwPrefix$Num"

    # --- Find / install RustDesk ---
    Write-Step "Checking RustDesk installation"
    $Paths = @("$env:ProgramFiles\RustDesk\rustdesk.exe", "${env:ProgramFiles(x86)}\RustDesk\rustdesk.exe")
    $RustDesk = $Paths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $RustDesk) {
        Write-Step "Finding latest RustDesk release"
        $rel   = Invoke-RestMethod "https://api.github.com/repos/rustdesk/rustdesk/releases/latest" -Headers @{ "User-Agent" = "ps" }
        $asset = $rel.assets | Where-Object { $_.name -match '^rustdesk-[\d\.]+-x86_64\.exe$' } | Select-Object -First 1
        if (-not $asset) { throw "Could not find Windows installer in latest release." }

        $Installer = Join-Path $env:TEMP $asset.name
        Write-Step "Downloading $($asset.name)"
        Invoke-WebRequest $asset.browser_download_url -OutFile $Installer -UseBasicParsing
        if ((Get-Item $Installer).Length -lt 1MB) { throw "Downloaded installer looks invalid." }

        $sig = Get-AuthenticodeSignature $Installer
        if ($sig.Status -ne "Valid") { throw "Installer signature is not valid ($($sig.Status))." }

        Write-Step "Installing RustDesk (silent)"
        Start-Process -FilePath $Installer -ArgumentList "--silent-install" -Wait
        Start-Sleep -Seconds 8
        Remove-Item $Installer -Force -ErrorAction SilentlyContinue

        $RustDesk = $Paths | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $RustDesk) { throw "RustDesk executable not found after install." }
    } else {
        Write-Host "RustDesk already installed." -ForegroundColor Green
    }

    # --- Service ---
    Write-Step "Ensuring RustDesk service exists and is running"
    $svc = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    if (-not $svc) {
        Start-Process -FilePath $RustDesk -ArgumentList "--install-service" -Wait -WindowStyle Hidden
        Start-Sleep -Seconds 5
    }
    Stop-Service -Name "RustDesk" -Force -ErrorAction SilentlyContinue
    Get-Process -Name "rustdesk" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

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

    Start-Service -Name "RustDesk"
    Start-Sleep -Seconds 5

    # --- Permanent password ---
    Write-Step "Setting permanent password"
    & $RustDesk --password $Password | Out-Null
    Start-Sleep -Seconds 2

    # --- Get ID ---
    Write-Step "Retrieving RustDesk ID"
    $out = & $RustDesk --get-id | Out-String
    $RustDeskID = ($out -split '\r?\n' | Where-Object { $_.Trim() -match '^\d{6,}$' } | Select-Object -First 1)
    if (-not $RustDeskID) { throw "Could not read RustDesk ID. Output: $out" }

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
