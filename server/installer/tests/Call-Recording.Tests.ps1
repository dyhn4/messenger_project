<#
.SYNOPSIS
  "화상회의 녹화 서버(Docker)"(Call-Recording.ps1) 확인용 테스트 — 개발 PC 전용(설치 프로그램·업데이트 zip에는 안 들어감). 관리자 권한
  없이 돌고 %TEMP% 안의 임시 .env만 쓴다. 설치용 .ps1은 실행하지 않고 함수만 꺼내 쓴다(Docker·방화벽·서비스는 건드리지 않는다).

.DESCRIPTION
  1) 구성: 구문 오류 없음, BOM 있는 UTF-8 + CRLF, 맨 처음에 스스로 승격, 시작 메뉴 바로가기·[Files]·제거 때 방화벽 규칙 지우기.
  2) livekit.yaml 읽기·고치기(Get-LiveKitPort·Get-LiveKitKey·Add-LiveKitRedis — 이미 있으면 그대로, 줄바꿈은 원래 것).
  3) Egress 설정·compose 파일(New-EgressYaml·New-RecordingCompose — 녹화 폴더를 /out으로, host.docker.internal).
  4) .env 고치기(Set-EnvValues) — 있는 값은 바꾸고 없는 값은 주석과 함께 끝에, 다른 줄은 그대로.

  사용법(저장소 루트): powershell -NoProfile -ExecutionPolicy Bypass -File server\installer\tests\Call-Recording.Tests.ps1
  실패가 하나라도 있으면 종료 코드 1.
#>

$ErrorActionPreference = 'Stop'
$installerDir = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $installerDir 'Call-Recording.ps1'
$iss = [System.IO.File]::ReadAllText((Join-Path $installerDir 'messenger-server.iss'), [System.Text.Encoding]::UTF8)

$script:passed = 0
$script:failures = New-Object System.Collections.Generic.List[string]
function Check([string]$Name, $Actual, $Expected) {
  if ("$Actual" -ceq "$Expected") { $script:passed++ } else { $script:failures.Add("$Name -> [$Actual], 기대값 [$Expected]") }
}
function CheckContains([string]$Name, [string]$Text, [string]$Part) {
  if ($Text.Contains($Part)) { $script:passed++ } else { $script:failures.Add("$Name -> [$Text]에 '$Part'이(가) 없음") }
}

# ── 1) 구성 ───────────────────────────────────────────────────────────────────
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
Check 'parse: 구문 오류 없음' (@($parseErrors).Count) 0
$bytes = [System.IO.File]::ReadAllBytes($scriptPath)
Check 'encoding: BOM 있는 UTF-8' ("{0:X2}{1:X2}{2:X2}" -f $bytes[0], $bytes[1], $bytes[2]) 'EFBBBF'
$raw = [System.Text.Encoding]::UTF8.GetString($bytes)
Check 'encoding: 줄바꿈은 CRLF' ($raw -match "[^`r]`n") $false
$first = @($ast.EndBlock.Statements)[1].Extent.Text
Check 'elevate: 맨 처음에 스스로 승격' ($first -match 'IsInRole\(' -and $first -match '-Verb\s+RunAs') $true
CheckContains 'iss: [Files]' $iss 'Source: "Call-Recording.ps1"; DestDir: "{app}"'
CheckContains 'iss: 시작 메뉴' $iss '{app}\Call-Recording.ps1'
CheckContains 'iss: 제거 때 자막 포트 규칙 지우기' $iss 'delete rule name=""TangoTalk Captions (Egress)""'
CheckContains 'script: 같은 규칙 이름' $raw "`$CaptionRuleName = 'TangoTalk Captions (Egress)'"
# 서버 기본값(config.js CALL_CAPTION_WS_PORT·CALL_CAPTION_WS_URL)과 같은 포트.
$config = [System.IO.File]::ReadAllText((Join-Path (Split-Path $installerDir -Parent) 'src\config.js'))
CheckContains 'config: 자막 포트 기본값 7891' $config 'Number(process.env.CALL_CAPTION_WS_PORT) || 7891'
CheckContains 'script: 자막 포트 7891' $raw '$CaptionPort = 7891'

# 함수만 꺼내 이 세션에 정의한다.
foreach ($fn in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
  . ([scriptblock]::Create($fn.Extent.Text))
}

# ── 2) livekit.yaml ──────────────────────────────────────────────────────────
$yaml = "# 자동 생성`r`nport: 7980`r`nrtc:`r`n  tcp_port: 7881`r`nkeys:`r`n  tangotalk: abc123def`r`n"
Check 'livekit: 포트' (Get-LiveKitPort -Yaml $yaml) 7980
Check 'livekit: 포트 없으면 7880' (Get-LiveKitPort -Yaml "keys:`n  a: b`n") 7880
$key = Get-LiveKitKey -Yaml $yaml
Check 'livekit: 키 이름' $key.Key 'tangotalk'
Check 'livekit: 비밀값' $key.Secret 'abc123def'
Check 'livekit: 키 없음' ($null -eq (Get-LiveKitKey -Yaml "port: 7880`n")) $true
$added = Add-LiveKitRedis -Yaml $yaml
CheckContains 'redis: 더함' $added "redis:`r`n  address: 127.0.0.1:6379`r`n"
Check 'redis: 원래 줄은 그대로' ($added.StartsWith($yaml.TrimEnd("`r", "`n"))) $true
Check 'redis: 이미 있으면 그대로' (Add-LiveKitRedis -Yaml "port: 1`nredis:`n  address: 10.0.0.5:6379`n") "port: 1`nredis:`n  address: 10.0.0.5:6379`n"
CheckContains 'redis: LF 파일은 LF로' (Add-LiveKitRedis -Yaml "port: 1`n") "redis:`n  address"

# ── 3) Egress 설정·compose ───────────────────────────────────────────────────
$egress = New-EgressYaml -ApiKey 'tangotalk' -ApiSecret 's3cret' -LiveKitPort 7980
CheckContains 'egress: 키' $egress 'api_key: tangotalk'
CheckContains 'egress: 비밀값' $egress 'api_secret: s3cret'
CheckContains 'egress: LiveKit 주소' $egress 'ws_url: ws://host.docker.internal:7980'
CheckContains 'egress: redis' $egress "redis:`r`n  address: redis:6379"
$compose = New-RecordingCompose -RecordingDir 'C:\Program Files\TangoTalk Server\recordings'
CheckContains 'compose: 녹화 폴더를 /out으로(따옴표 — 공백 든 경로)' $compose '- "C:/Program Files/TangoTalk Server/recordings:/out"'
CheckContains 'compose: Egress 설정 파일' $compose 'EGRESS_CONFIG_FILE: /config/egress.yaml'
CheckContains 'compose: SYS_ADMIN' $compose '- SYS_ADMIN'
CheckContains 'compose: Redis는 이 PC에만' $compose '"127.0.0.1:6379:6379"'
CheckContains 'compose: 다시 켜면 저절로' $compose 'restart: unless-stopped'
CheckContains 'compose: 이 PC 주소' $compose 'host.docker.internal:host-gateway'

# ── 4) .env ──────────────────────────────────────────────────────────────────
$tmp = Join-Path $env:TEMP ("callrec-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $EnvFile = Join-Path $tmp '.env'
  [System.IO.File]::WriteAllText($EnvFile, "# 서버 설정`nPORT=3000`nCALL_RECORDING_DIR=D:\old`n", (New-Object System.Text.UTF8Encoding($false)))
  Set-EnvValues -Values ([ordered]@{ CALL_RECORDING_DIR = 'C:\TangoTalk\recordings'; CALL_RECORDING_EGRESS_DIR = '/out' }) -Comment '# 녹화'
  $after = [System.IO.File]::ReadAllText($EnvFile)
  Check 'env: 바꾸고 더함' $after "# 서버 설정`r`nPORT=3000`r`nCALL_RECORDING_DIR=C:\TangoTalk\recordings`r`n`r`n# 녹화`r`nCALL_RECORDING_EGRESS_DIR=/out`r`n"
  Check 'env: 읽기' (Get-EnvValue -Name 'CALL_RECORDING_DIR' -Lines @(Read-EnvLines)) 'C:\TangoTalk\recordings'
} finally {
  Remove-Item -Recurse -Force $tmp
}

''
if ($script:failures.Count -gt 0) {
  $script:failures | ForEach-Object { "FAIL $_" }
  "통과 $($script:passed), 실패 $($script:failures.Count)"
  exit 1
}
"통과 $($script:passed), 실패 0"
