<#
.SYNOPSIS
  새 기기(클라이언트 앱)를 페어링할 때 쓰는 4자리 코드를 발급받는다.

.DESCRIPTION
  서버를 백그라운드 Windows 서비스로 설치한 경우 콘솔 창이 없어서, 기존 방식(서버 콘솔에
  "pair"를 입력)을 쓸 수 없다 — 이 스크립트가 그 대신이다. server/scripts/pair.mjs(npm run pair)와
  똑같이 로컬 전용 페어링 부트스트랩 서버의 POST /admin/generate만 호출한다(server/src/pairing.js
  참고 — 127.0.0.1에서 온 요청만 허용되므로 이 스크립트도 반드시 서버가 설치된 그 PC에서
  실행해야 한다). node/node_modules 없이 동작하도록 순수 PowerShell로 만들었다.

  페어링 포트는 server\.env의 PORT/PAIRING_PORT에서 읽는다. 설치 폴더가 SYSTEM/Administrators 전용으로 잠긴
  뒤로는(Folder-Acl.ps1) 일반 권한으로 .env를 못 읽어서 기본값(3000/3001)으로 조용히 넘어갔고, 포트를 바꾼
  서버에서는 엉뚱한 포트로 요청하다 "코드를 발급받지 못했습니다"만 떴다 — 그래서 다른 관리용 바로가기처럼 스스로
  관리자 권한으로 다시 실행한다. (보안 경계 때문은 아니다 — /admin/generate는 이 PC에서 온 요청이면 받는다.)
#>

# ── 관리자 권한 확인/승격 ───────────────────────────────────────────────
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  try {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -ErrorAction Stop
  } catch {
    # 예전엔 승격 없이 바로 코드가 떴던 바로가기라, 관리자 권한 확인 창에서 "아니요"를 누르면 창만 닫히고 아무 일도
    # 없던 것처럼 보인다 — 왜 안 되는지 알려 준다.
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
      "관리자 권한이 필요합니다 — 서버 포트 설정(.env)이 관리자 전용 설치 폴더 안에 있습니다.`n`n" +
      "다시 실행한 뒤 관리자 권한 확인 창에서 '예'를 누르세요(관리자 계정이 아니면 관리자 계정 암호가 필요합니다).",
      'TangoTalk 서버 - 페어링 코드', 'OK', 'Warning'
    ) | Out-Null
  }
  exit
}

Add-Type -AssemblyName System.Windows.Forms

$ServerDir = Join-Path $PSScriptRoot 'server'
$EnvFile = Join-Path $ServerDir '.env'

# .env가 없으면(설정 전) 서버도 기본값을 쓰므로 기본값이 맞다 — 위에서 관리자 권한으로 바꿨으니 "있는데 못 읽는" 경우는 없다.
function Get-EnvIntValue {
  param([string]$Name, [int]$Default)
  if (-not (Test-Path $EnvFile)) { return $Default }
  $line = Get-Content $EnvFile | Where-Object { $_ -match "^\s*$Name\s*=\s*(\d+)\s*$" } | Select-Object -Last 1
  if ($line -and $line -match "=\s*(\d+)\s*$") { return [int]$Matches[1] }
  return $Default
}

$appPort = Get-EnvIntValue -Name 'PORT' -Default 3000
$pairingPort = Get-EnvIntValue -Name 'PAIRING_PORT' -Default ($appPort + 1)

try {
  $res = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$pairingPort/admin/generate" -TimeoutSec 5
  $seconds = [math]::Round($res.expiresInMs / 1000)
  [System.Windows.Forms.MessageBox]::Show(
    "새 기기 연결 코드: $($res.code)`n`n(유효시간 ${seconds}초, 1회용)`n`n" +
    "클라이언트 앱의 `"서버 주소 변경`" 화면에서 서버 주소와 함께 이 코드를 입력하세요.",
    'TangoTalk 서버 - 페어링 코드', 'OK', 'Information'
  ) | Out-Null
} catch {
  [System.Windows.Forms.MessageBox]::Show(
    "코드를 발급받지 못했습니다. 서버가 실행 중인지 확인하세요.`n`n($($_.Exception.Message))",
    'TangoTalk 서버 - 페어링 코드', 'OK', 'Error'
  ) | Out-Null
}
