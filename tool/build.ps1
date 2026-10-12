# Builds Best Music on Windows.
#
#   powershell -ExecutionPolicy Bypass -File tool\build.ps1 apk
#   powershell -ExecutionPolicy Bypass -File tool\build.ps1 windows
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool\build.ps1 release
#
# "apk" / "windows" build a release APK (arm64, see below) / the Windows exe
# locally; nothing is committed or published.
#
# "release" is what the laptop builder (Mfficiency/laptop-builder) runs in its
# own clone for every push to dev, staging and main. Environment:
#   BUILD_CHANNEL  main | staging | dev (default main). Every channel builds the
#                  same app (com.mfficiency.best_music, "Best Music"); only the
#                  release tag carries the channel.
#   BUILD_NUMBER   versionCode (builder: minutes since 2020-01-01 UTC of the
#                  built commit, so it rises across branches); default: the
#                  pubspec build number.
#   PUBLISH=1      publish a GitHub release in Mfficiency/BestMusic (tag
#                  music-v<x.y.z>-<build>, plus -staging / -dev; those are
#                  prereleases) via tool/publish_apk.dart. Without it the APK
#                  is only built, into build/channel/.
#   FORCE_RELEASE=1  build even when the same code is released already.
# It commits and pushes nothing, exits 0 without building when the release
# already exists, and refuses to build without android/key.properties (the
# upload key every Best Music install is signed with; not in git).
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$BuildArgs
)

$ErrorActionPreference = "Stop"

# Exit code of a native command, without throwing or printing its output.
function Test-Native {
  param([string]$Exe, [string[]]$Arguments = @())
  $saved = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & $Exe @Arguments *> $null
    return $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $saved
  }
}

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [string[]]$Arguments = @()
  )

  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

# arm64 only, with the Dart debug symbols written to build/symbols instead of
# into libapp.so: the default fat APK carries the native libraries for three
# ABIs (~67 MB, ~95 % of it binaries the phone never loads); this is about a
# third. Not --split-per-abi (the updater takes a release's first .apk asset).
$sizeArgs = @("--target-platform", "android-arm64", "--split-debug-info=build/symbols")

function Get-PubspecVersion {
  $versionLine = Select-String -Path "pubspec.yaml" -Pattern "^version:" | Select-Object -First 1
  if ($null -eq $versionLine) {
    throw "Could not find version: in pubspec.yaml"
  }
  return (($versionLine.Line -split "\s+", 2)[1]).Trim()
}

# Same code, other branch: merging dev -> staging -> main makes new commits
# (so new build numbers) with code that is released already. The phone is one
# app that installs the highest build of any channel, so publishing those
# would offer the same update up to three times. Before building, release
# mode looks for a release whose commit has the same source fingerprint:
# every tracked file except what differs between branches without changing
# the app (CI files, screenshots, build-time lines in the changelog). Found ->
# nothing is built or published. FORCE_RELEASE=1 skips the check.
$script:FingerprintExclude = '^\.github/|(^|/)docs/screenshots/'
$script:BuildNoteLine = '^- (Local build|CI build|Build duration|APK size|Build size)\b'

function Get-TextHash {
  param([string]$Text)
  $hasher = [Security.Cryptography.SHA256]::Create()
  try {
    return ($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) |
      ForEach-Object { $_.ToString('x2') }) -join ''
  } finally {
    $hasher.Dispose()
  }
}

function Get-SourceFingerprint {
  param([string]$Commit)
  $items = New-Object 'System.Collections.Generic.List[string]'
  foreach ($entry in (& git -c core.quotepath=off ls-tree -r --full-tree $Commit)) {
    $tab = $entry.IndexOf("`t")
    $path = $entry.Substring($tab + 1)
    if ($path -match $script:FingerprintExclude) { continue }
    $id = ($entry.Substring(0, $tab) -split ' ')[2]
    if ($path -match '(^|/)CHANGELOG[^/]*\.md$') {
      $id = Get-TextHash ((@(& git cat-file blob $id) |
        Where-Object { $_ -notmatch $script:BuildNoteLine }) -join "`n")
    }
    $items.Add("$id $path")
  }
  return Get-TextHash ($items -join "`n")
}

# The newest release tag (of the newest $Limit matching $TagPattern, whose
# group 1 is the build number) built from the same code as $Commit, or $null.
function Find-ReleaseWithSameCode {
  param([string]$Commit, [string]$TagPattern, [int]$Limit = 20)
  if ("$env:FORCE_RELEASE" -eq '1') { return $null }
  $saved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $lines = @(& git ls-remote --tags origin 2> $null)
    if ($LASTEXITCODE -ne 0) { throw "git ls-remote --tags origin failed ($LASTEXITCODE)" }
    $commits = @{}
    $builds = @{}
    foreach ($line in $lines) {
      $parts = $line -split "`t"
      if ($parts.Count -ne 2 -or $parts[1] -notmatch '^refs/tags/(.+?)(\^\{\})?$') { continue }
      $name = $Matches[1]
      $peeled = $Matches[2] -ne $null -and $Matches[2] -ne ''
      $m = [regex]::Match($name, $TagPattern)
      if (-not $m.Success) { continue }
      # An annotated tag lists its tag object and then (^{}) its commit.
      if ($peeled -or -not $commits.ContainsKey($name)) { $commits[$name] = $parts[0] }
      $builds[$name] = [long]$m.Groups[1].Value
    }
    $ours = $null
    $newest = $builds.Keys | Sort-Object { $builds[$_] } -Descending | Select-Object -First $Limit
    foreach ($name in $newest) {
      $other = $commits[$name]
      & git cat-file -e "$other^{commit}" 2> $null
      if ($LASTEXITCODE -ne 0) { & git fetch -q --no-tags origin $other 2> $null }
      & git cat-file -e "$other^{commit}" 2> $null
      if ($LASTEXITCODE -ne 0) { continue }
      if ($null -eq $ours) { $ours = Get-SourceFingerprint $Commit }
      if ((Get-SourceFingerprint $other) -eq $ours) { return $name }
    }
    return $null
  } catch {
    Write-Warning "could not compare with earlier releases ($_); publishing as usual"
    return $null
  } finally {
    $ErrorActionPreference = $saved
  }
}

function Assert-KeyProperties {
  $path = "android/key.properties"
  if (-not (Test-Path -LiteralPath $path)) {
    throw "release mode needs android/key.properties (the upload key) -- refusing to build a debug-signed APK"
  }
  $props = @{}
  foreach ($line in Get-Content -LiteralPath $path) {
    if ($line -match '^\s*([^#=]+?)\s*=\s*(.*?)\s*$') {
      $props[$Matches[1]] = $Matches[2]
    }
  }
  foreach ($key in @("storeFile", "storePassword", "keyAlias", "keyPassword")) {
    if ([string]::IsNullOrWhiteSpace($props[$key])) {
      throw "android/key.properties has no $key -- refusing to build a debug-signed APK"
    }
  }
  $store = $props["storeFile"]
  # Gradle resolves a relative storeFile against android/app.
  if (-not [System.IO.Path]::IsPathRooted($store)) {
    $store = Join-Path "android/app" $store
  }
  if (-not (Test-Path -LiteralPath $store)) {
    throw "keystore $($props['storeFile']) (from android/key.properties) not found"
  }
}

function Invoke-ChannelRelease {
  $channel = if ([string]::IsNullOrWhiteSpace($env:BUILD_CHANNEL)) { "main" } else { $env:BUILD_CHANNEL.Trim().ToLower() }
  if (@("main", "staging", "dev") -notcontains $channel) {
    throw "BUILD_CHANNEL must be dev, staging or main (got '$channel')"
  }
  $env:BUILD_CHANNEL = $channel
  $buildNumber = "$env:BUILD_NUMBER".Trim()
  if ($buildNumber -ne "" -and $buildNumber -notmatch '^\d+$') {
    throw "BUILD_NUMBER must be an integer (got '$buildNumber')"
  }
  $publish = ($env:PUBLISH -eq "1")
  $sha = (& git rev-parse HEAD).Trim()
  $numberArgs = @()
  if ($buildNumber -ne "") { $numberArgs = @("--build-number", $buildNumber) }

  Write-Host "==> release: channel=$channel build=$(if ($buildNumber) { $buildNumber } else { '(pubspec)' }) publish=$publish"

  if ($publish) {
    & dart run tool/publish_apk.dart --channel $channel @numberArgs --exists
    $status = $LASTEXITCODE
    if ($status -eq 0) {
      Write-Host "==> release for this build already exists -- nothing to do"
      return
    }
    if ($status -ne 2) {
      throw "could not check for an existing release (exit $status)"
    }
    $same = Find-ReleaseWithSameCode $sha '^music-v\d+\.\d+\.\d+-(\d+)(-dev|-staging)?$'
    if ($same) {
      Write-Host "==> same code as release $same -- skipping (FORCE_RELEASE=1 builds anyway)"
      return
    }
  }

  Assert-KeyProperties
  # Belt and braces: android/app/build.gradle.kts fails the build instead of
  # falling back to the debug key when this is set.
  $env:REQUIRE_RELEASE_KEY = "1"

  $apk = "build/app/outputs/flutter-apk/app-release.apk"
  # Never pick up a previous build's leftover.
  if (Test-Path -LiteralPath $apk) { Remove-Item -LiteralPath $apk -Force }

  $flutterArgs = @("build", "apk", "--release") + $sizeArgs +
    @("--dart-define=BUILD_CHANNEL=$channel")
  if ($buildNumber -ne "") {
    $flutterArgs += @("--build-number=$buildNumber", "--dart-define=BUILD_NUMBER=$buildNumber")
  }
  Write-Host "==> flutter $($flutterArgs -join ' ')"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  & flutter @flutterArgs
  $status = $LASTEXITCODE
  $sw.Stop()
  if ($status -ne 0) { throw "flutter build failed (exit $status)" }
  if (-not (Test-Path -LiteralPath $apk)) { throw "build produced no $apk" }
  $seconds = [int][Math]::Round($sw.Elapsed.TotalSeconds)

  # A copy named like its release asset, for testing by hand.
  $suffix = if ($channel -eq "main") { "" } else { "-$channel" }
  $name = ((Get-PubspecVersion) -split '\+')[0]
  $number = if ($buildNumber -ne "") { $buildNumber } else { ((Get-PubspecVersion) -split '\+')[1] }
  New-Item -ItemType Directory -Force -Path "build/channel" | Out-Null
  $out = "build/channel/BestMusic-$name+$number$suffix.apk"
  Copy-Item -LiteralPath $apk -Destination $out -Force
  Write-Host "    built $out in ${seconds}s"

  if (-not $publish) {
    Write-Host "    PUBLISH is not 1: nothing published"
    return
  }
  Invoke-Checked "dart" (@("run", "tool/publish_apk.dart", "--channel", $channel,
    "--apk", $out, "--target", $sha, "--duration", "$seconds") + $numberArgs)
}

Set-Location (Resolve-Path (Join-Path $PSScriptRoot ".."))

$mode = if ($BuildArgs.Count -gt 0) { $BuildArgs[0] } else { "" }
$rest = if ($BuildArgs.Count -gt 1) { $BuildArgs[1..($BuildArgs.Count - 1)] } else { @() }
switch ($mode) {
  "release" { Invoke-ChannelRelease }
  "apk" { Invoke-Checked "flutter" (@("build", "apk", "--release") + $sizeArgs + $rest) }
  "windows" { Invoke-Checked "flutter" (@("build", "windows", "--release") + $rest) }
  default {
    Write-Host "Usage: tool\build.ps1 release | apk [flutter args] | windows [flutter args]"
    exit 64
  }
}
