<#
.SYNOPSIS
  "백업" 시작 메뉴 항목 — 관리자 콘솔 "백업" 탭과 같은 전체 백업을 지금 한 번 한다.

.DESCRIPTION
  관리자 콘솔 "백업" 탭에서 백업 암호를 정해 두었으면 server\scripts\backup-now.mjs로 전체 백업(DB·서버 설정·인증서를 백업
  암호로 암호화 — 외부 백업 위치를 정했으면 그곳에 복사하고 첨부파일까지 맞춤)을 한다. 서버도 매일 정한 시각에 같은 백업을
  스스로 하므로 이 메뉴는 "지금 한 번 더"가 필요할 때 쓴다. 백업 암호를 아직 정하지 않았거나 전체 백업이 실패하면 아래 예전
  방식(DB만)으로 백업한다 — 그 설명:

  pg_dump를 직접 콘솔에서 치는 건 경로(전용 설치라 C:\Program Files\PostgreSQL이 아님)·포트
  (전용 포트 55432)·비밀번호(secrets\db-app.pw에 저장돼 있어 따로 기억할 필요 없음)를 전부
  알아야 해서 번거롭다 — 이 스크립트가 전부 대신 채워서 실행한다.

  DB만 백업한다(회원/팀/방/메시지/댓글/설정 등 — 실제 데이터는 전부 여기 들어있다). 업로드된
  첨부파일(server\uploads)과 TLS 인증서(server\certs)는 따로 복사해서 챙겨야 한다(README의
  "서버/DB 백업 · 이전 · 초기화" 참고).

  서버를 멈추지 않고도 안전하게 백업된다(pg_dump는 그 시점의 일관된 스냅샷을 뜬다).

  백업 파일에는 DB 전체(회원 비밀번호 해시, 암호화된 이메일, 초대 토큰 등)가 들어 있어서, backups 폴더를
  SYSTEM/Administrators 전용으로 잠근 뒤에 쓰고(Folder-Acl.ps1), 가장 최근 것 몇 개(아래 $KeepBackups,
  기본 10개)만 남기고 오래된 것은 지운다.
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
# 보관 개수 — 백업을 끝없이 쌓아두면 새어 나갈 거리(오래된 비밀번호 해시·초대 토큰 등)만 늘어난다. 새로
# 만든 것까지 포함해 가장 최근 이만큼만 남긴다. 더 오래 보관할 것은 다른 안전한 곳에 복사해 두고, 개수를
# 바꾸려면 이 값만 고치면 된다. 이 스크립트가 만든 이름(messenger_<날짜>_<시각>.dump)의 파일만 지운다.
$KeepBackups = 10

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
# 백업 파일에는 DB 전체(회원 비밀번호 해시·암호화된 이메일·초대 토큰)가 들어 있어서, 쓰기 "전에" backups
# 폴더를 SYSTEM/Administrators 전용으로 잠근다. 아래 중 하나라도면 백업을 진행하지 않는다 — 덤프가 다른
# 계정에게 그대로 새어 나가기 때문이다(백업이 없는 것보다 "조용히 새는 백업"이 더 나쁘다):
#   - Folder-Acl.ps1이 없다: 이 잠금 기능이 없던 때 설치된 서버다(zip 업데이트로는 안 들어옴) — 최신 설치
#     프로그램을 한 번 실행해야 설치 폴더가 잠기고 이 헬퍼도 들어온다.
#   - backups가 링크(정션/심볼릭 링크)다: 예전 넓은 권한 시절 누군가 {app}\backups를 자기 폴더를 가리키는
#     정션으로 심어 뒀을 수 있다(그러면 덤프가 그 폴더에 써진다).
#   - 폴더를 관리자 전용으로 못 잠근다: 네트워크/FAT/드라이브 최상위 등(Set-AdminOnlyAcl이 예외를 던진다).
# 핵심 잠금은 됐는데 "정리" 단계에서만 경고가 난 경우(폴더는 이미 잠김)에는 경고만 남기고 진행한다.
$AclHelper = Join-Path $AppDir 'Folder-Acl.ps1'
if (-not (Test-Path -LiteralPath $AclHelper)) {
    Write-Host 'Folder-Acl.ps1이 없어 백업 폴더를 관리자 전용으로 잠글 수 없습니다 — 백업에는 모든 데이터가 들어 있어, 안전을 위해 백업하지 않습니다.' -ForegroundColor Red
    Write-Host '최신 서버 설치 프로그램(tangotalk-server-setup.exe)을 한 번 다시 실행한 뒤 백업하세요.' -ForegroundColor Red
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 1
}
. $AclHelper
if (Test-ReparsePoint -Path $BackupsDir) {
    Write-Host "백업 폴더($BackupsDir)가 링크(정션/심볼릭 링크)라 백업 파일이 엉뚱한 폴더에 써질 수 있어, 안전을 위해 백업하지 않습니다." -ForegroundColor Red
    Write-Host '이 링크를 지우거나 서버를 새로 설치한 뒤 다시 시도하세요.' -ForegroundColor Red
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 1
}
try {
    $aclWarnings = @(Set-AdminOnlyAcl -Path $BackupsDir)
} catch {
    Write-Host "백업 폴더를 관리자 전용으로 잠그지 못해, 안전을 위해 백업하지 않습니다 — $($_.Exception.Message)" -ForegroundColor Red
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 1
}
foreach ($warning in $aclWarnings) { Write-Host "경고: $warning" -ForegroundColor Yellow }

# ── 전체 백업(관리자 콘솔 "백업" 탭과 같은 것) ─────────────────────────────
# 관리자 콘솔에서 백업 암호를 정해 두었으면 server\scripts\backup-now.mjs로 DB·서버 설정·인증서를 암호화해 백업하고, 외부 백업
# 위치를 정했으면 그곳에 복사하고 첨부파일까지 맞춘다(server\src\backup.js). 백업 암호를 아직 정하지 않았으면(종료 코드 3) 아래의
# 예전 방식(DB만, 암호화 없음)으로 백업한다. node가 이 창에 바로 쓰게 파이프 없이 부른다(한글이 그대로 보인다).
$ServerDir = Join-Path $AppDir 'server'
$NodeExe = Join-Path $AppDir 'node\node.exe'
$BackupNowScript = Join-Path $ServerDir 'scripts\backup-now.mjs'
if ((Test-Path -LiteralPath $NodeExe) -and (Test-Path -LiteralPath $BackupNowScript)) {
    Write-Host '전체 백업(DB·서버 설정·인증서, 외부 위치를 정했으면 첨부파일까지)을 합니다...'
    Write-Host ''
    Push-Location -LiteralPath $ServerDir
    try {
        $global:LASTEXITCODE = -1
        & $NodeExe $BackupNowScript
        $fullBackupCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    Write-Host ''
    if ($fullBackupCode -eq 0) {
        Write-Host '백업 파일은 백업 암호로 암호화돼 있습니다 — 복원할 때 백업 암호가 필요합니다.' -ForegroundColor Yellow
        Read-Host '엔터를 누르면 창이 닫힙니다'
        exit 0
    }
    if ($fullBackupCode -eq 2) {
        Write-Host '이 PC에는 백업했지만 외부 위치 복사에 실패했습니다 — 외장 드라이브·NAS 연결을 확인하세요.' -ForegroundColor Yellow
        Read-Host '엔터를 누르면 창이 닫힙니다'
        exit 2
    }
    if ($fullBackupCode -eq 4) {
        Read-Host '엔터를 누르면 창이 닫힙니다'
        exit 1
    }
    if ($fullBackupCode -eq 3) {
        Write-Host '관리자 콘솔 "백업" 탭에서 백업 암호를 정하면 매일 자동으로 전체 백업합니다.' -ForegroundColor Yellow
        Write-Host '지금은 예전 방식으로 DB만 백업합니다.' -ForegroundColor Yellow
    } else {
        Write-Host '전체 백업에 실패해 DB만이라도 예전 방식으로 백업합니다.' -ForegroundColor Yellow
    }
    Write-Host ''
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

# ── 오래된 백업 정리 — 방금 만든 것 포함 최근 $KeepBackups개만 남긴다 ───────────
# 이름의 날짜·시각 순으로 정렬한다(파일을 복사·이동하면 바뀌는 수정 시각보다 정확). 방금 만든 파일은 시계가
# 틀어져 이름이 더 옛날로 보여도 절대 지우지 않게 따로 뺀다.
$oldBackups = @(Get-ChildItem -LiteralPath $BackupsDir -File -Filter 'messenger_*.dump' |
        Where-Object { $_.Name -match '^messenger_\d{8}_\d{6}\.dump$' -and $_.Name -ne $fileName } |
        Sort-Object Name -Descending | Select-Object -Skip ([Math]::Max($KeepBackups - 1, 0)))
foreach ($old in $oldBackups) {
    try {
        Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop
        Write-Host "오래된 백업 삭제: $($old.Name)"
    } catch {
        Write-Host "오래된 백업을 지우지 못했습니다($($old.Name)): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
if ($oldBackups.Count -gt 0) { Write-Host '' }

Write-Host "이 폴더에는 가장 최근 백업 ${KeepBackups}개만 남깁니다(더 오래된 것은 다음 백업 때 자동으로 지워짐)." -ForegroundColor Yellow
Write-Host '이 파일 하나를 다른 곳(외장 드라이브, NAS 등)에도 복사해두는 걸 권장합니다 —' -ForegroundColor Yellow
Write-Host '이 PC 자체에 문제가 생기면 이 폴더의 백업도 같이 사라집니다.' -ForegroundColor Yellow
Write-Host '단, 백업에는 회원 비밀번호 해시 등 모든 데이터가 들어 있으니 복사해 둔 곳도 관리자만 열 수 있게 하세요.' -ForegroundColor Yellow
Read-Host '엔터를 누르면 창이 닫힙니다'
