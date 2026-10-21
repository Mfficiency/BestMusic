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
#   WEAR=0         skip the Wear OS watch app (see below).
# It commits and pushes nothing, exits 0 without building when the release
# already exists, and refuses to build without android/key.properties (the
# upload key every Best Music install is signed with; not in git).
#
# After the phone APK (built, and published with PUBLISH=1), "release" also
# builds the Wear OS watch app (wear/, its own Gradle build, see
# wear/README.md) into build/wear/ and, with PUBLISH=1, publishes it as a
# separate GitHub release, tag wear-<phone tag> (never "Latest"; the phone's
# updater only takes music-v<digit>... tags). That step can't fail or change
# the phone release: any error is a warning, plus a WEAR_BUILD_RESULT line.
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

# The Wear OS watch app (wear/): built after the phone release, published
# (PUBLISH=1) as its own release wear-<phone tag>. Never throws and leaves
# $LASTEXITCODE and the environment as they were, so the phone release's
# result is exactly what it would be without it. WEAR=0 skips it.
function Invoke-WearRelease {
  param(
    [string]$Channel,
    [string]$Version,
    [string]$Number,
    [string]$Suffix,
    [string]$Sha,
    [bool]$Publish
  )
  if ("$env:WEAR" -eq "0") {
    Write-Host "==> watch: WEAR=0 -- skipped"
    Write-Host "WEAR_BUILD_RESULT status=skipped"
    return
  }
  $savedExit = $global:LASTEXITCODE
  $savedRequire = $env:REQUIRE_RELEASE_KEY
  $savedJava = $env:JAVA_HOME
  try {
    $phoneTag = "music-v$Version-$Number$Suffix"
    $tag = "wear-$phoneTag"
    $gradlew = Join-Path (Get-Location) "wear\gradlew.bat"
    if (-not (Test-Path -LiteralPath $gradlew)) { throw "$gradlew not found" }
    # Flutter writes android/local.properties (sdk.dir=...): the watch build
    # uses the same Android SDK.
    $sdkLine = $null
    if (Test-Path -LiteralPath "android/local.properties") {
      $sdkLine = Get-Content -LiteralPath "android/local.properties" |
        Where-Object { $_ -match '^\s*sdk\.dir\s*=' } | Select-Object -First 1
    }
    if ($sdkLine) {
      Set-Content -LiteralPath "wear/local.properties" -Value $sdkLine -Encoding ASCII
    } elseif ([string]::IsNullOrWhiteSpace($env:ANDROID_HOME) -and [string]::IsNullOrWhiteSpace($env:ANDROID_SDK_ROOT)) {
      throw "no sdk.dir in android/local.properties and no ANDROID_HOME"
    }
    if ([string]::IsNullOrWhiteSpace($env:JAVA_HOME)) {
      $jbr = "C:\Program Files\Android\Android Studio\jbr"
      if (Test-Path -LiteralPath $jbr) { $env:JAVA_HOME = $jbr }
    }
    # wear/app/build.gradle.kts refuses the debug key when this is set.
    $env:REQUIRE_RELEASE_KEY = "1"
    $wearApk = "wear/app/build/outputs/apk/release/app-release.apk"
    if (Test-Path -LiteralPath $wearApk) { Remove-Item -LiteralPath $wearApk -Force }
    Write-Host "==> watch: wear\gradlew.bat -p wear assembleRelease (build $Number, $Version)"
    Invoke-Checked $gradlew @("-p", "wear", "assembleRelease", "-PbuildNumber=$Number",
      "-PversionName=$Version", "--no-daemon")
    if (-not (Test-Path -LiteralPath $wearApk)) { throw "the watch build produced no $wearApk" }
    New-Item -ItemType Directory -Force -Path "build/wear" | Out-Null
    $out = "build/wear/BestMusic-Watch-$Version-$Number$Suffix.apk"
    Copy-Item -LiteralPath $wearApk -Destination $out -Force
    Write-Host "    built $out"
    if (-not $Publish) {
      Write-Host "WEAR_BUILD_RESULT status=built apk=$out"
      return
    }
    $repo = "Mfficiency/BestMusic"
    if ((Test-Native "gh" @("release", "view", $tag, "--repo", $repo)) -eq 0) {
      Invoke-Checked "gh" @("release", "upload", $tag, $out, "--repo", $repo, "--clobber")
    } else {
      $title = "Best Music Watch $Version ($Channel)"
      $notes = "Wear OS watch app for Best Music [$phoneTag](https://github.com/$repo/releases/tag/$phoneTag) " +
        "(same build, same signing key). Install it on the watch with wireless ADB: " +
        "``adb -s <watch-ip>:<port> install -r $(Split-Path $out -Leaf)`` (wear/README.md)."
      $ghArgs = @("release", "create", $tag, $out, "--repo", $repo, "--title", $title,
        "--notes", $notes, "--target", $Sha, "--latest=false")
      if ($Channel -ne "main") { $ghArgs += "--prerelease" }
      Invoke-Checked "gh" $ghArgs
    }
    Write-Host "WEAR_BUILD_RESULT status=published tag=$tag apk=$out"
  } catch {
    Write-Warning "Watch APK not built: $_"
    Write-Host "WEAR_BUILD_RESULT status=failed"
  } finally {
    $env:REQUIRE_RELEASE_KEY = $savedRequire
    $env:JAVA_HOME = $savedJava
    $global:LASTEXITCODE = $savedExit
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
    Invoke-WearRelease -Channel $channel -Version $name -Number $number -Suffix $suffix -Sha $sha -Publish $false
    return
  }
  Invoke-Checked "dart" (@("run", "tool/publish_apk.dart", "--channel", $channel,
    "--apk", $out, "--target", $sha, "--duration", "$seconds") + $numberArgs)
  Invoke-WearRelease -Channel $channel -Version $name -Number $number -Suffix $suffix -Sha $sha -Publish $true
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
