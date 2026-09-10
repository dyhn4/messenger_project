<#
.SYNOPSIS
  서버 삭제(PostgreSQL과 DB 데이터 포함) — PostgreSQL 자체(프로그램+서비스 등록)와 DB
  데이터/업로드 파일/설정을 전부 삭제한다. 되돌릴 수 없습니다.

.DESCRIPTION
  일반 "프로그램 제거"(제어판/시작 메뉴의 "TangoTalk 서버 제거")는 Node 앱 프로그램 파일만
  지우고 PostgreSQL과 데이터는 그대로 남겨둔다 — 이 스크립트는 그것과 완전히 분리된, 오직
  시작 메뉴의 "서버 삭제(PostgreSQL과 DB 데이터 포함)" 항목으로만 실행되는 별도 절차다.
  아래 확인 문구를 정확히 입력해야만 실제로 삭제가 진행된다.

  PostgreSQL을 프로그램 파일만 남겨두고 서비스만 정지시키면, 나중에 이 PC에 PostgreSQL을
  다시 설치할 때 그 설치 프로그램이 "이미 설치되어 있다"고 인식해서 새로 지정한 경로/서비스
  이름을 무시하고 예전 것을 그대로 재사용해버리는 문제가 있다 — 그래서 이 스크립트는
  `uninstall-postgresql.exe`로 PostgreSQL 자체도 정식으로 제거한다(Node 앱 프로그램 파일은
  여전히 안 건드림 — 그건 "TangoTalk 서버 제거"로 따로 진행).
#>

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
Write-Host ' TangoTalk 서버 삭제 (PostgreSQL과 DB 데이터 포함)'
Write-Host '================================================================'
Write-Host ''
Write-Host '아래 항목이 전부 영구히 삭제됩니다 — 되돌릴 수 없습니다:'
Write-Host "  - PostgreSQL 자체(프로그램, 서비스 등록) 및 데이터베이스 폴더: $PgDataDir"
Write-Host "  - 업로드된 첨부파일: $ServerDir\uploads"
Write-Host "  - TLS 인증서: $ServerDir\certs"
Write-Host "  - 서버 설정(.env)과 자동 생성된 비밀값(JWT/암호화 키, DB 비밀번호)"
Write-Host ''
Write-Host 'Node 앱 프로그램 파일 자체는 지워지지 않습니다 — 그건 "TangoTalk 서버 제거"로 따로 진행하세요.'
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
Write-Host '완료되었습니다 — PostgreSQL과 DB 데이터가 모두 제거됐습니다. Node 앱 프로그램 파일은' -ForegroundColor Green
Write-Host '남아있습니다 — 필요하면 "TangoTalk 서버 제거"로 마저 지우세요.' -ForegroundColor Green
Read-Host '엔터를 누르면 창이 닫힙니다'
