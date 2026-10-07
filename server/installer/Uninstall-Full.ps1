<#
.SYNOPSIS
  서버 완전 삭제(PostgreSQL·Node 앱·DB 데이터 모두) — 이 PC에서 서버를 통째로 걷어낸다.
  되돌릴 수 없습니다.

.DESCRIPTION
  이 스크립트 하나로 PostgreSQL 자체(프로그램+서비스 등록), DB 데이터/업로드 파일/설정,
  그리고 Node 앱 프로그램 파일까지 전부 제거한다 — 시작 메뉴의
  "서버 완전 삭제(PostgreSQL·Node 앱·DB 데이터 모두)" 항목으로만 실행되는 별도 절차다.
  아래 확인 문구를 정확히 입력해야만 실제로 삭제가 진행된다.

  PostgreSQL을 프로그램 파일만 남겨두고 서비스만 정지시키면, 나중에 이 PC에 PostgreSQL을
  다시 설치할 때 그 설치 프로그램이 "이미 설치되어 있다"고 인식해서 새로 지정한 경로/서비스
  이름을 무시하고 예전 것을 그대로 재사용해버리는 문제가 있다 — 그래서 이 스크립트는
  `uninstall-postgresql.exe`로 PostgreSQL 자체도 정식으로 제거한다.

  마지막 단계로 일반 "TangoTalk 서버 제거"(Inno Setup 생성 제거 프로그램, unins000.exe)를
  무인 모드(/VERYSILENT)로 실행해서 Node 앱 프로그램 파일까지 마저 지운다 — 그래서 이
  스크립트가 끝나면 더 이상 따로 "TangoTalk 서버 제거"를 실행할 필요가 없다. NSSM 서비스
  정지/PostgreSQL 제거/제거 프로그램 실행 전부 관리자 권한이 필요해서, 관리자가 아니면
  스스로 관리자 권한으로 다시 실행한다.
#>

# ── 관리자 권한 확인/승격 ───────────────────────────────────────────────
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  exit
}

$AppDir = $PSScriptRoot
$ServerDir = Join-Path $AppDir 'server'
$PgDir = Join-Path $AppDir 'pgsql'
$PgDataDir = Join-Path $AppDir 'pgsql-data'
$SecretsDir = Join-Path $AppDir 'secrets'
$NssmExe = Join-Path $AppDir 'tools\nssm.exe'
$PgUninstallExe = Join-Path $PgDir 'uninstall-postgresql.exe'
$PgServiceName = 'postgresql-tangotalk'
$NodeServiceName = 'TangoTalkServer'

# 서버 운영자 아이디/비밀번호 확인(server\scripts\verify-admin.mjs) — 맞으면 $true. Reset-Data.ps1·Restore-Data.ps1·
# Uninstall-Full.ps1에 똑같이 들어 있다 — 고치면 셋 다 고치고 tests\Admin-Verify.Tests.ps1을 돌릴 것(셋이 같은지도 본다).
# - 비밀번호는 stdin(파이프)으로만 넘긴다 — 명령줄 인자는 이 PC의 다른 계정도 프로세스 목록에서 볼 수 있고, 환경 변수나
#   파일로 넘기면 흔적이 남는다.
# - Windows PowerShell 5.1은 파이프로 외부 프로그램에 넘기는 글자를 $OutputEncoding(기본값 ASCII)으로 바꿔 한글 등 ASCII
#   밖의 글자를 전부 '?'로 보낸다 — 그런 글자가 든 비밀번호는 맞게 쳐도 늘 실패했다. 그래서 이 함수 안에서만 BOM 없는
#   UTF-8로 바꾼다(verify-admin.mjs가 UTF-8로 읽는다). New-Object로 만들면 PSObject로 감싸여, 함수 안 지역 변수에서는
#   인코딩으로 인식되지 않고 조용히 ASCII로 돌아간다(직접 확인) — 그래서 ::new()로 만든다.
# - node는 서버 폴더에서 실행하고(다른 관리 스크립트와 같은 규칙) 끝나면 원래 위치로 돌아온다 — 뒤에서 띄우는 프로그램이
#   지울 대상인 server 폴더를 작업 폴더로 물려받지 않게(Uninstall-Full.ps1).
function Test-ServerAdminPassword {
  param([string]$NodeExe, [string]$ServerDir, [string]$Username, [securestring]$Password)
  $ok = $false
  $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
  try {
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
  $previousOutputEncoding = $OutputEncoding
  Push-Location -LiteralPath $ServerDir
  try {
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    # node가 아예 실행되지 못하면 $LASTEXITCODE가 예전 값(0일 수도 있음) 그대로 남아 통과처럼 보이므로 먼저 지워 둔다.
    $global:LASTEXITCODE = -1
    # node가 stdout에 무엇을 쓰든 이 함수의 결과($true/$false)에 섞이지 않게 화면으로만 보낸다.
    $plainPassword | & $NodeExe (Join-Path $ServerDir 'scripts\verify-admin.mjs') $Username | Out-Host
    $ok = ($LASTEXITCODE -eq 0)
  } catch {
    Write-Host "운영자 확인을 실행하지 못했습니다: $($_.Exception.Message)" -ForegroundColor Red
    $ok = $false
  } finally {
    $OutputEncoding = $previousOutputEncoding
    $plainPassword = $null
    Pop-Location
  }
  return $ok
}

Write-Host '================================================================'
Write-Host ' TangoTalk 서버 완전 삭제 (PostgreSQL·Node 앱·DB 데이터 모두)'
Write-Host '================================================================'
Write-Host ''
Write-Host '아래 항목이 전부 영구히 삭제됩니다 — 되돌릴 수 없습니다:'
Write-Host "  - PostgreSQL 자체(프로그램, 서비스 등록) 및 데이터베이스 폴더: $PgDataDir"
Write-Host "  - 업로드된 첨부파일: $ServerDir\uploads"
Write-Host "  - TLS 인증서: $ServerDir\certs"
Write-Host "  - 서버 설정(.env)과 자동 생성된 비밀값(JWT/암호화 키, DB 비밀번호)"
Write-Host "  - Node 앱 프로그램 파일 전체(마지막 단계에서 일반 제거 프로그램을 자동 실행)"
Write-Host ''
# 백업은 일부러 지우지 않는다(되돌릴 수 없는 삭제 뒤에도 마지막 기회로 남겨 둔다) — 그래서 설치 폴더 자체는 남는다.
# 같은 경로에 다시 설치하면 설치 프로그램이 이 폴더를 그대로 받아 준다(messenger-server.iss의 PrepareToInstall).
# 다만 DB 암호화 키(.db-encryption-key)는 위 목록대로 지워지므로, 그 키 없이 백업을 복원하면 암호화된 이메일 등을
# 읽을 수 없다(루트 README "다른 PC에서 새로 클론했을 때 — git에는 없는 파일들" 표와 같은 이유) — 지우기 전에 알려 준다.
Write-Host "남는 것: 백업 파일($AppDir\backups)·로그와 server 폴더의 일부 설정 파일(.livekit-secret, .web-push-vapid.json, 직접 넣은"
Write-Host '         firebase-service-account.json) — 필요 없으면 끝난 뒤 직접 지우세요(관리자 권한 필요). 특히 Firebase 키 파일은'
Write-Host '         더 쓰지 않으면 지우세요.'
Write-Host "나중에 그 백업을 복원할 생각이면, 계속하기 전에 $ServerDir\.db-encryption-key 를 안전한 곳에 복사해 두세요" -ForegroundColor Yellow
Write-Host '— 이 키가 없으면 백업 속 암호화된 이메일 등을 읽을 수 없습니다.' -ForegroundColor Yellow
Write-Host ''

# 이 PC 앞에 앉을 수 있다고 해서 누구나 지울 수 있으면 안 되므로, 실제 서버 운영자
# (is_server_admin=true) 계정의 아이디/비밀번호를 먼저 확인한다 — 확인 문구만 입력하면
# 되는 건 그 다음 단계일 뿐이다(scripts/verify-admin.mjs 참고).
Write-Host '먼저 서버 운영자 계정으로 본인 확인이 필요합니다.'
$username = Read-Host '서버 운영자 아이디'
$securePassword = Read-Host '비밀번호' -AsSecureString

$NodeExe = Join-Path $AppDir 'node\node.exe'
# Test-ServerAdminPassword는 서버 폴더에서 node를 돌리고(다른 관리 스크립트와 같은 규칙) 끝나면 바로 원래 위치로
# 돌아온다 — 아래에서 띄우는 PostgreSQL 제거·일반 제거 프로그램은 PowerShell의 현재 위치를 작업 폴더로 물려받는데,
# 그게 지울 대상인 server 폴더면 그 폴더를 붙잡고 있게 된다.
$verified = Test-ServerAdminPassword -NodeExe $NodeExe -ServerDir $ServerDir -Username $username -Password $securePassword
$securePassword.Dispose()

if (-not $verified) {
  Write-Host ''
  Write-Host '서버 운영자 인증에 실패했습니다. 삭제를 진행하지 않습니다.' -ForegroundColor Red
  Read-Host '엔터를 누르면 창이 닫힙니다'
  exit 1
}
Write-Host '운영자 확인 완료.' -ForegroundColor Green
Write-Host ''

$confirm = Read-Host '계속하려면 정확히 DELETE 를 입력하세요'
if ($confirm -cne 'DELETE') {
  Write-Host '취소되었습니다. 아무 것도 삭제하지 않았습니다.'
  Read-Host '엔터를 누르면 창이 닫힙니다'
  exit 0
}

Write-Host ''
Write-Host '삭제를 진행합니다...'

# Node 앱 서비스 정지
if (Test-Path $NssmExe) {
  & $NssmExe stop $NodeServiceName 2>$null | Out-Null
}

# PostgreSQL 정식 제거 — 서비스만 세워두고 프로그램 파일을 남겨두면, 나중에 같은 PC에
# PostgreSQL을 다시 설치할 때 설치 프로그램이 "이미 설치돼 있다"고 인식해서 새로 지정한
# 경로/서비스 이름을 무시하고 이 예전 설치를 그대로 재사용해버리는 문제가 생긴다 — 그래서
# uninstall-postgresql.exe로 확실하게 제거한다(서비스 등록 해제까지 포함됨).
if (Test-Path $PgUninstallExe) {
  Write-Host 'PostgreSQL 제거 중...'
  $p = Start-Process -FilePath $PgUninstallExe -ArgumentList @('--mode', 'unattended') -Wait -PassThru
  if ($p.ExitCode -ne 0) {
    Write-Host "PostgreSQL 제거 프로그램이 오류 코드 $($p.ExitCode)로 종료됐습니다 — 계속 진행합니다." -ForegroundColor Yellow
  } else {
    Write-Host '  PostgreSQL 제거 완료'
  }
} else {
  # 제거 프로그램이 이미 없다면(예: 수동으로 지운 경우) 서비스만이라도 정지한다.
  $pgSvc = Get-Service -Name $PgServiceName -ErrorAction SilentlyContinue
  if ($pgSvc) {
    Stop-Service -Name $PgServiceName -Force -ErrorAction SilentlyContinue
  }
}
Start-Sleep -Seconds 2

# 데이터 삭제 — uninstall-postgresql.exe가 데이터 폴더까지 지웠을 수도, 안 지웠을 수도
# 있으므로(버전마다 다름) 남아있으면 여기서 마저 지운다.
foreach ($path in @($PgDir, $PgDataDir, (Join-Path $ServerDir 'uploads'), (Join-Path $ServerDir 'certs'),
    (Join-Path $ServerDir '.env'), (Join-Path $ServerDir '.jwt-secret'),
    (Join-Path $ServerDir '.db-encryption-key'), $SecretsDir)) {
  if (Test-Path $path) {
    Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "삭제됨: $path"
  }
}

# 방화벽 규칙 정리
netsh advfirewall firewall delete rule name="TangoTalk Server (main)" | Out-Null
netsh advfirewall firewall delete rule name="TangoTalk Server (pairing)" | Out-Null

Write-Host ''
Write-Host '완료되었습니다 — PostgreSQL과 DB 데이터가 모두 제거됐습니다.' -ForegroundColor Green

# 마지막으로 일반 제거 프로그램(Inno Setup이 만든 unins000.exe)을 무인 모드로 실행해서
# Node 앱 프로그램 파일까지 마저 지운다. -Wait를 안 쓰는 이유: 이 스크립트 자신도
# {app} 안에 설치된 파일이라 제거 대상이라서, 여기서 기다리는 대신 바로 종료해 파일이
# 사용 중인 상태로 남지 않게 한다 — 제거 자체는 독립된 프로세스로 계속 진행된다.
$UninstallExe = Join-Path $AppDir 'unins000.exe'
if (Test-Path $UninstallExe) {
  Write-Host 'Node 앱 프로그램도 마저 제거합니다(백그라운드에서 계속 진행됨)...' -ForegroundColor Green
  Start-Process -FilePath $UninstallExe -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') | Out-Null
  Start-Sleep -Seconds 3
  Write-Host "잠시 후 프로그램 파일이 지워집니다(백업 파일($AppDir\backups)·로그 등은 남습니다). 이 창은 닫으셔도 됩니다." -ForegroundColor Green
} else {
  Write-Host "제거 프로그램(${UninstallExe})을 찾을 수 없어 Node 앱 프로그램 파일은 남아있습니다 — 필요하면 수동으로 지우세요." -ForegroundColor Yellow
  Read-Host '엔터를 누르면 창이 닫힙니다'
}
