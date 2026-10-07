<#
.SYNOPSIS
  "복원" 시작 메뉴 항목 — "백업"(Backup-Data.ps1)이 만든 .dump 파일로 DB를 되돌린다.
  지금 DB에 있는 내용은 전부 그 백업 시점 내용으로 덮어써진다. 되돌릴 수 없습니다.

.DESCRIPTION
  Backup-Data.ps1과 마찬가지로 pg_restore 경로·포트·비밀번호를 전부 대신 채워서 실행한다.
  DB 데이터 초기화(Reset-Data.ps1)만큼 위험한 작업이라 같은 방식으로 안전장치를 둔다 —
  서버 운영자 계정 본인 확인 + "RESTORE" 입력 확인.
#>

# ── 관리자 권한 확인/승격 ───────────────────────────────────────────────
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$AppDir = $PSScriptRoot
$ServerDir = Join-Path $AppDir 'server'
$PgBin = Join-Path $AppDir 'pgsql\bin'
$SecretsDir = Join-Path $AppDir 'secrets'
$BackupsDir = Join-Path $AppDir 'backups'
$NssmExe = Join-Path $AppDir 'tools\nssm.exe'
$NodeExe = Join-Path $AppDir 'node\node.exe'
$NodeServiceName = 'TangoTalkServer'
$PgPort = 55432
$DbName = 'messenger'
$DbAppUser = 'messenger_app'

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

# node는 서버 폴더에서 실행한다 — verify-admin.mjs는 자기 위치 기준으로 .env를 읽지만, .env를 "현재 폴더"에서 읽는
# 서버 스크립트(reset-data.mjs 등 dotenv/config)와 같은 규칙으로 맞춰 둔다(승격된 PowerShell은 System32에서 시작한다).
Set-Location -LiteralPath $ServerDir

Write-Host '================================================================'
Write-Host ' TangoTalk DB 복원'
Write-Host '================================================================'
Write-Host ''

$pgRestore = Join-Path $PgBin 'pg_restore.exe'
if (-not (Test-Path $pgRestore)) {
    Write-Host "pg_restore.exe를 찾을 수 없습니다($pgRestore) — 서버가 정상 설치됐는지 확인하세요." -ForegroundColor Red
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 1
}

$pwFile = Join-Path $SecretsDir 'db-app.pw'
if (-not (Test-Path $pwFile)) {
    Write-Host "DB 비밀번호 파일을 찾을 수 없습니다($pwFile) — 서버가 정상 설치됐는지 확인하세요." -ForegroundColor Red
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 1
}

# ── 복원할 백업 파일 선택 ────────────────────────────────────────────────
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = '복원할 백업 파일(.dump) 선택'
$dialog.Filter = '백업 파일 (*.dump)|*.dump|모든 파일 (*.*)|*.*'
$dialog.InitialDirectory = if (Test-Path $BackupsDir) { $BackupsDir } else { $AppDir }
if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host '취소되었습니다.'
    exit 0
}
$dumpPath = $dialog.FileName

Write-Host "선택한 파일: $dumpPath"
Write-Host ''
Write-Host "지금 DB에 있는 회원/팀/대화방/메시지 등 모든 내용이 위 백업 시점 내용으로" -ForegroundColor Yellow
Write-Host "완전히 덮어써집니다 — 되돌릴 수 없습니다." -ForegroundColor Yellow
Write-Host ''

# "DB 데이터 초기화"와 같은 이유로 — 이 PC 앞에 앉을 수 있다는 것만으로 복원할 수 있으면
# 안 되므로, 실제 서버 운영자 계정으로 먼저 본인 확인을 한다.
Write-Host '먼저 서버 운영자 계정으로 본인 확인이 필요합니다.'
$username = Read-Host '서버 운영자 아이디'
$securePassword = Read-Host '비밀번호' -AsSecureString
$verified = Test-ServerAdminPassword -NodeExe $NodeExe -ServerDir $ServerDir -Username $username -Password $securePassword
$securePassword.Dispose()

if (-not $verified) {
    Write-Host ''
    Write-Host '서버 운영자 인증에 실패했습니다. 복원을 진행하지 않습니다.' -ForegroundColor Red
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 1
}
Write-Host '운영자 확인 완료.' -ForegroundColor Green
Write-Host ''

$confirm = Read-Host '계속하려면 정확히 RESTORE 를 입력하세요'
if ($confirm -cne 'RESTORE') {
    Write-Host '취소되었습니다. 아무 것도 바꾸지 않았습니다.'
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 0
}

$dbPassword = (Get-Content $pwFile -Raw).Trim()

Write-Host ''
Write-Host '복원을 진행합니다...'

# 복원 도중 서버가 DB에 계속 쓰면 안 되므로 잠깐 멈춘다.
if (Test-Path $NssmExe) {
    & $NssmExe stop $NodeServiceName 2>$null | Out-Null
}

$env:PGPASSWORD = $dbPassword
try {
    $args = @('-h', 'localhost', '-p', $PgPort, '-U', $DbAppUser, '-d', $DbName, '--clean', '--if-exists', $dumpPath)
    $out = & $pgRestore @args 2>&1
    $ok = ($LASTEXITCODE -eq 0)
} finally {
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    $dbPassword = $null
}

if (Test-Path $NssmExe) {
    & $NssmExe start $NodeServiceName 2>$null | Out-Null
}

if (-not $ok) {
    Write-Host ''
    Write-Host '복원 중 오류가 발생했습니다:' -ForegroundColor Red
    Write-Host ($out | Out-String)
    Write-Host '서버는 다시 시작했지만 DB 내용이 일부만 반영됐을 수 있습니다 — 필요하면 다시' -ForegroundColor Yellow
    Write-Host '백업 파일로 복원을 시도하거나 DB 데이터 초기화 후 재시도하세요.' -ForegroundColor Yellow
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 1
}

Write-Host ''
Write-Host '완료되었습니다 — 서버가 다시 시작됐습니다.' -ForegroundColor Green
Read-Host '엔터를 누르면 창이 닫힙니다'
