# Build native Flutter Windows + Inno Setup installer (PowerShell).
# Run from repo root on Windows or windows-latest CI.
$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $Root

$pubspec = Get-Content "app/pubspec.yaml"
$Version = (($pubspec | Where-Object { $_ -match '^version:' }) -split ':',2)[1].Trim().Split('+')[0]
$Stamp = if ($env:PRIVET_BUILD) { $env:PRIVET_BUILD } else { (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss") }
$Out = Join-Path $Root "server/public/downloads"
New-Item -ItemType Directory -Force -Path $Out | Out-Null

Push-Location app
flutter pub get
flutter build windows --release --dart-define="PRIVET_BUILD=$Stamp"
Pop-Location

$Release = Join-Path $Root "app/build/windows/x64/runner/Release"
if ((Test-Path (Join-Path $Release "Privet.exe")) -and -not (Test-Path (Join-Path $Release "privet.exe"))) {
  Copy-Item (Join-Path $Release "Privet.exe") (Join-Path $Release "privet.exe") -Force
}
if (-not (Test-Path (Join-Path $Release "privet.exe"))) {
  throw "Missing privet.exe in $Release"
}

$IsccCandidates = @(
  (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
  (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe"),
  (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe")
)
$Iscc = $IsccCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Iscc) {
  throw "Inno Setup 6 not found - install from https://jrsoftware.org/isinfo.php (or winget install JRSoftware.InnoSetup)"
}

& $Iscc `
  "/DMyAppVersion=$Version" `
  "/DSourceDir=$Release" `
  "/DOutputDir=$Out" `
  "/DMyAppIcon=$(Join-Path $Root 'app/windows/runner/resources/app_icon.ico')" `
  (Join-Path $Root "packaging/windows/privet.iss")

$Versioned = Join-Path $Out "Privet-Setup-$Version.exe"
$Stable = Join-Path $Out "Privet-Setup.exe"
Copy-Item $Versioned $Stable -Force
Write-Host "Wrote $Versioned"
Write-Host "Wrote $Stable (stamp=$Stamp)"

$Bash = @(
  "bash",
  (Join-Path ${env:ProgramFiles} "Git\bin\bash.exe"),
  (Join-Path ${env:ProgramFiles(x86)} "Git\bin\bash.exe")
) | Where-Object {
  if ($_ -eq "bash") { Get-Command bash -ErrorAction SilentlyContinue } else { Test-Path $_ }
} | Select-Object -First 1
if ($Bash) {
  & $Bash (Join-Path $Root "scripts/write-version-json.sh")
} else {
  Write-Warning "bash not found; skipped write-version-json.sh (version.json may be stale)"
}
