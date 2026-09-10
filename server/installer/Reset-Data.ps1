<#
.SYNOPSIS
  DB 데이터 초기화 — 서버 프로그램/설치는 그대로 두고, 회원/팀/메시지/댓글/첨부파일 등
  데이터만 전부 비운다. 되돌릴 수 없습니다.

.DESCRIPTION
  "서버 데이터 완전 삭제"(Uninstall-Full.ps1)는 서버 자체를 지우기 전에(=결국 다시 설치해야
  쓸 수 있는 상태로) 쓰는 것과 달리, 이건 서버는 계속 그대로 쓰되 안의 데이터만 깨끗하게
  비우고 싶을 때 쓴다 — .env/인증서/설치된 프로그램은 안 건드리고, 실행이 끝나면 서버가
  다시 시작되어 바로 쓸 수 있다(처음 가입하는 계정이 새 서버 운영자가 됨).
#>

$AppDir = $PSScriptRoot
$ServerDir = Join-Path $AppDir 'server'
$NssmExe = Join-Path $AppDir 'tools\nssm.exe'
$NodeServiceName = 'TangoTalkServer'
$NodeExe = Join-Path $AppDir 'node\node.exe'

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
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
$plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

$VerifyScript = Join-Path $ServerDir 'scripts\verify-admin.mjs'
$plainPassword | & $NodeExe $VerifyScript $username
$verified = ($LASTEXITCODE -eq 0)
$plainPassword = $null

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
