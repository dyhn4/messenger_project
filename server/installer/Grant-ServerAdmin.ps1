<#
.SYNOPSIS
  서버 운영자 복구 — 서버 운영자 계정이 한 명도 남지 않아(운영자가 탈퇴·정지됐거나 운영자 지정이 모두 해제돼)
  아무도 관리자 콘솔에 들어갈 수 없을 때, 이미 가입한 계정 하나를 서버 운영자로 되돌린다.

.DESCRIPTION
  server\scripts\grant-server-admin.mjs를 이 서버에 함께 설치된 Node로 실행해 주는 창일 뿐이다. 그 스크립트는
  "지금 활성(탈퇴·정지되지 않은) 서버 운영자가 한 명도 없을 때"만 동작한다 — 운영자가 있으면 아무것도 바꾸지 않고
  관리자 콘솔에서 하라고 안내한다(종료 코드 1). 운영자가 없으면 입력한 아이디의 계정(탈퇴하지 않은 계정)을 서버
  운영자로 지정하고 정지돼 있으면 정지도 푼다(종료 코드 0). .env·DB 오류는 종료 코드 2.
  보안 경계는 아니다 — .env(DB 접속 정보)를 읽을 수 있는 이 PC의 관리자는 어차피 DB를 직접 고칠 수 있다. 이건
  "운영자가 멀쩡히 있는 서버의 권한 구성을 실수로 바꾸지 않게" 하는 안전장치와, 운영자를 잃은 서버를 되살리는 길이다.

  .env가 관리자 전용 설치 폴더 안에 있어(Folder-Acl.ps1) 스스로 관리자 권한으로 다시 실행하고, 서버 폴더로 이동한
  뒤 node를 부른다(그 스크립트의 안내대로 — 승격된 PowerShell은 C:\Windows\System32에서 시작한다). 거의 쓸 일이
  없어 시작 메뉴에는 넣지 않았다 — 설치 폴더에서 이 파일을 오른쪽 클릭 → "PowerShell에서 실행"(README-설치후.txt).
#>

# ── 관리자 권한 확인/승격 ───────────────────────────────────────────────
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$AppDir = $PSScriptRoot
$ServerDir = Join-Path $AppDir 'server'
$NodeExe = Join-Path $AppDir 'node\node.exe'
$GrantScript = Join-Path $ServerDir 'scripts\grant-server-admin.mjs'

Write-Host '================================================================'
Write-Host ' TangoTalk 서버 운영자 복구'
Write-Host '================================================================'
Write-Host ''
Write-Host '서버 운영자(관리자 콘솔을 쓸 수 있는 계정)가 한 명도 남지 않아 아무도 운영자로 로그인할 수 없을 때만 씁니다.'
Write-Host '이미 가입한 계정(탈퇴하지 않은 계정) 하나를 서버 운영자로 지정하고, 정지돼 있으면 정지도 풉니다.'
Write-Host '활성 서버 운영자가 한 명이라도 있으면 아무것도 바꾸지 않습니다 — 그때는 그 운영자 계정으로 앱의 관리자 콘솔에서'
Write-Host '운영자를 지정하세요.'
Write-Host ''

if (-not (Test-Path -LiteralPath $NodeExe) -or -not (Test-Path -LiteralPath $GrantScript)) {
    Write-Host "필요한 파일을 찾을 수 없습니다: $NodeExe / $GrantScript" -ForegroundColor Red
    Write-Host '이 서버 버전에는 운영자 복구 기능이 없을 수 있습니다 — 시작 메뉴 "서버 업데이트"로 최신 업데이트 파일을 적용한 뒤' -ForegroundColor Red
    Write-Host '다시 실행하세요.' -ForegroundColor Red
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 2
}

# 아이디는 가입한 그대로(대소문자 포함) 입력받는다 — 대소문자만 다른 계정을 어떻게 찾을지는 그 스크립트가 정한다.
$username = "$(Read-Host '서버 운영자로 지정할 계정의 아이디')".Trim()
if (-not $username) {
    Write-Host '아이디를 입력하지 않아 취소했습니다. 아무것도 바꾸지 않았습니다.'
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 0
}

Write-Host ''
Set-Location -LiteralPath $ServerDir
# node가 아예 실행되지 못하면 $LASTEXITCODE가 예전 값(0일 수도 있음) 그대로 남아 성공처럼 보이므로 먼저 지워 둔다.
$global:LASTEXITCODE = -1
& $NodeExe $GrantScript $username
$exitCode = $LASTEXITCODE

# 자세한 결과(지정한 계정, 거절한 까닭, 할 일)는 위에 그 스크립트가 직접 출력한다 — 여기서는 한 줄로 정리만 한다.
Write-Host ''
if ($exitCode -eq 0) {
    Write-Host '완료되었습니다.' -ForegroundColor Green
} elseif ($exitCode -eq 1) {
    Write-Host '아무것도 바꾸지 않았습니다 — 위 안내를 확인하세요.' -ForegroundColor Yellow
} else {
    Write-Host "오류로 끝났습니다(종료 코드 $exitCode) — 위 메시지를 확인하세요. PostgreSQL 서비스(postgresql-tangotalk)가" -ForegroundColor Red
    Write-Host '실행 중인지도 확인하세요.' -ForegroundColor Red
}
Read-Host '엔터를 누르면 창이 닫힙니다'
exit $exitCode
