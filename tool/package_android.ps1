[CmdletBinding()]
param(
    [switch]$UseCurrentVersion,
    [string]$AuthBaseUrl = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$pubspecPath = Join-Path $projectRoot 'pubspec.yaml'
$versionSourcePath = Join-Path $projectRoot 'lib/app_version.dart'
$downloadPagePath = Join-Path $projectRoot 'release/download.html'
$apkSourcePath = Join-Path $projectRoot 'build/app/outputs/flutter-apk/app-release.apk'

$pubspecOriginal = [System.IO.File]::ReadAllText($pubspecPath)
$versionSourceOriginal = [System.IO.File]::ReadAllText($versionSourcePath)
$versionMatch = [regex]::Match($pubspecOriginal, '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$')
if (-not $versionMatch.Success) {
    throw 'pubspec.yaml 中的 version 必须使用 major.minor.patch+build 格式。'
}

$major = [int]$versionMatch.Groups[1].Value
$minor = [int]$versionMatch.Groups[2].Value
$patch = [int]$versionMatch.Groups[3].Value
$buildNumber = [int]$versionMatch.Groups[4].Value
if (-not $UseCurrentVersion) {
    $patch++
    $buildNumber++
}
$versionName = "$major.$minor.$patch"
$versionValue = "$versionName+$buildNumber"

if (-not [string]::IsNullOrWhiteSpace($AuthBaseUrl)) {
    $parsedAuthUrl = $null
    if (-not [System.Uri]::TryCreate($AuthBaseUrl.Trim(), [System.UriKind]::Absolute, [ref]$parsedAuthUrl) -or
        $parsedAuthUrl.Scheme -ne 'https' -or
        [string]::IsNullOrWhiteSpace($parsedAuthUrl.Host) -or
        -not [string]::IsNullOrEmpty($parsedAuthUrl.UserInfo) -or
        -not [string]::IsNullOrEmpty($parsedAuthUrl.Query) -or
        -not [string]::IsNullOrEmpty($parsedAuthUrl.Fragment)) {
        throw 'AuthBaseUrl 必须是有效且不含凭据、查询参数或片段的 HTTPS 地址。'
    }
}

$localPropertiesPath = Join-Path $projectRoot 'android/local.properties'
$localProperties = @{}
if (Test-Path -LiteralPath $localPropertiesPath) {
    foreach ($line in Get-Content -LiteralPath $localPropertiesPath) {
        if ($line -match '^([^=]+)=(.*)$') {
            $slash = [char]92
            $doubleSlash = "$slash$slash"
            $localProperties[$Matches[1]] = $Matches[2].Replace($doubleSlash, [string]$slash)
        }
    }
}
if (-not [string]::IsNullOrWhiteSpace($localProperties['sdk.dir']) -and
    (Test-Path -LiteralPath $localProperties['sdk.dir'])) {
    $env:ANDROID_HOME = $localProperties['sdk.dir']
    $env:ANDROID_SDK_ROOT = $localProperties['sdk.dir']
}
$flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
$flutterExe = $null
if ($null -ne $flutterCommand) {
    $flutterExe = $flutterCommand.Source
} else {
    if (Test-Path -LiteralPath $localPropertiesPath) {
        $sdkLine = Get-Content -LiteralPath $localPropertiesPath | Where-Object { $_ -match '^flutter\.sdk=' } | Select-Object -First 1
        if ($null -ne $sdkLine) {
            $slash = [char]92
            $doubleSlash = "$slash$slash"
            $flutterRoot = ($sdkLine -replace '^flutter\.sdk=', '').Replace($doubleSlash, [string]$slash)
            $flutterExe = Join-Path $flutterRoot 'bin/flutter.bat'
        }
    }
}
if ([string]::IsNullOrWhiteSpace($flutterExe) -or -not (Test-Path -LiteralPath $flutterExe)) {
    throw '找不到 Flutter SDK。请把 flutter 加入 PATH，或在 android/local.properties 中配置 flutter.sdk。'
}

$pubspecUtf8 = [System.Text.UTF8Encoding]::new($false)
$versionChanged = -not $UseCurrentVersion
try {
    if ($versionChanged) {
        $pubspecUpdated = [regex]::Replace(
            $pubspecOriginal,
            '(?m)^version:\s*\d+\.\d+\.\d+\+\d+\s*$',
            "version: $versionValue",
            1
        )
        $versionSourceUpdated = [regex]::Replace(
            $versionSourceOriginal,
            "defaultValue:\s*'\d+\.\d+\.\d+'",
            "defaultValue: '$versionName'",
            1
        )
        [System.IO.File]::WriteAllText($pubspecPath, $pubspecUpdated, $pubspecUtf8)
        [System.IO.File]::WriteAllText($versionSourcePath, $versionSourceUpdated, $pubspecUtf8)
    }

    # Let Flutter generate the Android plugin registrant, including the JNI plugin.
    $buildArguments = @(
        'build',
        'apk',
        '--release',
        '--build-name',
        $versionName,
        '--build-number',
        $buildNumber.ToString(),
        "--dart-define=APP_VERSION=$versionName"
    )
    if (-not [string]::IsNullOrWhiteSpace($AuthBaseUrl)) {
        $buildArguments += "--dart-define=CWHale_AUTH_BASE_URL=$($AuthBaseUrl.Trim())"
    }
    & $flutterExe @buildArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter release 构建失败，退出码：$LASTEXITCODE"
    }
    if (-not (Test-Path -LiteralPath $apkSourcePath)) {
        throw "构建命令成功，但未找到 APK：$apkSourcePath"
    }

    $releaseDirectory = Join-Path $projectRoot 'release'
    if (-not (Test-Path -LiteralPath $releaseDirectory)) {
        New-Item -ItemType Directory -Path $releaseDirectory | Out-Null
    }
    $apkDestinationPath = Join-Path $releaseDirectory "Cwhale-$versionName.apk"
    Copy-Item -LiteralPath $apkSourcePath -Destination $apkDestinationPath -Force
    $apkHash = (Get-FileHash -LiteralPath $apkDestinationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $apkSizeMb = [math]::Round((Get-Item -LiteralPath $apkDestinationPath).Length / 1MB)

    if (Test-Path -LiteralPath $downloadPagePath) {
        $downloadPage = [System.IO.File]::ReadAllText($downloadPagePath)
        $downloadPage = [regex]::Replace($downloadPage, 'href="\./Cwhale-[^"]+\.apk"', "href=`"./Cwhale-$versionName.apk`"", 1)
        $downloadPage = [regex]::Replace($downloadPage, '版本 [^<]*', "版本 $versionName · Android 7.0 及以上 · 约 $apkSizeMb MB", 1)
        $downloadPage = [regex]::Replace($downloadPage, '(?<=<code>)[0-9a-fA-F]{64}(?=</code>)', $apkHash, 1)
        [System.IO.File]::WriteAllText($downloadPagePath, $downloadPage, $pubspecUtf8)
    }

    Write-Host "已构建 Cwhale $versionName（build $buildNumber）"
    Write-Host "APK：$apkDestinationPath"
    Write-Host "SHA-256：$apkHash"
} catch {
    if ($versionChanged) {
        [System.IO.File]::WriteAllText($pubspecPath, $pubspecOriginal, $pubspecUtf8)
        [System.IO.File]::WriteAllText($versionSourcePath, $versionSourceOriginal, $pubspecUtf8)
    }
    throw
}
