Param(
    [switch]$Pair,
    [switch]$Connect,
    [switch]$WatchPubspec,
    [switch]$Run,
    [switch]$Uninstall,
    [switch]$InstallApk,
    [string]$Ip = "",
    [int]$Port = 5555,
    [string]$PairingCode = "",
    [string]$Device = "",
    [string]$AdbPath = ""
)

$ErrorActionPreference = "Stop"

$cfgPath = Join-Path $PSScriptRoot "dev.config.json"

function Load-DevConfig {
    if (Test-Path $cfgPath) {
        try { return Get-Content -Raw -Path $cfgPath | ConvertFrom-Json } catch { return $null }
    }
    return $null
}

function Save-DevConfig($cfg) {
    try { $cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $cfgPath -Encoding UTF8 } catch {}
}

function Exec($cmd, $cwd) {
    if ($cwd -ne "") {
        Push-Location $cwd
    }
    try {
        & $env:ComSpec /c $cmd | Write-Output
    } finally {
        if ($cwd -ne "") {
            Pop-Location
        }
    }
}

function Ensure-Adb {
    if ($AdbPath -ne "") {
        if (Test-Path $AdbPath) {
            $env:Path = (Split-Path $AdbPath -Parent) + ";" + $env:Path
        }
    }
    $adb = Get-Command adb -ErrorAction SilentlyContinue
    if (-not $adb) {
        $candidates = @()
        if ($env:ANDROID_HOME) { $candidates += (Join-Path $env:ANDROID_HOME "platform-tools\adb.exe") }
        if ($env:ANDROID_SDK_ROOT) { $candidates += (Join-Path $env:ANDROID_SDK_ROOT "platform-tools\adb.exe") }
        if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe") }
        $candidates += "C:\Android\platform-tools\adb.exe"
        $candidates += "C:\Program Files (x86)\Android\android-sdk\platform-tools\adb.exe"
        foreach ($p in $candidates) {
            if ($p -and (Test-Path $p)) {
                $env:Path = (Split-Path $p -Parent) + ";" + $env:Path
                break
            }
        }
        $adb = Get-Command adb -ErrorAction SilentlyContinue
    }
    if (-not $adb) { throw "adb not found. Install Android SDK Platform-Tools and add to PATH." }
}

function Start-Pair {
    Ensure-Adb
    $cfg = Load-DevConfig
    if (-not $Ip -and $cfg -and $cfg.ip) { $Ip = $cfg.ip }
    if (-not $Ip -or -not $PairingCode) { throw "Provide -Ip and -PairingCode" }
    Exec "adb pair $Ip`:$Port $PairingCode" (Get-Location)
    $newCfg = [pscustomobject]@{
        ip          = $Ip
        pairingPort = $Port
        connectPort = if ($cfg -and $cfg.connectPort) { $cfg.connectPort } else { 5555 }
        adbPath     = if ($AdbPath -ne "") { $AdbPath } elseif ($cfg) { $cfg.adbPath } else { "" }
    }
    Save-DevConfig $newCfg
}

function Start-Connect {
    Ensure-Adb
    $cfg = Load-DevConfig
    if (-not $Ip -and $cfg -and $cfg.ip) { $Ip = $cfg.ip }
    if ($Port -eq 5555 -and $cfg -and $cfg.connectPort) { $Port = [int]$cfg.connectPort }
    if (-not $Ip) { throw "Provide -Ip" }
    Exec "adb connect $Ip`:$Port" (Get-Location)
    $newCfg = [pscustomobject]@{
        ip          = $Ip
        pairingPort = if ($cfg -and $cfg.pairingPort) { $cfg.pairingPort } else { 37099 }
        connectPort = $Port
        adbPath     = if ($AdbPath -ne "") { $AdbPath } elseif ($cfg) { $cfg.adbPath } else { "" }
    }
    Save-DevConfig $newCfg
}

function Start-WatchPubspec {
    $root = Split-Path -Parent $PSScriptRoot
    $pubspec = Join-Path $root "pubspec.yaml"
    if (-not (Test-Path $pubspec)) { throw "pubspec.yaml not found" }
    Write-Output "Watching $pubspec for changes"
    $fsw = New-Object System.IO.FileSystemWatcher
    $fsw.Path = Split-Path -Parent $pubspec
    $fsw.Filter = "pubspec.yaml"
    $fsw.IncludeSubdirectories = $false
    $fsw.EnableRaisingEvents = $true
    $action = {
        Start-Sleep -Milliseconds 250
        try {
            Exec "flutter pub get" $root | Out-Null
            Write-Output "flutter pub get completed"
        } catch {
            Write-Output "flutter pub get failed: $($_.Exception.Message)"
        }
    }
    Register-ObjectEvent $fsw Changed -Action $action | Out-Null
    Register-ObjectEvent $fsw Created -Action $action | Out-Null
    Register-ObjectEvent $fsw Renamed -Action $action | Out-Null
    while ($true) { Start-Sleep -Seconds 1 }
}

function Start-Run {
    $root = Split-Path -Parent $PSScriptRoot
    $deviceArg = ""
    if ($Device -ne "") { $deviceArg = "-d $Device" }
    Exec "flutter run $deviceArg --fast-start" $root
}

function Get-AppId {
    $root = Split-Path -Parent $PSScriptRoot
    $gradle = Join-Path $root "android\app\build.gradle.kts"
    if (-not (Test-Path $gradle)) { return "" }
    $text = Get-Content -Raw -Path $gradle
    $m = [regex]::Match($text, "applicationId\s*=\s*""([^""]+)""")
    if ($m.Success) { return $m.Groups[1].Value } else { return "" }
}

function Start-Uninstall {
    Ensure-Adb
    $appId = Get-AppId
    if (-not $appId -or $appId -eq "") { throw "Could not determine applicationId from android/app/build.gradle.kts" }
    Write-Output "Uninstalling $appId from connected device(s)..."
    Exec "adb uninstall $appId" (Get-Location)
}

function Start-InstallDebugApk {
    Ensure-Adb
    $root = Split-Path -Parent $PSScriptRoot
    $apk = Join-Path $root "build\app\outputs\flutter-apk\app-debug.apk"
    if (-not (Test-Path $apk)) {
        throw "Debug APK not found at $apk. Build first with 'flutter build apk --debug' or run app once."
    }
    Write-Output "Installing $apk (replace/downgrade allowed, test build allowed)..."
    Exec "adb install -r -d -t `"$apk`"" (Get-Location)
}

try {
    $cfg = Load-DevConfig
    if ($AdbPath -eq "" -and $cfg -and $cfg.adbPath) { $AdbPath = $cfg.adbPath }
    if ($Pair) { Start-Pair }
    if ($Connect) { Start-Connect }
    if ($Run) { Start-Run }
    if ($WatchPubspec) { Start-WatchPubspec }
    if ($Uninstall) { Start-Uninstall }
    if ($InstallApk) { Start-InstallDebugApk }
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
