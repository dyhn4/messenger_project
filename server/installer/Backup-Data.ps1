<#
.SYNOPSIS
  "백업" 시작 메뉴 항목 — DB(회원/팀/메시지 등 모든 데이터)를 파일 하나로 저장한다.

.DESCRIPTION
  pg_dump를 직접 콘솔에서 치는 건 경로(전용 설치라 C:\Program Files\PostgreSQL이 아님)·포트
  (전용 포트 55432)·비밀번호(secrets\db-app.pw에 저장돼 있어 따로 기억할 필요 없음)를 전부
  알아야 해서 번거롭다 — 이 스크립트가 전부 대신 채워서 실행한다.

  DB만 백업한다(회원/팀/방/메시지/댓글/설정 등 — 실제 데이터는 전부 여기 들어있다). 업로드된
  첨부파일(server\uploads)과 TLS 인증서(server\certs)는 따로 복사해서 챙겨야 한다(README의
  "서버/DB 백업 · 이전 · 초기화" 참고).

  서버를 멈추지 않고도 안전하게 백업된다(pg_dump는 그 시점의 일관된 스냅샷을 뜬다).
#>

# ── 관리자 권한 확인/승격 ───────────────────────────────────────────────
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$AppDir = $PSScriptRoot
$PgBin = Join-Path $AppDir 'pgsql\bin'
$SecretsDir = Join-Path $AppDir 'secrets'
$BackupsDir = Join-Path $AppDir 'backups'
$PgPort = 55432
$DbName = 'messenger'
$DbAppUser = 'messenger_app'

Write-Host '================================================================'
Write-Host ' TangoTalk DB 백업'
Write-Host '================================================================'
Write-Host ''

$pgDump = Join-Path $PgBin 'pg_dump.exe'
if (-not (Test-Path $pgDump)) {
    Write-Host "pg_dump.exe를 찾을 수 없습니다($pgDump) — 서버가 정상 설치됐는지 확인하세요." -ForegroundColor Red
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 1
}

$pwFile = Join-Path $SecretsDir 'db-app.pw'
if (-not (Test-Path $pwFile)) {
    Write-Host "DB 비밀번호 파일을 찾을 수 없습니다($pwFile) — 서버가 정상 설치됐는지 확인하세요." -ForegroundColor Red
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 1
}
$dbPassword = (Get-Content $pwFile -Raw).Trim()

if (-not (Test-Path $BackupsDir)) {
    New-Item -ItemType Directory -Path $BackupsDir -Force | Out-Null
}

$fileName = "messenger_{0}.dump" -f (Get-Date -Format 'yyyyMMdd_HHmmss')
$outPath = Join-Path $BackupsDir $fileName

Write-Host "백업 파일을 만드는 중... ($outPath)"
Write-Host ''

$env:PGPASSWORD = $dbPassword
try {
    $args = @('-h', 'localhost', '-p', $PgPort, '-U', $DbAppUser, '-d', $DbName, '-F', 'c', '-f', $outPath)
    $out = & $pgDump @args 2>&1
    $ok = ($LASTEXITCODE -eq 0)
} finally {
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    $dbPassword = $null
}

if (-not $ok) {
    Write-Host '백업 중 오류가 발생했습니다:' -ForegroundColor Red
    Write-Host ($out | Out-String)
    Remove-Item $outPath -ErrorAction SilentlyContinue
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 1
}

$sizeMb = [Math]::Round((Get-Item $outPath).Length / 1MB, 1)
Write-Host "완료되었습니다 — ${sizeMb}MB" -ForegroundColor Green
Write-Host "저장 위치: $outPath"
Write-Host ''
Write-Host '이 파일 하나를 다른 곳(외장 드라이브, NAS 등)에도 복사해두는 걸 권장합니다 —' -ForegroundColor Yellow
Write-Host '이 PC 자체에 문제가 생기면 이 폴더의 백업도 같이 사라집니다.' -ForegroundColor Yellow
Read-Host '엔터를 누르면 창이 닫힙니다'
