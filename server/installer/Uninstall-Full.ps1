<#
.SYNOPSIS
  TangoTalk 서버의 데이터베이스/업로드 파일/설정을 완전히 삭제한다. 되돌릴 수 없습니다.

.DESCRIPTION
  일반 "프로그램 제거"(제어판/시작 메뉴의 "TangoTalk 서버 제거")는 프로그램 파일만 지우고 이
  데이터들은 그대로 남겨둔다 — 이 스크립트는 그것과 완전히 분리된, 오직 시작 메뉴의
  "서버 데이터 완전 삭제" 항목으로만 실행되는 별도 절차다. 아래 확인 문구를 정확히 입력해야만
  실제로 삭제가 진행된다.
#>

$AppDir = $PSScriptRoot
$ServerDir = Join-Path $AppDir 'server'
$PgDir = Join-Path $AppDir 'pgsql'
$PgDataDir = Join-Path $AppDir 'pgsql-data'
$SecretsDir = Join-Path $AppDir 'secrets'
$NssmExe = Join-Path $AppDir 'tools\nssm.exe'
$PgServiceName = 'postgresql-tangotalk'
$NodeServiceName = 'TangoTalkServer'

Write-Host '================================================================'
Write-Host ' TangoTalk 서버 데이터 완전 삭제'
Write-Host '================================================================'
Write-Host ''
Write-Host '아래 항목이 전부 영구히 삭제됩니다 — 되돌릴 수 없습니다:'
Write-Host "  - 데이터베이스(PostgreSQL 데이터 폴더: $PgDataDir)"
Write-Host "  - 업로드된 첨부파일: $ServerDir\uploads"
Write-Host "  - TLS 인증서: $ServerDir\certs"
Write-Host "  - 서버 설정(.env)과 자동 생성된 비밀값(JWT/암호화 키, DB 비밀번호)"
Write-Host ''
Write-Host '프로그램 파일 자체는 지워지지 않습니다 — 그건 "TangoTalk 서버 제거"로 따로 진행하세요.'
Write-Host ''
$confirm = Read-Host '계속하려면 정확히 DELETE 를 입력하세요'
if ($confirm -cne 'DELETE') {
  Write-Host '취소되었습니다. 아무 것도 삭제하지 않았습니다.'
  Read-Host '엔터를 누르면 창이 닫힙니다'
  exit 0
}

Write-Host ''
Write-Host '삭제를 진행합니다...'

# 서비스 정지
if (Test-Path $NssmExe) {
  & $NssmExe stop $NodeServiceName 2>$null | Out-Null
}
$pgSvc = Get-Service -Name $PgServiceName -ErrorAction SilentlyContinue
if ($pgSvc) {
  Stop-Service -Name $PgServiceName -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2

# 데이터 삭제
foreach ($path in @($PgDataDir, (Join-Path $ServerDir 'uploads'), (Join-Path $ServerDir 'certs'),
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
Write-Host '완료되었습니다. PostgreSQL 자체(프로그램 파일, pgsql\ 폴더)는 남아있습니다 — 필요하면'
Write-Host '"TangoTalk 서버 제거"로 프로그램 파일까지 마저 지우세요.'
Read-Host '엔터를 누르면 창이 닫힙니다'
