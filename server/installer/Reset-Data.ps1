<#
.SYNOPSIS
  DB 데이터 초기화 — 서버 프로그램/설치는 그대로 두고, 회원/팀/메시지/댓글/첨부파일 등
  데이터만 전부 비운다. 되돌릴 수 없습니다.

.DESCRIPTION
  "서버 데이터 완전 삭제"(Uninstall-Full.ps1)는 서버 자체를 지우기 전에(=결국 다시 설치해야
  쓸 수 있는 상태로) 쓰는 것과 달리, 이건 서버는 계속 그대로 쓰되 안의 데이터만 깨끗하게
  비우고 싶을 때 쓴다 — .env/인증서/설치된 프로그램은 안 건드리고, 실행이 끝나면 서버가
  다시 시작되어 바로 쓸 수 있다(처음 가입하는 계정이 새 서버 운영자가 됨).

  설치 폴더가 SYSTEM/Administrators 전용으로 잠겨 있어(Folder-Acl.ps1) 일반 권한으로는 node.exe·서버 스크립트·
  .env를 읽지도, 서비스를 멈추지도, 첨부파일을 지우지도 못한다 — 그래서 다른 관리용 바로가기처럼 스스로 관리자
  권한으로 다시 실행한다. 또 reset-data.mjs는 .env를 "현재 폴더"에서 읽으므로(dotenv/config) 서버 폴더로 이동한
  뒤 node를 부른다 — 승격된 PowerShell은 C:\Windows\System32에서 시작한다.
#>

# ── 관리자 권한 확인/승격 ───────────────────────────────────────────────
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$AppDir = $PSScriptRoot
$ServerDir = Join-Path $AppDir 'server'
$NssmExe = Join-Path $AppDir 'tools\nssm.exe'
$NodeServiceName = 'TangoTalkServer'
$NodeExe = Join-Path $AppDir 'node\node.exe'

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

# 아래 node 스크립트들이 서버 폴더의 .env를 읽도록(reset-data.mjs는 현재 폴더 기준) 서버 폴더에서 실행한다.
Set-Location -LiteralPath $ServerDir

Write-Host '================================================================'
Write-Host ' TangoTalk DB 데이터 초기화'
Write-Host '================================================================'
Write-Host ''
Write-Host '서버 프로그램/설치는 그대로 두고, 아래 데이터가 전부 영구히 삭제됩니다 — 되돌릴 수 없습니다:'
Write-Host '  - 모든 회원 계정, 팀, 대화방, 메시지, 댓글'
Write-Host '  - 업로드된 첨부파일'
Write-Host '  - 초대 링크, 감사 로그, 서버 설정값'
Write-Host ''
Write-Host '서버 설정(.env), 인증서, 설치된 프로그램은 그대로 남습니다 — 초기화가 끝나면 서버가'
Write-Host '다시 시작되어 바로 쓸 수 있고, 처음 가입하는 계정이 새 서버 운영자가 됩니다.'
Write-Host ''

# "서버 데이터 완전 삭제"와 같은 이유로 — 이 PC 앞에 앉을 수 있다는 것만으로 지울 수 있으면
# 안 되므로, 실제 서버 운영자 계정으로 먼저 본인 확인을 한다.
Write-Host '먼저 서버 운영자 계정으로 본인 확인이 필요합니다.'
$username = Read-Host '서버 운영자 아이디'
$securePassword = Read-Host '비밀번호' -AsSecureString
$verified = Test-ServerAdminPassword -NodeExe $NodeExe -ServerDir $ServerDir -Username $username -Password $securePassword
$securePassword.Dispose()

if (-not $verified) {
    Write-Host ''
    Write-Host '서버 운영자 인증에 실패했습니다. 초기화를 진행하지 않습니다.' -ForegroundColor Red
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 1
}
Write-Host '운영자 확인 완료.' -ForegroundColor Green
Write-Host ''

$confirm = Read-Host '계속하려면 정확히 RESET 을 입력하세요'
if ($confirm -cne 'RESET') {
    Write-Host '취소되었습니다. 아무 것도 삭제하지 않았습니다.'
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 0
}

Write-Host ''
Write-Host '초기화를 진행합니다...'

# 진행 중 소켓/연결이 어중간한 상태로 남지 않도록 서버 앱만 잠깐 멈춘다
# (Postgres는 초기화 SQL을 실행해야 하므로 그대로 둔다).
if (Test-Path $NssmExe) {
    & $NssmExe stop $NodeServiceName 2>$null | Out-Null
}

$ResetScript = Join-Path $ServerDir 'scripts\reset-data.mjs'
& $NodeExe $ResetScript
$resetOk = ($LASTEXITCODE -eq 0)

if (-not $resetOk) {
    Write-Host ''
    Write-Host 'DB 초기화 중 오류가 발생했습니다. 서버를 다시 시작한 뒤 로그를 확인하세요.' -ForegroundColor Red
    if (Test-Path $NssmExe) { & $NssmExe start $NodeServiceName 2>$null | Out-Null }
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 1
}

$uploadsDir = Join-Path $ServerDir 'uploads'
if (Test-Path $uploadsDir) {
    Get-ChildItem $uploadsDir -Force | Where-Object { $_.Name -ne '.gitkeep' } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '업로드 파일 삭제됨.'
}

if (Test-Path $NssmExe) {
    & $NssmExe start $NodeServiceName 2>$null | Out-Null
}

Write-Host ''
Write-Host '완료되었습니다 — 서버가 다시 시작됐습니다. 처음 가입하는 계정이 새 서버 운영자가 됩니다.' -ForegroundColor Green
Read-Host '엔터를 누르면 창이 닫힙니다'
