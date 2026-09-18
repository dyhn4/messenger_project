<#
.SYNOPSIS
  TangoTalk 서버 설치 프로그램의 실제 작업 — messenger-server.iss의 [Run]에서 설치 마지막 단계로
  실행된다. PostgreSQL 무인 설치, 앱 전용 DB 계정/데이터베이스 생성, .env 작성, 마이그레이션
  적용, 방화벽 규칙 추가, 서버 실행 방식(백그라운드 서비스/콘솔) 등록까지 전부 처리한다.

.DESCRIPTION
  모든 단계가 "지금 상태를 먼저 확인하고, 이미 되어 있으면 건너뛴다"는 원칙으로 되어 있다 —
  그래서 새 설치든, 새 버전 설치 프로그램을 같은 PC에 다시 실행하는 업그레이드든 안전하게 같은
  스크립트로 처리된다(비밀번호/데이터베이스를 다시 만들거나 덮어쓰지 않는다).

  PostgreSQL은 그 PC의 기본 설치 경로(C:\Program Files\PostgreSQL\...)나 기본 포트(5432)를 쓰지
  않고, 이 앱 전용 경로(--prefix)와 전용 포트에 설치한다 — 그 PC에 이미 다른 PostgreSQL이
  깔려 있어도(버전이 다르거나, 우리가 설치한 게 아니라서 관리자 비밀번호를 모르는 경우) 절대
  충돌하지 않게 하기 위함이다. "이미 설치된 PostgreSQL을 재사용할지" 문제 자체를 우회한다.

  실패해도 이 스크립트는 나중에 그대로 다시 실행할 수 있다(관리자 권한 PowerShell에서
  `Setup-TangoTalkServer.ps1 -RunMode service -AppDir C:\TangoTalk-Server -PgInstallerPath <설치
  프로그램 exe 경로>`) — 이미 끝난 단계는 자동으로 건너뛴다.
#>

param(
  [Parameter(Mandatory = $true)][ValidateSet('service', 'console')][string]$RunMode,
  [Parameter(Mandatory = $true)][string]$AppDir,
  [string]$PgInstallerPath
)

$ErrorActionPreference = 'Stop'

# ── 상수 ──────────────────────────────────────────────────────────────────
$PgPort = 55432
$PgServiceName = 'postgresql-tangotalk'
$NodeServiceName = 'TangoTalkServer'
$DbName = 'messenger'
$DbAppUser = 'messenger_app'
$PgSuperUser = 'postgres'

$LiveKitServiceName = 'TangoTalkLiveKit'
# 화상회의 포트 — server/src/config.js의 LIVEKIT_PORT 기본값(7880)과 맞춰야 한다.
$LiveKitPort = 7880
$LiveKitTcpPort = 7881
$LiveKitTurnPort = 3478

$NodeExe = Join-Path $AppDir 'node\node.exe'
$NssmExe = Join-Path $AppDir 'tools\nssm.exe'
$LiveKitDir = Join-Path $AppDir 'livekit'
$LiveKitExe = Join-Path $LiveKitDir 'livekit-server.exe'
$LiveKitConfig = Join-Path $LiveKitDir 'livekit.yaml'
$ServerDir = Join-Path $AppDir 'server'
$PgDir = Join-Path $AppDir 'pgsql'
$PgDataDir = Join-Path $AppDir 'pgsql-data'
$PgBin = Join-Path $PgDir 'bin'
$SecretsDir = Join-Path $AppDir 'secrets'
$EnvFile = Join-Path $ServerDir '.env'
$LogFile = Join-Path $AppDir 'install.log'

function Write-Log {
  param([string]$Message)
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Write-Host $line
  Add-Content -Path $LogFile -Value $line -Encoding utf8
}

function Fail {
  param([string]$Message)
  Write-Log "오류: $Message"
  # 콘솔이 안 보이는 상태(Inno의 runhidden)로 실행 중이므로, 설치하는 사람이 실패를 놓치지
  # 않도록 메시지 박스도 띄운다.
  Add-Type -AssemblyName System.Windows.Forms
  [System.Windows.Forms.MessageBox]::Show(
    "서버 설치 중 문제가 발생했습니다:`n`n$Message`n`n자세한 내용은 $LogFile 를 확인하세요. " +
    "이 창을 닫은 뒤 관리자 권한 PowerShell에서 이 스크립트를 다시 실행하면 이어서 진행됩니다.",
    'TangoTalk 서버 설치', 'OK', 'Error'
  ) | Out-Null
  exit 1
}

function New-RandomPassword {
  # SQL 문자열에 안전하게 그대로 넣을 수 있도록 영숫자만 쓴다(따옴표 이스케이프 불필요).
  $chars = (48..57) + (65..90) + (97..122)
  -join ((1..24) | ForEach-Object { [char]($chars | Get-Random) })
}

function Get-OrCreateSecret {
  param([string]$FileName)
  $path = Join-Path $SecretsDir $FileName
  if (Test-Path $path) {
    return (Get-Content $path -Raw).Trim()
  }
  if (-not (Test-Path $SecretsDir)) {
    New-Item -ItemType Directory -Path $SecretsDir -Force | Out-Null
  }
  $value = New-RandomPassword
  Set-Content -Path $path -Value $value -NoNewline -Encoding ascii
  # 관리자(SYSTEM/Administrators)만 읽을 수 있게 ACL을 좁힌다 — server/src/config.js의
  # resolveSecret이 .jwt-secret 등을 0o600으로 저장하는 것과 같은 취지를 Windows 방식으로.
  icacls $path /inheritance:r /grant:r 'SYSTEM:(R)' 'Administrators:(R)' | Out-Null
  return $value
}

function Invoke-Psql {
  param([string]$Sql, [string]$SuperPassword, [switch]$ScalarOut)
  $env:PGPASSWORD = $SuperPassword
  try {
    $psql = Join-Path $PgBin 'psql.exe'
    $args = @('-h', 'localhost', '-p', $PgPort, '-U', $PgSuperUser, '-d', 'postgres', '-v', 'ON_ERROR_STOP=1')
    if ($ScalarOut) { $args += @('-tAc', $Sql) } else { $args += @('-c', $Sql) }
    $out = & $psql @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "psql 실패: $out" }
    return ($out | Out-String).Trim()
  } finally {
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
  }
}

function Test-PortFree {
  param([int]$Port)
  $inUse = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  return (-not $inUse)
}

# 본문 전체를 try/catch로 감싼다 — 이 안 어디서든(Fail을 명시적으로 부르지 않은 예상 밖 오류
# 포함) 예외가 나면 여기서 잡아서 반드시 로그+오류 창으로 남긴다. 이게 없으면(예전 버전)
# $ErrorActionPreference='Stop' 때문에 예상 못 한 오류가 스크립트를 그냥 조용히 죽여버리고
# (runhidden이라 콘솔도 안 보임) install.log에도 흔적이 안 남는다 — 5~7단계(마이그레이션/
# 방화벽/서비스 재시작)가 실제로는 한 번도 안 됐는데 설치 프로그램은 "성공"으로 끝나버리는
# 사고가 실제로 있었다.
try {

# ── 0. 준비 ──────────────────────────────────────────────────────────────
if (-not (Test-Path $AppDir)) { Fail "설치 경로($AppDir)를 찾을 수 없습니다." }
Write-Log "=== TangoTalk 서버 설정 시작 (RunMode=$RunMode) ==="

# ── 1. 비밀값(DB 비밀번호) 확인/생성 — 이미 있으면 재사용, 없으면 새로 생성 ──────
$superPw = Get-OrCreateSecret -FileName 'db-superuser.pw'
$appPw = Get-OrCreateSecret -FileName 'db-app.pw'
Write-Log '1/7 DB 비밀번호 준비 완료'

# ── 2. PostgreSQL 설치(전용 prefix+포트) ────────────────────────────────
$pgAlreadyInstalled = Test-Path (Join-Path $PgBin 'pg_ctl.exe')
if ($pgAlreadyInstalled) {
  Write-Log '2/7 PostgreSQL 이미 설치되어 있음 — 건너뜀'
  $svc = Get-Service -Name $PgServiceName -ErrorAction SilentlyContinue
  if ($svc -and $svc.Status -ne 'Running') {
    Start-Service -Name $PgServiceName
    Write-Log "  서비스($PgServiceName)가 꺼져 있어 시작했습니다."
  }
} else {
  if (-not $PgInstallerPath -or -not (Test-Path $PgInstallerPath)) {
    Fail "PostgreSQL 설치 프로그램을 찾을 수 없습니다: $PgInstallerPath"
  }
  if (-not (Test-PortFree -Port $PgPort)) {
    Fail ("포트 {0}을(를) 이미 다른 프로그램이 사용 중입니다. 그 프로그램을 확인하거나 " +
      "이 스크립트의 `$PgPort 값을 바꿔서 다시 시도하세요. (이 PC의 다른 PostgreSQL을 " +
      "자동으로 재사용하지 않습니다 — 관리자 비밀번호를 알 수 없기 때문입니다.)" -f $PgPort)
  }
  Write-Log '2/7 PostgreSQL 무인 설치 시작...'
  # Start-Process -ArgumentList는 배열 원소를 그냥 공백으로 이어붙일 뿐 따옴표를 붙여주지
  # 않는다 — 그래서 경로에 공백이 있으면(설치 경로를 사용자가 고를 수 있게 되면서 생긴
  # 가능성) 인자가 둘로 쪼개져 설치가 깨진다. 공백이 있을 수 있는 값만 직접 따옴표로 감싼다.
  $pgArgs = @(
    '--mode', 'unattended', '--unattendedmodeui', 'none',
    '--superpassword', $superPw,
    '--serverport', $PgPort,
    '--prefix', "`"$PgDir`"",
    '--datadir', "`"$PgDataDir`"",
    '--servicename', $PgServiceName,
    # pgAdmin4(GUI 관리 도구)는 헤드리스 서버 운영에 필요 없어서 stackbuilder와 함께 끈다 —
    # 설치 용량/시간이 줄고, pgAdmin4가 번들하는 대용량 Python 런타임이 "재시작이 필요합니다"
    # 프롬프트의 원인 중 하나로 보여서 이것도 겸사겸사 줄인다.
    '--disable-components', 'pgAdmin,stackbuilder'
  )
  $p = Start-Process -FilePath $PgInstallerPath -ArgumentList $pgArgs -Wait -PassThru
  if ($p.ExitCode -ne 0) { Fail "PostgreSQL 설치 프로그램이 오류 코드 $($p.ExitCode)로 종료됐습니다." }
  if (-not (Test-Path (Join-Path $PgBin 'pg_ctl.exe'))) { Fail 'PostgreSQL 설치가 끝났지만 pg_ctl.exe를 찾을 수 없습니다.' }
  Write-Log '  PostgreSQL 설치 완료'
}

# 설치 프로그램이 서비스를 시작해두긴 하지만, 접속을 바로 받을 준비가 될 때까지 약간의 지연이
# 있을 수 있어서 첫 psql 호출 전에 짧게 재시도한다.
$pgIsReady = Join-Path $PgBin 'pg_isready.exe'
$ready = $false
for ($i = 0; $i -lt 15; $i++) {
  & $pgIsReady -h localhost -p $PgPort -U $PgSuperUser 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { $ready = $true; break }
  Start-Sleep -Seconds 2
}
if (-not $ready) { Fail "PostgreSQL이 $PgPort 포트에서 응답하지 않습니다(30초 대기함)." }

# ── 3. 앱 전용 DB 역할/데이터베이스 생성(없을 때만) ─────────────────────
Write-Log '3/7 DB 역할/데이터베이스 확인 중...'
$roleExists = Invoke-Psql -SuperPassword $superPw -ScalarOut -Sql "SELECT 1 FROM pg_roles WHERE rolname='$DbAppUser'"
if ($roleExists -ne '1') {
  Invoke-Psql -SuperPassword $superPw -Sql "CREATE ROLE $DbAppUser LOGIN PASSWORD '$appPw'" | Out-Null
  Write-Log "  역할 생성됨: $DbAppUser"
} else {
  Write-Log "  역할 이미 존재: $DbAppUser (건너뜀)"
}
$dbExists = Invoke-Psql -SuperPassword $superPw -ScalarOut -Sql "SELECT 1 FROM pg_database WHERE datname='$DbName'"
if ($dbExists -ne '1') {
  Invoke-Psql -SuperPassword $superPw -Sql "CREATE DATABASE $DbName OWNER $DbAppUser" | Out-Null
  Write-Log "  데이터베이스 생성됨: $DbName"
} else {
  Write-Log "  데이터베이스 이미 존재: $DbName (건너뜀)"
}

# ── 4. .env 작성(없을 때만 — 이미 있으면 관리자가 손댔을 수 있으니 보존) ──
if (-not (Test-Path $EnvFile)) {
  $databaseUrl = "postgres://${DbAppUser}:${appPw}@localhost:${PgPort}/${DbName}"
  @(
    "# Setup-TangoTalkServer.ps1이 설치 시점에 자동으로 만들었습니다."
    "DATABASE_URL=$databaseUrl"
    ""
    "# JWT_SECRET / DB_ENCRYPTION_KEY는 일부러 비워둡니다 — 서버가 첫 실행 때 알아서 안전한"
    "# 값을 만들어 .jwt-secret / .db-encryption-key 파일에 저장하고 계속 재사용합니다."
    "# (server/src/config.js의 resolveSecret 참고)"
  ) -join "`r`n" | Set-Content -Path $EnvFile -Encoding utf8
  Write-Log '4/7 .env 새로 작성함'
} else {
  Write-Log '4/7 .env 이미 존재 — 그대로 둠'
}
# .env는 DB 비밀번호(DATABASE_URL)를 평문으로 담고 있어 secrets\db-app.pw와 똑같이 민감한데,
# Get-OrCreateSecret과 달리 지금까지 ACL을 안 좁혀서 이 PC의 아무 로그인 계정이나 메모장으로
# 열어볼 수 있었다 — 새로 만든 경우든(위) 이미 있던 경우든(재설치) 항상 적용해서, 예전에
# 만들어진 .env도 이 스크립트를 다시 돌리면 뒤늦게라도 잠기게 한다.
icacls $EnvFile /inheritance:r /grant:r 'SYSTEM:(R)' 'Administrators:(R)' | Out-Null
# server/src/config.js의 resolveSecret이 fs.writeFileSync(..., { mode: 0o600 })으로 만드는
# .jwt-secret/.db-encryption-key도 같은 문제다 — 0o600은 POSIX 권한 비트라 Windows NTFS에서는
# 실제로 아무것도 제한하지 않는다. 이 두 파일은 서버가 처음 실행될 때 생기므로 최초 설치
# 시점엔 아직 없을 수 있지만(다음 재실행 때 이 블록이 마저 잠근다), 업데이트 재설치라면
# 이미 있을 것이다.
foreach ($secretName in @('.jwt-secret', '.db-encryption-key')) {
  $secretPath = Join-Path $ServerDir $secretName
  if (Test-Path $secretPath) {
    icacls $secretPath /inheritance:r /grant:r 'SYSTEM:(R)' 'Administrators:(R)' | Out-Null
  }
}
Write-Log '  비밀값 파일 접근 권한을 관리자 전용으로 좁혔습니다(.env 포함)'

# ── 4.5 화상회의(LiveKit) 설정 ───────────────────────────────────────────
# Node 서버와 LiveKit이 **같은 API 비밀값**을 알아야 한다: 서버는 그 값으로 참가 토큰을
# 서명하고, LiveKit은 그 서명을 검증한다. 서버 쪽은 server/.livekit-secret 파일을 읽으므로
# (src/config.js의 optionalSecret) 여기서 그 파일을 만들고, 같은 값을 livekit.yaml에 넣는다.
# 파일이 이미 있으면(업데이트 재설치) 그대로 재사용한다 — 새로 만들면 기존 클라이언트가
# 받아둔 토큰/설정과 어긋난다.
$liveKitSecretFile = Join-Path $ServerDir '.livekit-secret'
if (-not (Test-Path $liveKitSecretFile)) {
  $bytes = New-Object byte[] 32
  # RandomNumberGenerator.Fill(Span<byte>)는 .NET Core/5+ 전용 API라 Windows PowerShell 5.1
  # (전체 .NET Framework 위에서 돈다)에서는 "메서드가 없다"는 예외로 죽는다 — 이 스크립트가
  # 2026-09-16/17 운영PC 재설치에서 정확히 이 줄에서 조용히(콘솔이 안 보이는 상태라) 멈춰서
  # 5~7단계(마이그레이션/방화벽/서비스 재시작)가 실제로 한 번도 안 된 원인이었다. .NET
  # Framework 2.0부터 있는 Create()+GetBytes()로 바꿔서 어느 PowerShell에서도 동작하게 한다.
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $rng.GetBytes($bytes)
  } finally {
    $rng.Dispose()
  }
  $liveKitSecret = -join ($bytes | ForEach-Object { $_.ToString('x2') })
  # 줄바꿈 없이 써야 한다 — 서버가 trim해서 읽지만 yaml 쪽과 한 글자라도 달라지면 인증이 깨진다.
  [System.IO.File]::WriteAllText($liveKitSecretFile, $liveKitSecret)
  Write-Log '4.5/7 LiveKit API 비밀값 새로 생성함'
} else {
  $liveKitSecret = (Get-Content $liveKitSecretFile -Raw).Trim()
  Write-Log '4.5/7 LiveKit API 비밀값 이미 존재 — 재사용'
}

if (-not (Test-Path $LiveKitConfig)) {
  # 사내망 서버라 공인 IP 탐색(use_external_ip)은 끈다 — 켜두면 STUN으로 바깥 IP를 찾으려다
  # 인터넷이 없는 환경에서 시작이 느려지고 엉뚱한 후보를 광고한다.
  # 내장 TURN(UDP)은 켜둔다: 방화벽이 빡빡한 사내망에서 UDP 직결이 막혀도 중계로 붙는다.
  @(
    '# TangoTalk 설치 프로그램이 자동 생성했습니다.'
    "port: $LiveKitPort"
    'rtc:'
    '  port_range_start: 50000'
    '  port_range_end: 60000'
    "  tcp_port: $LiveKitTcpPort"
    '  use_external_ip: false'
    'turn:'
    '  enabled: true'
    "  udp_port: $LiveKitTurnPort"
    'keys:'
    "  tangotalk: $liveKitSecret"
  ) -join "`r`n" | Set-Content -Path $LiveKitConfig -Encoding utf8
  Write-Log '  livekit.yaml 새로 작성함'
} else {
  Write-Log '  livekit.yaml 이미 존재 — 그대로 둠(관리자가 포트 등을 바꿨을 수 있음)'
}

# ── 5. 마이그레이션 적용 ─────────────────────────────────────────────────
Write-Log '5/7 데이터베이스 마이그레이션 적용 중...'
$drizzleKitCli = Join-Path $ServerDir 'node_modules\drizzle-kit\bin.cjs'
if (-not (Test-Path $drizzleKitCli)) { Fail "drizzle-kit을 찾을 수 없습니다: $drizzleKitCli (설치 스테이징이 잘못됐을 수 있습니다)" }
Push-Location $ServerDir
try {
  # drizzle.config.js가 dotenv/config로 이 폴더의 .env를 직접 읽으므로 별도로 DATABASE_URL을
  # 환경변수로 넘길 필요가 없다 — 작업 디렉터리만 맞으면 된다.
  & $NodeExe $drizzleKitCli 'migrate' 2>&1 | ForEach-Object { Write-Log "  [migrate] $_" }
  if ($LASTEXITCODE -ne 0) { Fail "마이그레이션 적용 실패(종료 코드 $LASTEXITCODE) — install.log를 확인하세요." }
} finally {
  Pop-Location
}
Write-Log '  마이그레이션 완료'

# ── 6. 방화벽 규칙(재실행 대비 delete 후 add) ───────────────────────────
function Get-EnvIntValue {
  param([string]$Name, [int]$Default)
  $line = Get-Content $EnvFile | Where-Object { $_ -match "^\s*$Name\s*=\s*(\d+)\s*$" } | Select-Object -Last 1
  if ($line -and $line -match "=\s*(\d+)\s*$") { return [int]$Matches[1] }
  return $Default
}
$appPort = Get-EnvIntValue -Name 'PORT' -Default 3000
$pairingPort = Get-EnvIntValue -Name 'PAIRING_PORT' -Default ($appPort + 1)

foreach ($rule in @(
    @{ Name = 'TangoTalk Server (main)'; Port = $appPort },
    @{ Name = 'TangoTalk Server (pairing)'; Port = $pairingPort }
  )) {
  netsh advfirewall firewall delete rule name="$($rule.Name)" | Out-Null
  netsh advfirewall firewall add rule name="$($rule.Name)" dir=in action=allow protocol=TCP localport=$($rule.Port) | Out-Null
}

# 화상회의: 신호(TCP 7880/7881)와 미디어(UDP)를 따로 연다. 미디어는 ICE 후보 포트 범위
# (50000-60000)와 내장 TURN(3478) + TURN 릴레이 범위(30000-40000)가 모두 필요하다 —
# 하나라도 막히면 "연결은 되는데 화면이 안 나오는" 상태가 된다.
netsh advfirewall firewall delete rule name="TangoTalk LiveKit (signal)" | Out-Null
netsh advfirewall firewall add rule name="TangoTalk LiveKit (signal)" dir=in action=allow protocol=TCP localport="$LiveKitPort,$LiveKitTcpPort" | Out-Null
netsh advfirewall firewall delete rule name="TangoTalk LiveKit (media)" | Out-Null
netsh advfirewall firewall add rule name="TangoTalk LiveKit (media)" dir=in action=allow protocol=UDP localport=50000-60000 | Out-Null
netsh advfirewall firewall delete rule name="TangoTalk LiveKit (turn)" | Out-Null
netsh advfirewall firewall add rule name="TangoTalk LiveKit (turn)" dir=in action=allow protocol=UDP localport="$LiveKitTurnPort,30000-40000" | Out-Null

Write-Log "6/7 방화벽 규칙 적용됨 (앱 $appPort/$pairingPort, 화상회의 $LiveKitPort/$LiveKitTcpPort + UDP)"

# ── 7. 실행 방식 등록 ────────────────────────────────────────────────────
# LiveKit은 콘솔 모드/서비스 모드와 무관하게 항상 백그라운드 서비스로 돌린다 — 화상회의는
# "서버가 떠 있으면 되는" 상시 구성요소라, 관리자가 콘솔 창을 띄워두는 것과 별개다.
if (Test-Path $LiveKitExe) {
  $existingLiveKit = Get-Service -Name $LiveKitServiceName -ErrorAction SilentlyContinue
  if ($existingLiveKit) {
    & $NssmExe restart $LiveKitServiceName | Out-Null
    Write-Log "  화상회의 서비스($LiveKitServiceName) 재시작함"
  } else {
    & $NssmExe install $LiveKitServiceName $LiveKitExe "--config" "$LiveKitConfig"
    & $NssmExe set $LiveKitServiceName AppDirectory $LiveKitDir
    & $NssmExe set $LiveKitServiceName AppStdout (Join-Path $LiveKitDir 'livekit-out.log')
    & $NssmExe set $LiveKitServiceName AppStderr (Join-Path $LiveKitDir 'livekit-err.log')
    & $NssmExe set $LiveKitServiceName Start SERVICE_AUTO_START
    & $NssmExe start $LiveKitServiceName | Out-Null
    Write-Log "  화상회의 서비스($LiveKitServiceName) 등록하고 시작함"
  }
} else {
  Write-Log '  LiveKit 실행 파일이 없어 화상회의를 건너뜀(이 설치본에는 포함되지 않음)'
}

if ($RunMode -eq 'service') {
  $existing = Get-Service -Name $NodeServiceName -ErrorAction SilentlyContinue
  if ($existing) {
    & $NssmExe restart $NodeServiceName | Out-Null
    Write-Log "7/7 기존 서비스($NodeServiceName) 재시작함(새 코드 반영)"
  } else {
    & $NssmExe install $NodeServiceName $NodeExe "$ServerDir\src\index.js"
    & $NssmExe set $NodeServiceName AppDirectory $ServerDir
    & $NssmExe set $NodeServiceName AppStdout (Join-Path $ServerDir 'service-out.log')
    & $NssmExe set $NodeServiceName AppStderr (Join-Path $ServerDir 'service-err.log')
    & $NssmExe set $NodeServiceName Start SERVICE_AUTO_START
    & $NssmExe start $NodeServiceName | Out-Null
    Write-Log "7/7 백그라운드 서비스($NodeServiceName)로 등록하고 시작함"
  }
} else {
  Write-Log '7/7 콘솔 모드 선택됨 — 시작 메뉴의 "서버 콘솔로 실행"으로 직접 실행하세요.'
}

Write-Log '=== TangoTalk 서버 설정 완료 ==='

} catch {
  # 위 어디서든 Fail()을 거치지 않고 터진 예외는 전부 여기서 받는다 — Fail()과 똑같이
  # 로그+오류 창을 남기고 종료한다(스택 트레이스까지 남겨서 다음엔 바로 원인을 알 수 있게).
  Write-Log "오류(예상 못 한 예외): $($_.Exception.Message)"
  $position = ($_.InvocationInfo.PositionMessage -replace '\r?\n', ' ')
  Write-Log "  위치: $position"
  Add-Type -AssemblyName System.Windows.Forms
  [System.Windows.Forms.MessageBox]::Show(
    "서버 설치 중 예상하지 못한 오류가 발생했습니다:`n`n$($_.Exception.Message)`n`n" +
    "자세한 내용은 $LogFile 를 확인하세요. 이 창을 닫은 뒤 관리자 권한 PowerShell에서 이 " +
    "스크립트를 다시 실행하면 이어서 진행됩니다.",
    'TangoTalk 서버 설치', 'OK', 'Error'
  ) | Out-Null
  exit 1
}
