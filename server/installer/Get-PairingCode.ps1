<#
.SYNOPSIS
  새 기기(클라이언트 앱)를 페어링할 때 쓰는 4자리 코드를 발급받는다.

.DESCRIPTION
  서버를 백그라운드 Windows 서비스로 설치한 경우 콘솔 창이 없어서, 기존 방식(서버 콘솔에
  "pair"를 입력)을 쓸 수 없다 — 이 스크립트가 그 대신이다. server/scripts/pair.mjs(npm run pair)와
  똑같이 로컬 전용 페어링 부트스트랩 서버의 POST /admin/generate만 호출한다(server/src/pairing.js
  참고 — 127.0.0.1에서 온 요청만 허용되므로 이 스크립트도 반드시 서버가 설치된 그 PC에서
  실행해야 한다). node/node_modules 없이 동작하도록 순수 PowerShell로 만들었다.
#>

Add-Type -AssemblyName System.Windows.Forms

$ServerDir = Join-Path $PSScriptRoot 'server'
$EnvFile = Join-Path $ServerDir '.env'

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
    'TeamTalk 서버 - 페어링 코드', 'OK', 'Information'
  ) | Out-Null
} catch {
  [System.Windows.Forms.MessageBox]::Show(
    "코드를 발급받지 못했습니다. 서버가 실행 중인지 확인하세요.`n`n($($_.Exception.Message))",
    'TeamTalk 서버 - 페어링 코드', 'OK', 'Error'
  ) | Out-Null
}
