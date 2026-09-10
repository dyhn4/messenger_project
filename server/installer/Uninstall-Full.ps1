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

# 이 PC 앞에 앉을 수 있다고 해서 누구나 지울 수 있으면 안 되므로, 실제 서버 운영자
# (is_server_admin=true) 계정의 아이디/비밀번호를 먼저 확인한다 — 확인 문구만 입력하면
# 되는 건 그 다음 단계일 뿐이다(scripts/verify-admin.mjs 참고).
Write-Host '먼저 서버 운영자 계정으로 본인 확인이 필요합니다.'
$username = Read-Host '서버 운영자 아이디'
$securePassword = Read-Host '비밀번호' -AsSecureString
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
$plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

$NodeExe = Join-Path $AppDir 'node\node.exe'
$VerifyScript = Join-Path $ServerDir 'scripts\verify-admin.mjs'
$plainPassword | & $NodeExe $VerifyScript $username
$verified = ($LASTEXITCODE -eq 0)
$plainPassword = $null

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
  Write-Host '잠시 후 이 폴더가 사라집니다. 이 창은 닫으셔도 됩니다.' -ForegroundColor Green
} else {
  Write-Host "제거 프로그램(${UninstallExe})을 찾을 수 없어 Node 앱 프로그램 파일은 남아있습니다 — 필요하면 수동으로 지우세요." -ForegroundColor Yellow
  Read-Host '엔터를 누르면 창이 닫힙니다'
}
