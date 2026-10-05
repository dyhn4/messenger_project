# 서버+PostgreSQL을 새 "서비스 PC"에 한 번에 설치하는 Windows 설치 프로그램을 만든다.
# 사용법: 저장소 루트에서 .\build_server_installer.ps1
# publish_release.ps1(클라이언트 설치 프로그램 빌드)과 같은 구조 — 자세한 설계는
# server/installer/README.md 참고.
#
# 하는 일:
#   1) Node.js 포터블 런타임 / PostgreSQL 설치 프로그램 / nssm.exe를 server/installer/bin/에
#      받아둔다(이미 있으면 다시 받지 않음).
#   2) server/를 정리해서(.env·certs·uploads·로그·firebase-service-account.json 등 실데이터/
#      비밀값 전부 제외) server/installer/stage/에 복사하고, 그 안에서 npm install(전체 —
#      drizzle-kit이 devDependency지만 설치 시점 마이그레이션 실행에 실제로 필요하다).
#      앱의 "도움말"이 여는 초보자용 안내 웹페이지(server/guide/)도 여기서 같이 담긴다.
#   3) 저장소 루트 README.md를 server/installer/README.html로 변환한다(설치된 서버의
#      "메신저 설명서" 바로가기가 보여줌 — build-readme-html.mjs 참고).
#   4) ISCC.exe로 messenger-server.iss를 컴파일해서 server/installer/output/에 exe를 만든다.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest 진행률 표시를 끄면 훨씬 빠르다.

# ── 버전 고정(나중에 올릴 때는 이 값들만 바꾸면 됨) ─────────────────────────
$NodeVersion = '24.21.0'
$NodeZipUrl = "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-win-x64.zip"
$PgVersion = '17.11-1'
$PgInstallerUrl = "https://get.enterprisedb.com/postgresql/postgresql-$PgVersion-windows-x64.exe"
$NssmVersion = '2.24'
$NssmZipUrl = "https://nssm.cc/release/nssm-$NssmVersion.zip"
# 화상회의(SFU). Go 단일 실행 파일이라 Node/PostgreSQL처럼 그냥 같이 넣어두면 된다.
$LiveKitVersion = '1.13.7'
$LiveKitZipUrl = "https://github.com/livekit/livekit/releases/download/v$LiveKitVersion/livekit_${LiveKitVersion}_windows_amd64.zip"

$Root = $PSScriptRoot
$Server = Join-Path $Root 'server'
$Installer = Join-Path $Server 'installer'
$Bin = Join-Path $Installer 'bin'
$Stage = Join-Path $Installer 'stage'

New-Item -ItemType Directory -Force -Path $Bin | Out-Null

# bin/에 받아둔 파일이 위에 고정한 버전과 같은지 — 같으면 다시 안 받는다. 버전 값을 올렸는데
# 예전에 받아둔 파일이 남아 있으면 옛 버전이 그대로 설치 파일에 들어가므로, 받을 때마다
# bin/<이름>.version에 버전을 적어두고 다르면 새로 받는다(이 기록이 없던 예전 캐시도 새로 받음).
function Test-CachedVersion([string]$Name, [string]$Version, [string]$Path) {
  $stamp = Join-Path $Bin "$Name.version"
  return (Test-Path $Path) -and (Test-Path $stamp) -and ((Get-Content $stamp -Raw).Trim() -eq $Version)
}
function Set-CachedVersion([string]$Name, [string]$Version) {
  Set-Content -Path (Join-Path $Bin "$Name.version") -Value $Version -Encoding ascii
}

# ── 1) Node.js 포터블 런타임 ────────────────────────────────────────────
$nodeDestDir = Join-Path $Bin 'node'
if (-not (Test-CachedVersion 'node' $NodeVersion (Join-Path $nodeDestDir 'node.exe'))) {
  Write-Host "1) Node.js v$NodeVersion 다운로드 중..."
  $nodeZip = Join-Path $Bin 'node.zip'
  Invoke-WebRequest -Uri $NodeZipUrl -OutFile $nodeZip
  $nodeExtractTmp = Join-Path $Bin 'node-extract-tmp'
  Remove-Item $nodeExtractTmp -Recurse -Force -ErrorAction SilentlyContinue
  Expand-Archive -Path $nodeZip -DestinationPath $nodeExtractTmp
  Remove-Item $nodeDestDir -Recurse -Force -ErrorAction SilentlyContinue
  Move-Item (Join-Path $nodeExtractTmp "node-v$NodeVersion-win-x64") $nodeDestDir
  Remove-Item $nodeExtractTmp -Recurse -Force
  Remove-Item $nodeZip -Force
  Set-CachedVersion 'node' $NodeVersion
} else {
  Write-Host '1) Node.js 이미 준비됨 — 건너뜀'
}

# ── 2) PostgreSQL 설치 프로그램 ─────────────────────────────────────────
$pgInstallerExe = Join-Path $Bin 'pgsql-installer.exe'
if (-not (Test-CachedVersion 'pgsql' $PgVersion $pgInstallerExe)) {
  Write-Host "2) PostgreSQL $PgVersion 설치 프로그램 다운로드 중(용량이 커서 시간이 걸릴 수 있습니다)..."
  Invoke-WebRequest -Uri $PgInstallerUrl -OutFile $pgInstallerExe
  Set-CachedVersion 'pgsql' $PgVersion
} else {
  Write-Host '2) PostgreSQL 설치 프로그램 이미 준비됨 — 건너뜀'
}

# ── 3) nssm.exe ──────────────────────────────────────────────────────────
$nssmExe = Join-Path $Bin 'nssm.exe'
if (-not (Test-Path $nssmExe)) {
  Write-Host "3) nssm $NssmVersion 다운로드 중..."
  $nssmZip = Join-Path $Bin 'nssm.zip'
  Invoke-WebRequest -Uri $NssmZipUrl -OutFile $nssmZip
  $nssmExtractTmp = Join-Path $Bin 'nssm-extract-tmp'
  Remove-Item $nssmExtractTmp -Recurse -Force -ErrorAction SilentlyContinue
  Expand-Archive -Path $nssmZip -DestinationPath $nssmExtractTmp
  Copy-Item (Join-Path $nssmExtractTmp "nssm-$NssmVersion\win64\nssm.exe") $nssmExe
  Remove-Item $nssmExtractTmp -Recurse -Force
  Remove-Item $nssmZip -Force
} else {
  Write-Host '3) nssm.exe 이미 준비됨 — 건너뜀'
}

# ── 3.5) LiveKit 서버(화상회의 SFU) ─────────────────────────────────────
$liveKitDir = Join-Path $Bin 'livekit'
if (-not (Test-CachedVersion 'livekit' $LiveKitVersion (Join-Path $liveKitDir 'livekit-server.exe'))) {
  Write-Host "3.5) LiveKit $LiveKitVersion 다운로드 중..."
  New-Item -ItemType Directory -Force -Path $liveKitDir | Out-Null
  $lkZip = Join-Path $Bin 'livekit.zip'
  Invoke-WebRequest -Uri $LiveKitZipUrl -OutFile $lkZip
  Expand-Archive -Path $lkZip -DestinationPath $liveKitDir -Force
  Remove-Item $lkZip -Force
  Set-CachedVersion 'livekit' $LiveKitVersion
} else {
  Write-Host '3.5) LiveKit 이미 준비됨 — 건너뜀'
}

# ── 4) server/ 스테이징(실데이터/비밀값 제외) + npm install ────────────
Write-Host '4) server/ 소스 정리 중...'
Remove-Item $Stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Stage | Out-Null

# robocopy가 제외 목록 처리가 더 안정적이라 Copy-Item 대신 쓴다(exit code 1/2/3은 성공으로 취급 —
# robocopy는 실패가 아니어도 0이 아닌 코드를 돌려준다).
$robocopyArgs = @(
  $Server, $Stage, '/E',
  '/XD', 'node_modules', 'certs', 'uploads', 'releases', 'installer', '.livekit',
  '/XF', '.env', '*.log', '.jwt-secret', '.db-encryption-key', '.web-push-vapid.json', '.livekit-secret', 'firebase-service-account.json', 'db.json.bak', 'ecosystem.config.cjs',
  '/NFL', '/NDL', '/NJH', '/NJS'
)
robocopy @robocopyArgs | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy 실패(코드 $LASTEXITCODE)" }
# 초보자용 도움말(server/guide/)이 빠진 채로 설치되면 모든 회원이 빈 페이지를 보게 되므로,
# 위 제외 목록을 고치다 실수로 빠지는 일이 없게 확인한다.
if (-not (Test-Path (Join-Path $Stage 'guide\index.html'))) { throw 'server/guide/index.html이 스테이징에 없습니다(초보자용 도움말).' }

Write-Host '   npm install 실행 중(devDependencies 포함 — drizzle-kit이 마이그레이션에 필요)...'
Push-Location $Stage
try {
  npm install --no-audit --no-fund
  if ($LASTEXITCODE -ne 0) { throw 'npm install 실패' }
} finally {
  Pop-Location
}

# ── 5) 메신저 설명서(README.html) 생성 ───────────────────────────────────
# 저장소 루트 README.md(전체 프로젝트 문서, 목차 포함)를 정적 HTML로 변환해서 설치된 서버의
# "메신저 설명서" 바로가기(와 앱의 관리자용 "메신저 설명서" 메뉴 — version.js의 GET /help)가
# 기본 브라우저로 보여줄 수 있게 한다 — build-readme-html.mjs는 이 파일들에서 실제 쓰는
# 마크다운 구성만 처리하는 작은 자체 변환기다(별도 npm 의존성 없음).
Write-Host '5) 메신저 설명서(README.html) 만드는 중...'
$readmeHtml = Join-Path $Installer 'README.html'
$converter = Join-Path $Installer 'build-readme-html.mjs'
& (Join-Path $nodeDestDir 'node.exe') $converter (Join-Path $Root 'README.md') $readmeHtml
if ($LASTEXITCODE -ne 0) { throw 'README.html 생성 실패' }

# ── 6) Inno Setup 컴파일 ─────────────────────────────────────────────────
Write-Host '6) 설치 프로그램 컴파일 중...'
$iscc = Get-ChildItem "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" -ErrorAction SilentlyContinue
if (-not $iscc) { $iscc = Get-ChildItem "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" -ErrorAction SilentlyContinue }
if (-not $iscc) { throw "ISCC.exe를 찾을 수 없습니다. Inno Setup이 설치되어 있는지 확인하세요 (winget install JRSoftware.InnoSetup)." }
# 막 만든 설치 파일에 아이콘·버전 정보를 써 넣는 순간 백신(Windows Defender 실시간 검사)이 그
# 파일을 잠가 두면 "EndUpdateResource failed ... (110)"로 가끔 실패한다 — 세 번까지 다시 해 본다.
for ($attempt = 1; $attempt -le 3; $attempt++) {
  & $iscc.FullName (Join-Path $Installer 'messenger-server.iss')
  if ($LASTEXITCODE -eq 0) { break }
  if ($attempt -eq 3) {
    throw "Inno Setup 컴파일이 3번 모두 실패했습니다(코드 $LASTEXITCODE). 백신이 server\installer\output 폴더를 잠그는 것이면 그 폴더를 검사 제외에 넣고 다시 실행하세요."
  }
  Write-Host "   컴파일 실패(코드 $LASTEXITCODE) — 5초 뒤 다시 시도합니다 ($attempt/3)..."
  Start-Sleep -Seconds 5
}

Write-Host ''
Write-Host "완료: $Installer\output\tangotalk-server-setup.exe"
Write-Host '이 파일은 server/releases/(클라이언트 자동 업데이트 채널)와는 무관합니다 — 새 서비스 PC에'
Write-Host 'USB/사내 공유 폴더 등으로 직접 전달해서 실행하세요.'
