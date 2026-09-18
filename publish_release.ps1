# 새 클라이언트 버전을 빌드해서 server/releases/에 배포한다. 버전 번호는 client/pubspec.yaml의
# version:을 그대로 읽어서 쓴다 — 예전엔 -Version 인자로 따로 입력받았는데, 실제 빌드 시점의
# pubspec.yaml과 이 인자가 서로 다른 값일 수 있어서(둘 중 하나만 올리고 깜빡하는 실수) 서버가
# 광고하는 버전과 실제 설치되는 exe에 새겨진 버전이 어긋나는 사고가 있었다(업데이트를 설치해도
# 계속 "새 버전이 있습니다" 알약이 뜨던 원인) — pubspec.yaml 하나만 진짜로 취급하도록 없앴다.
# 사용법: .\publish_release.ps1 -Notes "이번 업데이트 내용" (버전은 client/pubspec.yaml의
# version:을 미리 올려두면 됨)
param(
  [string]$Notes = ""
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$client = Join-Path $root "client"
$releases = Join-Path $root "server\releases"

Write-Host "0) client/pubspec.yaml에서 버전 읽는 중..."
$pubspecPath = Join-Path $client "pubspec.yaml"
$versionLine = Get-Content $pubspecPath | Where-Object { $_ -match '^version:\s*\S+' } | Select-Object -First 1
if (-not $versionLine) { throw "client/pubspec.yaml에서 version: 값을 찾지 못했습니다." }
# Flutter 버전 형식은 "1.0.32" 또는 "1.0.32+5"(+뒤는 빌드 번호) — 뒷부분은 버전 비교/표시에
# 안 쓰니 뺀다(session.dart의 _isNewerVersion은 순수 점(.) 구분 숫자만 기대한다).
$Version = (($versionLine -replace '^version:\s*', '').Trim()).Split('+')[0]
Write-Host "   버전: $Version"

Write-Host "1) Android 릴리즈 빌드..."
Push-Location $client
flutter build apk --release
Pop-Location

Write-Host "2) Windows 릴리즈 빌드..."
Push-Location $client
flutter build windows --release
Pop-Location

Write-Host "3) Windows 설치 프로그램 컴파일..."
$iscc = Get-ChildItem "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" -ErrorAction SilentlyContinue
if (-not $iscc) { $iscc = Get-ChildItem "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" -ErrorAction SilentlyContinue }
if (-not $iscc) { throw "ISCC.exe를 찾을 수 없습니다. Inno Setup이 설치되어 있는지 확인하세요 (winget install JRSoftware.InnoSetup)." }
& $iscc.FullName "$client\windows\installer\messenger.iss"

Write-Host "4) server/releases/로 복사..."
New-Item -ItemType Directory -Force -Path $releases | Out-Null
Copy-Item "$client\windows\installer\output\messenger-setup.exe" "$releases\client-windows-setup.exe" -Force
Copy-Item "$client\build\app\outputs\flutter-apk\app-release.apk" "$releases\client-android.apk" -Force

$versionInfo = [ordered]@{ version = $Version; notes = $Notes }
$versionJson = $versionInfo | ConvertTo-Json
# Windows PowerShell 5.1의 Set-Content -Encoding utf8은 BOM을 붙여서, 그걸 그대로 읽는
# Node 쪽 JSON.parse가 실패한다 — .NET API로 BOM 없이 직접 써서 피해간다.
[System.IO.File]::WriteAllText("$releases\version.json", $versionJson, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "완료: $releases 에 버전 $Version 배포됨. 서버 재시작 없이 바로 새 버전을 알려줍니다."
