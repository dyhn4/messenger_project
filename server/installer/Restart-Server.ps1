<#
.SYNOPSIS
  "서버 재시작" 시작 메뉴 항목 — TangoTalkServer(Node) 서비스만 다시 시작한다. 코드/DB는
  전혀 건드리지 않는다(코드 갱신은 "서버 업데이트"=Update-Server.ps1이 따로 한다).

.DESCRIPTION
  .env를 손으로 고쳤거나, 서버가 이상하게 응답할 때 빠르게 다시 띄우는 용도. NSSM 서비스
  재시작에는 관리자 권한이 필요해서, Update-Server.ps1과 동일하게 관리자가 아니면 스스로
  관리자 권한으로 다시 실행한다.
#>

# ── 관리자 권한 확인/승격 ───────────────────────────────────────────────
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$AppDir = $PSScriptRoot
$NssmExe = Join-Path $AppDir 'tools\nssm.exe'
$NodeServiceName = 'TangoTalkServer'

Write-Host '================================================================'
Write-Host ' TangoTalk 서버 재시작'
Write-Host '================================================================'
Write-Host ''

$svc = Get-Service -Name $NodeServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host "서비스($NodeServiceName)를 찾을 수 없습니다." -ForegroundColor Yellow
    Write-Host '콘솔 모드("서버 콘솔로 실행")로 띄운 서버는 이 바로가기로 재시작할 수 없습니다 —' -ForegroundColor Yellow
    Write-Host '그 콘솔 창을 직접 닫았다가 다시 여세요.' -ForegroundColor Yellow
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 1
}

Write-Host "서비스($NodeServiceName)를 재시작하는 중..."
& $NssmExe restart $NodeServiceName | Out-Null
Start-Sleep -Seconds 2
$svc.Refresh()

if ($svc.Status -eq 'Running') {
    Write-Host '재시작 완료 — 서버가 실행 중입니다.' -ForegroundColor Green
} else {
    Write-Host "재시작 후 서비스 상태: $($svc.Status)" -ForegroundColor Yellow
    Write-Host "정상이 아니면 서버 폴더의 service-err.log를 확인하세요." -ForegroundColor Yellow
}

Write-Host ''
Read-Host '엔터를 누르면 창이 닫힙니다'
