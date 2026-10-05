<#
.SYNOPSIS
  xiaoshuo build-all script (Android)
.DESCRIPTION
  One-shot release script: bump pubspec version -> flutter build apk ->
  upload to xiaoshuo-server via HTTP /api/app/upload (X-Upload-Token).
  Server saves the APK to xiaoshuo_data/apks/ and rewrites latest.json
  automatically; clients detect the new version on next app start.
.PARAMETER Version
  Version string (required), e.g. 1.1.1. Build number auto-increments from pubspec.
.PARAMETER Notes
  Release notes (optional), shown in the in-app update dialog.
.PARAMETER ServerUrl
  xiaoshuo-server base URL. Default: http://192.168.31.16:18004 (NAS).
.PARAMETER UploadToken
  Upload token matching server XS_UPLOAD_TOKEN.
.PARAMETER SkipServer
  Build only, skip upload.
.EXAMPLE
  .\build_all.ps1 -Version 1.1.1 -Notes "修复若干问题"
.EXAMPLE
  .\build_all.ps1 -Version 1.1.1 -SkipServer   # 只打包不上传
.EXAMPLE
  .\build_all.ps1 -Version 1.1.1 -Dev -Notes "测试新功能"   # 测试包，走 dev 更新通道
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$Version,

    [Parameter(Mandatory=$false)]
    [string]$Notes = "",

    [Parameter(Mandatory=$false)]
    [string]$ServerUrl = "http://192.168.31.16:18004",

    [Parameter(Mandatory=$false)]
    [string]$UploadToken = "e5361412d64151c5f1306aabba640e98",

    # 测试包：--dart-define=APP_CHANNEL=dev，上传到 dev 更新通道（apks/dev/），
    # 只推给 DEV 包，生产包不受影响；设置页显示 DEV 角标
    [switch]$Dev,

    [switch]$SkipServer
)

$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot
$pubspecPath = Join-Path $projectRoot "pubspec.yaml"

function Write-Step($msg) { Write-Host ""; Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    [!]  $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "    [X]  $msg" -ForegroundColor Red }

# Upload the APK to xiaoshuo-server via HTTP /api/app/upload.
# Server-side saves the file into xiaoshuo_data/apks/ and rewrites latest.json.
function Upload-Apk {
    param(
        [string]$TargetUrl,
        [string]$Token,
        [string]$Ver,
        [int]$VerCode,
        [string]$ReleaseNotes,
        [string]$FilePath,
        [bool]$IsDev = $false
    )
    if (-not (Test-Path $FilePath)) { Write-Err "file not found: $FilePath"; return $false }

    # URL-encode notes (handles Chinese characters safely)
    $encodedNotes = [Uri]::EscapeDataString($ReleaseNotes)
    $channelParam = if ($IsDev) { "&channel=dev" } else { "" }
    $endpoint = "$TargetUrl/api/app/upload?platform=android&version=$Ver&version_code=$VerCode&notes=$encodedNotes$channelParam"

    $fileItem = Get-Item $FilePath
    Write-Host "    -> uploading $($fileItem.Name) ($([math]::Round($fileItem.Length/1MB,1)) MB)..." -ForegroundColor Gray

    # curl.exe ships with Windows 10+, multipart form upload natively.
    # IMPORTANT: do NOT pipe curl output through ForEach-Object — that would overwrite
    # $LASTEXITCODE with the cmdlet's exit code (always 0) and mask curl failures.
    $curlArgs = @(
        "-sS", "-X", "POST",
        $endpoint,
        "-H", "X-Upload-Token: $Token",
        "-F", "file=@$FilePath"
    )
    $output = & curl.exe @curlArgs 2>&1
    $curlExit = $LASTEXITCODE

    Write-Host "    server response: $output" -ForegroundColor Gray

    if ($curlExit -eq 0 -and $output -match '"code"\s*:\s*0') {
        Write-Ok "APK uploaded (version_code=$VerCode)"
        return $true
    } else {
        Write-Err "upload failed (curl exit=$curlExit)"
        Write-Err "    response: $output"
        return $false
    }
}

# ─────────────────────────────────────────────────────────────
# 0. Pre-check
# ─────────────────────────────────────────────────────────────
Write-Step "Environment check"

$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutter) { Write-Err "flutter not found in PATH"; exit 1 }
Write-Ok "Flutter: $($flutter.Source)"

if (-not $SkipServer) {
    $ServerUrl = $ServerUrl.Trim().TrimEnd("/")
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) { Write-Err "curl.exe not found in PATH (required for HTTP upload)"; exit 1 }
    Write-Ok "curl.exe: $($curl.Source)"
    Write-Ok "ServerUrl: $ServerUrl"
} else {
    Write-Warn "-SkipServer: build only, no upload"
}

# ─────────────────────────────────────────────────────────────
# 1. Update pubspec.yaml version (build number auto-increments)
# ─────────────────────────────────────────────────────────────
# pubspec/Android 要求三段式版本（MAJOR.MINOR.PATCH），两段式（如 1.0）会让
# flutter 构建直接失败，先校验再动 pubspec
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    Write-Err "Version 必须是三段式，例如 1.1.2（你输入的是: $Version）"
    exit 1
}
Write-Step "Update pubspec.yaml version -> $Version"

if (-not (Test-Path $pubspecPath)) { Write-Err "pubspec.yaml not found"; exit 1 }

$pubspec = Get-Content $pubspecPath -Raw
if ($pubspec -match "(?m)^version:\s*\d+\.\d+\.\d+(\+\d+)?\s*$") {
    $buildNumber = 1
    if ($pubspec -match "version:\s*\d+\.\d+\.\d+\+(\d+)") {
        $buildNumber = [int]$Matches[1] + 1
    }
    $newVersionLine = "version: $Version+$buildNumber"
    $pubspec = $pubspec -replace "(?m)^version:.*$", $newVersionLine
    # PowerShell 5 default encoding is not UTF-8, must force it
    [System.IO.File]::WriteAllText($pubspecPath, $pubspec, (New-Object System.Text.UTF8Encoding $false))
    Write-Ok "pubspec.yaml updated: version: $Version+$buildNumber (version_code=$buildNumber)"
} else {
    Write-Warn "pubspec.yaml version line not matched, please check manually"
    exit 1
}

# ─────────────────────────────────────────────────────────────
# 2. Build Android APK
# ─────────────────────────────────────────────────────────────
Write-Step "Build Android APK"

Push-Location $projectRoot
# flutter writes progress/warnings to stderr. Under $ErrorActionPreference="Stop"
# PowerShell treats stderr lines as RemoteException and aborts. Temporarily relax
# to "Continue" and judge success by $LASTEXITCODE + expected output file.
$savedEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
# dev 测试包：独立包名（.dev 后缀）与生产并排共存 + dart-define 走 dev 更新通道
$flavor = if ($Dev) { "dev" } else { "prod" }
$dartDefine = if ($Dev) { "--dart-define=APP_CHANNEL=dev" } else { "" }
& flutter build apk --release --flavor $flavor $dartDefine 2>&1 | Out-Null
$apkBuildExit = $LASTEXITCODE
$ErrorActionPreference = $savedEAP
if ($apkBuildExit -ne 0) { Write-Err "flutter build apk failed"; Pop-Location; exit 1 }
Pop-Location

$apkPath = Join-Path $projectRoot "build\app\outputs\flutter-apk\app-$flavor-release.apk"
if (-not (Test-Path $apkPath)) { Write-Err "APK not found: $apkPath"; exit 1 }
$apkSize = (Get-Item $apkPath).Length
Write-Ok "Android APK: $apkPath ($([math]::Round($apkSize/1MB,1)) MB)"

# ─────────────────────────────────────────────────────────────
# 3. Upload to xiaoshuo-server
# ─────────────────────────────────────────────────────────────
if (-not $SkipServer) {
    Write-Step "Upload to $ServerUrl"
    $relNotes = if ($Dev -and -not $Notes.StartsWith("[DEV]")) { "[DEV] $Notes" } else { $Notes }
    $r = Upload-Apk -TargetUrl $ServerUrl -Token $UploadToken `
        -Ver $Version -VerCode $buildNumber -ReleaseNotes $relNotes -FilePath $apkPath -IsDev:$Dev
    if (-not $r) {
        Write-Err "Upload failed. Fix and re-run, or upload manually:"
        Write-Err "  scp $apkPath -> NAS:xiaoshuo_data/apks/latest.apk + update latest.json"
        exit 1
    }
    Write-Ok "Server latest.json updated. Clients detect the new version on next app start."
} else {
    Write-Warn "Skipped upload (-SkipServer). Manual publish: copy APK to NAS xiaoshuo_data/apks/latest.apk + update latest.json"
}

# ─────────────────────────────────────────────────────────────
# 4. Done
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
$channelTag = if ($Dev) { " (DEV channel)" } else { "" }
Write-Host "  Build done! Version: $Version+$buildNumber$channelTag" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Android:  $apkPath"
Write-Host ""
