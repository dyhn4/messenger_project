<#
.SYNOPSIS
  TangoTalk 서버 설치 프로그램의 실제 작업 — messenger-server.iss의 [Run]에서 설치 마지막 단계로
  실행된다. PostgreSQL 무인 설치, 설치 폴더 접근 권한 잠금(SYSTEM/Administrators 전용 —
  Folder-Acl.ps1), 앱 전용 DB 계정/데이터베이스 생성, .env 작성, 마이그레이션 적용, 방화벽 규칙
  추가, 서버 실행 방식(백그라운드 서비스/콘솔) 등록까지 전부 처리한다.

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
    "서버 설치 중 문제가 발생했습니다:`n`n$Message`n`n자세한 내용은 $LogFile 를 확인하세요(설치 폴더가 " +
    "관리자 전용으로 잠긴 뒤에는 메모장을 관리자 권한으로 실행해서 여세요). " +
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

# $SecretsDir은 1단계에서 이 함수를 부르기 "전에" 관리자 전용으로 잠가 둔다 — 그래서 새 파일은 만들어지는
# 순간부터 그 권한을 물려받는다(파일을 먼저 쓰고 나중에 잠그면 그 사이에 다른 계정이 열어둘 수 있다).
function Get-OrCreateSecret {
  param([string]$FileName)
  $path = Join-Path $SecretsDir $FileName
  if (Test-Path $path) {
    return (Get-Content $path -Raw).Trim()
  }
  $value = New-RandomPassword
  Set-Content -Path $path -Value $value -NoNewline -Encoding ascii
  return $value
}

# 설치를 멈출 정도는 아니지만 운영자가 꼭 알아야 하는 일(접근 권한을 다 못 잠금 등) — 로그에 남기고, 설치
# 마지막에 한 번 창으로도 보여준다(Inno의 runhidden이라 로그만 남기면 아무도 못 본다).
$SetupWarnings = New-Object System.Collections.Generic.List[string]
function Write-SetupWarning {
  param([string]$Message)
  $SetupWarnings.Add($Message)
  Write-Log "  경고: $Message"
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

# 서버 서비스(NSSM)의 환경 변수에 NODE_ENV=production을 넣는다 — 되면 $true. Update-Server.ps1에도 똑같이 들어 있다 —
# 고치면 둘 다 고치고 tests\Service-Env.Tests.ps1을 돌릴 것(둘이 같은지도 본다).
# - Express는 NODE_ENV가 production이 아니면, 처리하지 못한 오류의 응답에 스택 트레이스(서버의 절대 경로)를 그대로
#   싣는다 — 서버를 인터넷에 열면 누구나 볼 수 있다. 서버 코드에는 NODE_ENV를 따로 보는 곳이 없다.
# - 이 스크립트 자신의 환경 변수($env:NODE_ENV)로 넣으면 안 된다 — 같은 프로세스에서 도는 npm install(Update-Server.ps1)이
#   devDependencies를 빼고 설치해(npm 7+) 마이그레이션에 쓰는 drizzle-kit이 깨진다. 그래서 서비스 설정에만 넣는다.
# - NSSM은 서비스를 시작할 때 서비스 키의 Parameters\AppEnvironmentExtra(REG_MULTI_SZ, 한 줄에 "이름=값" 하나)를 읽어 환경
#   변수로 더한다. nssm set으로 여러 줄을 한 번에 넣는 방법은 NSSM 버전마다 달라(번들한 2.24에서는 확인하지 못했다 — 인자를
#   공백으로 이어 한 줄로 만들면 NODE_ENV가 조용히 안 들어간다) 그 값을 직접 읽고 쓴다. 관리자가 따로 넣어 둔 다른 변수는
#   그대로 두고 NODE_ENV 줄만 바꾼다(nssm get은 파이프로 받으면 UTF-16으로 출력해 깨져 읽히기도 한다).
# - 서비스는 시작할 때 이 값을 읽으므로 시작/재시작 "전에" 부른다. 서비스 키가 없으면(NSSM 서비스가 아니면) 만들지 않고 $false.
function Set-NodeServiceProductionEnv {
  $paramsKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$NodeServiceName\Parameters"
  try {
    $current = (Get-Item -LiteralPath $paramsKey -ErrorAction Stop).GetValue('AppEnvironmentExtra')
    $entries = [string[]](@(@($current) | Where-Object { $_ -and $_ -notmatch '^NODE_ENV=' }) + 'NODE_ENV=production')
    Set-ItemProperty -LiteralPath $paramsKey -Name 'AppEnvironmentExtra' -Value $entries -Type MultiString -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
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

# 폴더 접근 권한 잠금 공용 함수(이 스크립트와 같은 폴더에 함께 설치된다 — 자세한 이유는 Folder-Acl.ps1).
. (Join-Path $PSScriptRoot 'Folder-Acl.ps1')
# 설치 경로가 링크(정션/심볼릭 링크)면 서버·DB·LiveKit과 그 비밀값이 링크가 가리키는 "다른" 폴더에서
# 실행·저장되고, SYSTEM/NetworkService 서비스로 도는 그 코드를 아무나 바꿔치기할 수 있다(일반 사용자도 C:\에
# 폴더·링크를 만들 수 있어 관리자가 설치하기 전에 심어둘 수 있다). messenger-server.iss의 PrepareToInstall이
# 설치 전에 막지만, 설치 도중 바꿔치기까지 대비해 여기서도 확인하고 더 진행하지 않는다.
if (Test-ReparsePoint -Path $AppDir) {
  Fail "설치 경로($AppDir)가 링크(정션/심볼릭 링크)라 보안을 위해 설치를 중단합니다. 이 폴더(링크)를 지우고 다시 설치하세요."
}
# 설치 경로가 드라이브 최상위나 Program Files 자체처럼 다른 것과 함께 쓰는 폴더면, 잠그는 순간 그 안의 다른
# 프로그램·파일까지 관리자 전용이 돼버리므로 잠그지 않고 경고만 남긴다(네트워크/FAT 드라이브도 마찬가지).
$aclKind = Get-FolderLockKind -Path $AppDir
$lockAcl = ($aclKind -eq 'Local')
if (-not $lockAcl) {
  Write-SetupWarning ("설치 경로($AppDir)가 $($AclKindText[$aclKind])라서 폴더 접근 권한을 잠그지 않았습니다 — " +
    '이 PC의 다른 계정이 서버 파일을 바꾸거나 비밀값을 읽을 수 있습니다. 전용 폴더(예: C:\TangoTalk-Server)에 다시 설치하는 것을 권장합니다.')
}

# ── 1. 비밀값(DB 비밀번호) 확인/생성 — 이미 있으면 재사용, 없으면 새로 생성 ──────
# 비밀값 파일을 쓰기 "전에" secrets 폴더부터 SYSTEM/Administrators 전용으로 잠근다 — 최초 설치 때는 설치
# 폴더 전체가 아직 C:\의 넓은 권한을 물려받은 상태다(전체 잠금은 PostgreSQL 설치 직후인 2.5단계). 설치
# 경로 자체를 잠글 수 없는 경우(위 경고)에도 이 폴더는 우리 전용이라 잠글 수 있으면 잠근다.
if (-not (Test-Path $SecretsDir)) {
  New-Item -ItemType Directory -Path $SecretsDir -Force | Out-Null
}
# 비밀값 폴더가 링크면 DB 비밀번호가 링크가 가리키는 다른 폴더에 써진다 — 멈춘다(최초 설치라 설치 폴더가 아직
# 안 잠긴 상태라, 아무나 미리 {app}\secrets를 정션으로 만들어 뒀을 수 있다). 잠글 수 없는 경로면(네트워크/FAT
# 등) 최소한 경고는 남긴다 — 예전 버전은 Local이 아니면 조용히 건너뛰어 비밀번호가 평문으로 노출됐다.
$secretsKind = Get-FolderLockKind -Path $SecretsDir
if ($secretsKind -eq 'Local') {
  foreach ($warning in @(Set-AdminOnlyAcl -Path $SecretsDir)) { Write-SetupWarning $warning }
} elseif (Test-ReparsePoint -Path $SecretsDir) {
  Fail "비밀값 폴더($SecretsDir)가 링크(정션/심볼릭 링크)라 DB 비밀번호가 엉뚱한 폴더에 써질 수 있어 설치를 중단합니다. 이 폴더(링크)를 지우고 다시 설치하세요."
} else {
  Write-SetupWarning "비밀값 폴더($SecretsDir)를 관리자 전용으로 잠그지 못했습니다($($AclKindText[$secretsKind])) — 이 PC의 다른 계정이 DB 비밀번호를 읽을 수 있습니다. 전용 폴더(예: C:\TangoTalk-Server)에 설치하는 것을 권장합니다."
}
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

# ── 2.5 설치 폴더 접근 권한 잠금 ─────────────────────────────────────────
# 설치 폴더 전체를 SYSTEM/Administrators 전용으로 잠근다(이유·예외는 Folder-Acl.ps1의 Protect-InstallDir).
# 이후 단계가 만드는 .env·LiveKit 비밀값·livekit.yaml, 서버가 첫 실행 때 만드는 .jwt-secret·
# .db-encryption-key·.web-push-vapid.json·certs\key.pem, 첨부파일·로그도 전부 이 권한을 물려받는다.
# PostgreSQL 설치 "뒤"에 하는 이유: EDB 설치 프로그램은 initdb 등을 제한된 토큰으로 돌리는데, 그 과정이 이
# 폴더의 원래(넓은) 권한에 기대는지는 검증하지 못했다 — 설치 도중의 환경은 예전 그대로 두고 끝난 직후 잠근다.
# (재설치·업그레이드는 PostgreSQL 단계를 건너뛰므로 시작하자마자 잠긴다.)
if ($lockAcl) {
  Write-Log '2.5/7 설치 폴더 접근 권한을 SYSTEM/Administrators 전용으로 잠그는 중(파일이 많아 1~2분 걸릴 수 있음)...'
  foreach ($warning in @(Protect-InstallDir -AppDir $AppDir -PgServiceName $PgServiceName)) { Write-SetupWarning $warning }
  Write-Log '  접근 권한 잠금 완료'
}

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
# .env는 DB 비밀번호(DATABASE_URL)를 평문으로 담고 있다 — 따로 잠그지 않고 2.5단계에서 잠근 설치 폴더
# 권한(SYSTEM/Administrators 전용)을 그대로 물려받는다. server/src/config.js의 resolveSecret이
# { mode: 0o600 }으로 만드는 .jwt-secret 등도 마찬가지다(0o600은 POSIX 권한 비트라 NTFS에서는 아무것도 막지
# 않는다). 예전 버전은 여기서 파일마다 'Administrators:(R)'처럼 이름으로 잠갔는데, (1) 이미 있던 두 파일만
# 잠그고 나중에 생기는 비밀값(.livekit-secret, .web-push-vapid.json, certs\key.pem)은 놓쳤고, (2) 읽기
# 전용이라 관리자도 "첨부파일 저장소"/"외부 접속 주소"에서 .env를 고쳐 쓰지 못했고, (3) 그룹 이름은 Windows
# 언어마다 달라 못 찾으면 icacls가 조용히 실패했다. 그 개별 권한은 2.5단계가 상속으로 되돌린다.

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
  # 운영 모드(NODE_ENV=production)로 돌게 한다(이유는 Set-NodeServiceProductionEnv). 예전 버전이 등록한 서비스에는 이 값이
  # 없으므로 기존 서비스도 재시작 전에 맞춘다 — 기존 서버는 이 설치 프로그램을 다시 실행할 때 여기서 처음 들어간다.
  # 직접 고치는 방법은 nssm edit(설정 창)으로 안내한다 — "nssm set … AppEnvironmentExtra 값"은 그 칸을 통째로 바꿔서 관리자가
  # 넣어 둔 다른 환경 변수까지 지운다(Set-NodeServiceProductionEnv가 일부러 다른 줄을 남기는 이유).
  $nodeEnvWarning = "서버 서비스($NodeServiceName)에 NODE_ENV=production을 넣지 못했습니다 — 처리하지 못한 오류가 나면 응답에 " +
    "서버 내부 경로가 보일 수 있습니다. 관리자 권한 PowerShell에서 & `"$NssmExe`" edit $NodeServiceName 을 실행해 Environment 탭에 " +
    "NODE_ENV=production 한 줄을 더하고(다른 줄은 그대로 두세요) [Edit service]를 누른 뒤 시작 메뉴 `"서버 재시작`"을 누르세요."
  $existing = Get-Service -Name $NodeServiceName -ErrorAction SilentlyContinue
  if ($existing) {
    if (-not (Set-NodeServiceProductionEnv)) { Write-SetupWarning $nodeEnvWarning }
    & $NssmExe restart $NodeServiceName | Out-Null
    Write-Log "7/7 기존 서비스($NodeServiceName) 재시작함(새 코드 반영)"
  } else {
    & $NssmExe install $NodeServiceName $NodeExe "$ServerDir\src\index.js"
    & $NssmExe set $NodeServiceName AppDirectory $ServerDir
    & $NssmExe set $NodeServiceName AppStdout (Join-Path $ServerDir 'service-out.log')
    & $NssmExe set $NodeServiceName AppStderr (Join-Path $ServerDir 'service-err.log')
    & $NssmExe set $NodeServiceName Start SERVICE_AUTO_START
    if (-not (Set-NodeServiceProductionEnv)) { Write-SetupWarning $nodeEnvWarning }
    & $NssmExe start $NodeServiceName | Out-Null
    Write-Log "7/7 백그라운드 서비스($NodeServiceName)로 등록하고 시작함"
  }
} else {
  Write-Log '7/7 콘솔 모드 선택됨 — 시작 메뉴의 "서버 콘솔로 실행"으로 직접 실행하세요(관리자 권한 확인 창이 뜹니다).'
}

Write-Log '=== TangoTalk 서버 설정 완료 ==='

if ($SetupWarnings.Count -gt 0) {
  Add-Type -AssemblyName System.Windows.Forms
  [System.Windows.Forms.MessageBox]::Show(
    "서버 설치는 끝났지만 확인할 것이 있습니다:`n`n- $($SetupWarnings -join "`n- ")`n`n" +
    "자세한 내용은 $LogFile 를 확인하세요(관리자 전용 파일이라 메모장을 관리자 권한으로 실행해서 여세요).",
    'TangoTalk 서버 설치', 'OK', 'Warning'
  ) | Out-Null
}

} catch {
  # 위 어디서든 Fail()을 거치지 않고 터진 예외는 전부 여기서 받는다 — Fail()과 똑같이
  # 로그+오류 창을 남기고 종료한다(스택 트레이스까지 남겨서 다음엔 바로 원인을 알 수 있게).
  Write-Log "오류(예상 못 한 예외): $($_.Exception.Message)"
  $position = ($_.InvocationInfo.PositionMessage -replace '\r?\n', ' ')
  Write-Log "  위치: $position"
  Add-Type -AssemblyName System.Windows.Forms
  [System.Windows.Forms.MessageBox]::Show(
    "서버 설치 중 예상하지 못한 오류가 발생했습니다:`n`n$($_.Exception.Message)`n`n" +
    "자세한 내용은 $LogFile 를 확인하세요(설치 폴더가 관리자 전용으로 잠긴 뒤에는 메모장을 관리자 권한으로 " +
    "실행해서 여세요). 이 창을 닫은 뒤 관리자 권한 PowerShell에서 이 " +
    "스크립트를 다시 실행하면 이어서 진행됩니다.",
    'TangoTalk 서버 설치', 'OK', 'Error'
  ) | Out-Null
  exit 1
}
