param(
  [switch]$OpenLinks
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$gradleFile = Join-Path $repoRoot 'android/app/build.gradle.kts'
$androidDir = Join-Path $repoRoot 'android'
$gradlewBat = Join-Path $androidDir 'gradlew.bat'
$gradlewSh = Join-Path $androidDir 'gradlew'

if (-not (Test-Path $gradleFile)) {
  throw "Could not find gradle file at: $gradleFile"
}

$gradleText = Get-Content -Path $gradleFile -Raw
$applicationId = 'com.beastmusic.app'
$match = [regex]::Match($gradleText, 'applicationId\s*=\s*"([^"]+)"')
if ($match.Success -and $match.Groups.Count -ge 2) {
  $applicationId = $match.Groups[1].Value.Trim()
}

$gradleCmd = if (Test-Path $gradlewBat) { $gradlewBat } elseif (Test-Path $gradlewSh) { $gradlewSh } else { $null }
if ($null -eq $gradleCmd) {
  throw "Could not find gradlew in $androidDir"
}

Write-Host "Running signingReport to extract SHA-1..."
Push-Location $androidDir
try {
  if ($gradleCmd.EndsWith('.bat')) {
    $signingOutput = cmd /c "`"$gradleCmd`" signingReport 2>&1" | Out-String
  }
  else {
    $signingOutput = & $gradleCmd signingReport 2>&1 | Out-String
  }
}
finally {
  Pop-Location
}

$sha1 = $null
$debugVariant = [regex]::Match(
  $signingOutput,
  '(?ms)Variant:\s*debug.*?SHA1:\s*([A-F0-9:]{40,59})'
)
if ($debugVariant.Success -and $debugVariant.Groups.Count -ge 2) {
  $sha1 = $debugVariant.Groups[1].Value.Trim()
}

if ([string]::IsNullOrWhiteSpace($sha1)) {
  $firstSha = [regex]::Match($signingOutput, 'SHA1:\s*([A-F0-9:]{40,59})')
  if ($firstSha.Success -and $firstSha.Groups.Count -ge 2) {
    $sha1 = $firstSha.Groups[1].Value.Trim()
  }
}

if ([string]::IsNullOrWhiteSpace($sha1)) {
  $debugKeystore = Join-Path $env:USERPROFILE '.android\debug.keystore'
  if (Test-Path $debugKeystore) {
    try {
      $keytoolPath = $null
      $keytoolCmd = Get-Command keytool -ErrorAction SilentlyContinue
      if ($null -ne $keytoolCmd) {
        $keytoolPath = $keytoolCmd.Source
      }
      if ([string]::IsNullOrWhiteSpace($keytoolPath) -and -not [string]::IsNullOrWhiteSpace($env:JAVA_HOME)) {
        $candidate = Join-Path $env:JAVA_HOME 'bin\keytool.exe'
        if (Test-Path $candidate) {
          $keytoolPath = $candidate
        }
      }
      if ([string]::IsNullOrWhiteSpace($keytoolPath)) {
        $fallbackPaths = @(
          'C:\Program Files\Java\latest\bin\keytool.exe',
          'C:\Program Files\Java\jre1.8.0_471\bin\keytool.exe'
        )
        foreach ($p in $fallbackPaths) {
          if (Test-Path $p) {
            $keytoolPath = $p
            break
          }
        }
      }
      if ([string]::IsNullOrWhiteSpace($keytoolPath)) {
        throw 'keytool not found'
      }
      $keytoolOutput = & $keytoolPath -list -v -alias androiddebugkey -keystore $debugKeystore -storepass android -keypass android 2>&1 | Out-String
      $fromKeytool = [regex]::Match($keytoolOutput, 'SHA1:\s*([A-F0-9:]{40,59})')
      if ($fromKeytool.Success -and $fromKeytool.Groups.Count -ge 2) {
        $sha1 = $fromKeytool.Groups[1].Value.Trim()
      }
    }
    catch {
      # ignore and keep fallback value below
    }
  }
}

if ([string]::IsNullOrWhiteSpace($sha1)) {
  $sha1 = 'NOT_FOUND'
}

$enableApiUrl = 'https://console.cloud.google.com/apis/library/youtube.googleapis.com'
$credentialsUrl = 'https://console.cloud.google.com/apis/credentials'

$summary = @"
YouTube OAuth Setup Helper
--------------------------
Package name: $applicationId
Debug SHA-1 : $sha1

Open these pages:
1) Enable YouTube Data API v3: $enableApiUrl
2) Create OAuth Android client: $credentialsUrl
"@

if ($sha1 -eq 'NOT_FOUND') {
  $summary += "`n`nSHA-1 was not auto-detected. Run manually:`ncd android && ./gradlew signingReport"
}

Write-Host ""
Write-Host $summary
Write-Host ""
Write-Host "Copied summary to clipboard."
Set-Clipboard -Value $summary

if ($OpenLinks) {
  Start-Process $enableApiUrl
  Start-Process $credentialsUrl
}
