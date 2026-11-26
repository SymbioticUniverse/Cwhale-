param(
  [string]$AuthBaseUrl = 'https://www.symbioticuniverse.com',
  [switch]$NoPub
)

$ErrorActionPreference = 'Stop'

if (-not [string]::IsNullOrWhiteSpace($AuthBaseUrl)) {
  $parsedAuthUrl = $null
  if (-not [System.Uri]::TryCreate($AuthBaseUrl.Trim(), [System.UriKind]::Absolute, [ref]$parsedAuthUrl) -or
      $parsedAuthUrl.Scheme -ne 'https' -or
      [string]::IsNullOrWhiteSpace($parsedAuthUrl.Host) -or
      -not [string]::IsNullOrEmpty($parsedAuthUrl.UserInfo) -or
      -not [string]::IsNullOrEmpty($parsedAuthUrl.Query) -or
      -not [string]::IsNullOrEmpty($parsedAuthUrl.Fragment)) {
    throw 'AuthBaseUrl must be a valid HTTPS URL without credentials, query parameters, or a fragment.'
  }
}

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$flutterCommand = Get-Command flutter -ErrorAction Stop
$versionLine = Get-Content (Join-Path $projectRoot 'pubspec.yaml') |
  Where-Object { $_ -match '^version:' } |
  Select-Object -First 1
if (-not $versionLine) {
  throw 'Could not read the application version from pubspec.yaml.'
}
$version = ($versionLine -replace '^version:\s*', '').Trim()
$displayVersion = ($version -split '\+')[0]

Push-Location $projectRoot
try {
  & (Join-Path $PSScriptRoot 'generate_windows_icon.ps1')

  $buildArguments = @('build', 'windows', '--release')
  $buildArguments += "--dart-define=APP_VERSION=$displayVersion"
  if ($NoPub) {
    $buildArguments += '--no-pub'
  }
  if (-not [string]::IsNullOrWhiteSpace($AuthBaseUrl)) {
    $buildArguments += "--dart-define=CWHale_AUTH_BASE_URL=$($AuthBaseUrl.Trim())"
  }
  & $flutterCommand.Source @buildArguments
  if ($LASTEXITCODE -ne 0) {
    throw "flutter build windows failed with exit code $LASTEXITCODE."
  }

  $buildCandidates = @(
    (Join-Path $projectRoot 'build\windows\x64\runner\Release'),
    (Join-Path $projectRoot 'build\windows\runner\Release')
  )
  $buildDirectory = $buildCandidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
    Select-Object -First 1
  if (-not $buildDirectory) {
    throw 'Flutter completed but the Windows release bundle was not found.'
  }

  $releaseDirectory = Join-Path $projectRoot 'release'
  $portableDirectory = Join-Path $releaseDirectory "Cwhale-$version-windows-x64"
  New-Item -ItemType Directory -Path $portableDirectory -Force | Out-Null
  Get-ChildItem -LiteralPath $buildDirectory -Force |
    Copy-Item -Destination $portableDirectory -Recurse -Force

  $portableArchive = Join-Path $releaseDirectory "Cwhale-$version-windows-x64-portable.zip"
  Compress-Archive -Path (Join-Path $portableDirectory '*') `
    -DestinationPath $portableArchive -Force
  Write-Output "Portable bundle: $portableArchive"

  $compilerCandidates = @(
    (Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
  $compiler = $compilerCandidates | Select-Object -First 1
  if (-not $compiler) {
    Write-Output 'Inno Setup 6 was not found; the portable ZIP is ready.'
    return
  }

  & $compiler "/DAppVersion=$displayVersion" `
    "/DAppSourceDir=$buildDirectory" `
    "/DOutputDir=$releaseDirectory" `
    (Join-Path $PSScriptRoot 'windows_installer.iss')
  if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup failed with exit code $LASTEXITCODE."
  }
} finally {
  Pop-Location
}
