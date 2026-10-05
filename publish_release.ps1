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
$buildExit = $LASTEXITCODE
Pop-Location
# 외부 명령(flutter/ISCC)은 실패해도 위 $ErrorActionPreference로 멈추지 않는다 — 코드를 직접 봐야
# 한다. 안 보면 그대로 진행해서 예전 apk/설치 파일을 releases로 복사해 버릴 수 있다.
if ($buildExit -ne 0) { throw "Android 빌드 실패(코드 $buildExit)" }

Write-Host "2) Windows 릴리즈 빌드..."
Push-Location $client
# 빌드 폴더에서 띄워 둔 앱이 살아 있으면 링커가 client.exe를 덮어쓰지 못해서
# "LNK1104: 파일을 열 수 없습니다"로 실패한다. 그 폴더에서 실행 중인 것만 골라서 끈다
# (설치된 앱 C:\Users\...\AppData\Local\TangoTalk\client.exe 는 건드리지 않는다).
$buildExe = "$client\build\windows\x64\runner\Release\client.exe"
Get-CimInstance Win32_Process -Filter "Name='client.exe'" |
  Where-Object { $_.ExecutablePath -eq $buildExe } |
  ForEach-Object {
    Write-Host "   빌드 폴더에서 실행 중인 앱을 종료합니다 (PID $($_.ProcessId))"
    Stop-Process -Id $_.ProcessId -Force
  }

# 버전만 올렸을 때 client.exe가 다시 링크되지 않아 예전 버전 번호가 그대로 박히는 문제가 있다.
# 앱은 자기 버전을 client.exe의 버전 정보에서 읽으므로(package_info_plus), 그러면 업데이트를
# 설치해도 계속 "새 버전 있음"으로 뜬다. Runner.rc를 건드려 버전 리소스를 매번 다시 컴파일한다.
(Get-Item "$client\windows\runner\Runner.rc").LastWriteTime = Get-Date
flutter build windows --release
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "Windows 빌드 실패(코드 $LASTEXITCODE)" }
$builtVersion = (Get-Item "$client\build\windows\x64\runner\Release\client.exe").VersionInfo.FileVersion
if ($builtVersion -ne $Version) { throw "client.exe 버전이 $builtVersion 입니다(기대: $Version). 빌드가 버전을 반영하지 못했습니다." }
Pop-Location

Write-Host "3) Windows 설치 프로그램 컴파일..."
$iscc = Get-ChildItem "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" -ErrorAction SilentlyContinue
if (-not $iscc) { $iscc = Get-ChildItem "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" -ErrorAction SilentlyContinue }
if (-not $iscc) { throw "ISCC.exe를 찾을 수 없습니다. Inno Setup이 설치되어 있는지 확인하세요 (winget install JRSoftware.InnoSetup)." }
# Inno Setup은 막 만든 설치 파일에 아이콘·버전 정보를 써 넣는데, 그 순간 백신(Windows Defender
# 실시간 검사)이 새 exe를 검사하느라 잠가 두면 "EndUpdateResource failed ... (110)"로 가끔 실패한다.
# 다시 돌리면 대개 되므로 세 번까지 해 보고, 그래도 안 되면 복사 전에 멈춘다.
for ($attempt = 1; $attempt -le 3; $attempt++) {
  & $iscc.FullName "$client\windows\installer\messenger.iss"
  if ($LASTEXITCODE -eq 0) { break }
  if ($attempt -eq 3) {
    throw "설치 프로그램 컴파일이 3번 모두 실패했습니다(코드 $LASTEXITCODE). 백신이 client\windows\installer\output 폴더를 잠그는 것이면 그 폴더를 검사 제외에 넣고 다시 실행하세요."
  }
  Write-Host "   설치 프로그램 컴파일 실패(코드 $LASTEXITCODE) — 5초 뒤 다시 시도합니다 ($attempt/3)..."
  Start-Sleep -Seconds 5
}

Write-Host "4) 웹 앱 빌드 → server/web/..."
Push-Location $client
flutter build web --release --no-wasm-dry-run
$buildExit = $LASTEXITCODE
Pop-Location
if ($buildExit -ne 0) { throw "웹 빌드 실패(코드 $buildExit)" }
# 서버는 이 폴더를 그대로 내려준다(server/src/config.js의 WEB_DIR) — 재시작 없이 다음 새로고침부터 새 웹 앱이
# 뜬다. 예전 빌드의 파일이 섞이지 않게 비우고 새로 넣는다. 운영 서버에는 package_server_update.ps1이 이
# 폴더째로 실어 보낸다.
$webDir = Join-Path $root "server\web"
if (Test-Path $webDir) { Remove-Item $webDir -Recurse -Force }
Copy-Item "$client\build\web" $webDir -Recurse

Write-Host "5) server/releases/로 복사..."
New-Item -ItemType Directory -Force -Path $releases | Out-Null
Copy-Item "$client\windows\installer\output\messenger-setup.exe" "$releases\client-windows-setup.exe" -Force
Copy-Item "$client\build\app\outputs\flutter-apk\app-release.apk" "$releases\client-android.apk" -Force

$versionInfo = [ordered]@{ version = $Version; notes = $Notes }
$versionJson = $versionInfo | ConvertTo-Json
# Windows PowerShell 5.1의 Set-Content -Encoding utf8은 BOM을 붙여서, 그걸 그대로 읽는
# Node 쪽 JSON.parse가 실패한다 — .NET API로 BOM 없이 직접 써서 피해간다.
[System.IO.File]::WriteAllText("$releases\version.json", $versionJson, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "완료: $releases 에 버전 $Version 배포됨. 서버 재시작 없이 바로 새 버전을 알려줍니다."
