# 새 클라이언트 버전을 빌드해서 server/releases/에 배포한다.
# 사용법: .\publish_release.ps1 -Version "1.0.1" -Notes "이번 업데이트 내용"
# client/pubspec.yaml의 version:도 같이 올려두는 걸 잊지 마세요(클라이언트 자신의 버전 번호).
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$Notes = ""
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$client = Join-Path $root "client"
$releases = Join-Path $root "server\releases"

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
($versionInfo | ConvertTo-Json) | Set-Content -Path "$releases\version.json" -Encoding utf8

Write-Host "완료: $releases 에 버전 $Version 배포됨. 서버 재시작 없이 바로 새 버전을 알려줍니다."
