<#
.SYNOPSIS
  "서버 콘솔로 실행" 시작 메뉴 항목(콘솔 모드로 설치한 경우) — 관리자 권한으로 승격한 뒤 이 창에서
  서버를 직접 띄운다. 창을 닫으면 서버도 같이 꺼진다.

.DESCRIPTION
  예전 바로가기는 node.exe를 일반 권한으로 바로 실행했는데, 설치 폴더가 SYSTEM/Administrators 전용으로
  잠기면서(Folder-Acl.ps1) 일반 권한으로는 node.exe·서버 코드·.env를 읽을 수 없다 — 그래서 다른 관리용
  바로가기처럼 스스로 관리자 권한으로 다시 실행한다(서비스 모드의 서버도 LocalSystem으로 돌므로 권한
  수준은 서비스 모드와 같다). 서버는 .env를 "현재 폴더"에서 읽으므로(dotenv/config) 서버 폴더로 이동한 뒤
  실행한다 — 승격된 PowerShell은 C:\Windows\System32에서 시작한다.
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

$Host.UI.RawUI.WindowTitle = 'TangoTalk 서버(콘솔) — 이 창을 닫으면 서버가 꺼집니다'
Set-Location -LiteralPath $ServerDir
# 서비스 모드(Setup-TangoTalkServer.ps1의 Set-NodeServiceProductionEnv)와 똑같이 운영 모드로 띄운다 — Express는 NODE_ENV가
# production이 아니면 처리하지 못한 오류의 응답에 스택 트레이스(서버의 절대 경로)를 그대로 싣는다. 서버 하나만 띄우는 이
# 창의 환경 변수라 다른 프로그램에는 영향이 없다(npm install을 돌리는 창이었다면 devDependencies가 빠져 안 됐다).
$env:NODE_ENV = 'production'
& $NodeExe (Join-Path $ServerDir 'src\index.js')
$exitCode = $LASTEXITCODE

# 서버가 오류로 바로 꺼졌을 때 창이 그대로 닫혀버리면 원인을 볼 수 없으므로 기다린다.
Write-Host ''
Write-Host "서버가 종료됐습니다(종료 코드 $exitCode)." -ForegroundColor Yellow
Read-Host '엔터를 누르면 창이 닫힙니다'
