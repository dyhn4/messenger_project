<#
.SYNOPSIS
  "화상회의 녹화 서버(Docker)" 시작 메뉴 항목 — 화상회의 녹화·회의록·실시간 자막에 필요한 LiveKit Egress와 Redis를 Docker로 띄우고,
  이 서버(.env)와 LiveKit(livekit.yaml)을 거기에 맞춘다.

.DESCRIPTION
  Egress(녹화 컴포넌트)는 Windows용 실행 파일이 없고 Docker 이미지로만 나와서 설치 프로그램에 넣지 못한다. 그래서 이 PC에 Docker
  Desktop(WSL2)이 있으면 이 스크립트가 남은 일을 한 번에 한다:
    1) 녹화 폴더를 정한다(기본 <설치 폴더>\recordings — 서버와 Egress가 같이 쓴다).
    2) <설치 폴더>\call-recording\에 egress.yaml(LiveKit 키·주소·Redis)과 docker-compose.yml(Redis + Egress, 다시 켜면 저절로)을 쓴다.
    3) livekit.yaml에 redis 주소를 더한다(LiveKit이 Egress에 일을 넘기는 길).
    4) .env에 CALL_RECORDING_DIR·CALL_RECORDING_EGRESS_DIR을 쓴다(실시간 자막 주소 CALL_CAPTION_WS_URL은 기본값이 이 구성에 맞다).
    5) 실시간 자막용 포트(7891)를 방화벽에서 연다(Egress 컨테이너가 이 서버로 소리를 보낸다 — 개인·도메인 네트워크만).
    6) docker compose up -d로 띄우고, LiveKit과 서버 서비스를 다시 시작한다.
  받아쓰기·요약(회의록)은 바깥 서비스라 .env에 직접 적는다(CALL_TRANSCRIBE_URL 등 — README "화상회의 녹화·회의록").
  -Off를 주면 컨테이너를 내리고 .env의 CALL_RECORDING_DIR을 비운다(녹화 단추가 사라진다 — 녹화 폴더와 파일은 남김).
  관리자 권한이 필요해서, 관리자가 아니면 스스로 관리자 권한으로 다시 실행한다.
#>
param([switch]$Off)

# ── 관리자 권한 확인/승격 ───────────────────────────────────────────────
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $offArg = if ($Off) { ' -Off' } else { '' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"$offArg"
    exit
}

$NodeServiceName = 'TangoTalkServer'
$LiveKitServiceName = 'TangoTalkLiveKit'
$CaptionPort = 7891
$CaptionRuleName = 'TangoTalk Captions (Egress)'
$ComposeProject = 'tangotalk-recording'

# ── 순수 함수(tests\Call-Recording.Tests.ps1이 꺼내 쓴다) ────────────────────

# livekit.yaml의 port(신호 포트) — 없으면 7880.
function Get-LiveKitPort {
    param([string]$Yaml)
    if ($Yaml -match '(?m)^port:\s*(\d+)\s*$') { return [int]$Matches[1] }
    return 7880
}

# livekit.yaml의 keys 아래 첫 키 이름과 비밀값 — @{ Key; Secret }(없으면 $null).
function Get-LiveKitKey {
    param([string]$Yaml)
    if ($Yaml -match '(?m)^keys:\s*\r?\n\s+([A-Za-z0-9_-]+):\s*(\S+)\s*$') {
        return @{ Key = $Matches[1]; Secret = $Matches[2] }
    }
    return $null
}

# livekit.yaml에 redis 주소를 더한다 — 이미 redis:가 있으면 그대로(관리자가 다른 Redis를 쓸 수 있다). 줄바꿈은 원래 것을 따른다.
function Add-LiveKitRedis {
    param([string]$Yaml, [string]$Address = '127.0.0.1:6379')
    if ($Yaml -match '(?m)^redis:') { return $Yaml }
    $nl = if ($Yaml -match "`r`n") { "`r`n" } else { "`n" }
    $body = $Yaml.TrimEnd("`r", "`n")
    return "$body$nl# 화상회의 녹화(Egress)용 — Call-Recording.ps1이 더함$($nl)redis:$($nl)  address: $Address$nl"
}

# Egress 설정 — LiveKit은 이 PC(컨테이너에서 host.docker.internal), Redis는 같은 compose의 redis.
function New-EgressYaml {
    param([string]$ApiKey, [string]$ApiSecret, [int]$LiveKitPort)
    @(
        '# TangoTalk Call-Recording.ps1이 만들었습니다 — 다시 실행하면 새로 씁니다.'
        "api_key: $ApiKey"
        "api_secret: $ApiSecret"
        "ws_url: ws://host.docker.internal:$LiveKitPort"
        'redis:'
        '  address: redis:6379'
        'log_level: info'
    ) -join "`r`n"
}

# docker-compose.yml — 녹화 폴더([RecordingDir], 이 PC 경로)를 컨테이너의 /out으로. Docker Desktop은 C:\… 경로를 그대로 받는다.
function New-RecordingCompose {
    param([string]$RecordingDir)
    $dir = $RecordingDir -replace '\\', '/'
    @(
        '# TangoTalk Call-Recording.ps1이 만들었습니다 — 다시 실행하면 새로 씁니다.'
        'services:'
        '  redis:'
        '    image: redis:7-alpine'
        '    restart: unless-stopped'
        '    ports:'
        '      - "127.0.0.1:6379:6379"'
        '  egress:'
        '    image: livekit/egress:latest'
        '    restart: unless-stopped'
        '    cap_add:'
        '      - SYS_ADMIN'
        '    environment:'
        '      EGRESS_CONFIG_FILE: /config/egress.yaml'
        '    extra_hosts:'
        '      - "host.docker.internal:host-gateway"'
        '    volumes:'
        '      - ./egress.yaml:/config/egress.yaml:ro'
        "      - `"$($dir):/out`""
        '    depends_on:'
        '      - redis'
    ) -join "`r`n"
}

# ── .env 읽고 쓰기(Web-Domain.ps1과 같은 규칙) ─────────────────────────────

function Read-EnvLines {
    if (-not (Test-Path -LiteralPath $EnvFile)) { return }
    try {
        $text = [System.IO.File]::ReadAllText($EnvFile, (New-Object System.Text.UTF8Encoding($false, $true)))
    } catch {
        $text = [System.IO.File]::ReadAllText($EnvFile, [System.Text.Encoding]::Default)
    }
    $lines = @($text -split '\r?\n')
    $count = $lines.Count
    if ($count -gt 0 -and $lines[$count - 1] -eq '') { $count-- }
    for ($i = 0; $i -lt $count; $i++) { $lines[$i] }
}

function Get-EnvValue {
    param([string]$Name, [string[]]$Lines)
    $value = ''
    foreach ($line in $Lines) {
        if ($line -match "^\s*(?:export\s+)?$([regex]::Escape($Name))\s*=\s*(.*)$") {
            $raw = $Matches[1].Trim()
            if ($raw -match '^(["''`])(.*)\1$') {
                $value = $Matches[2]
            } else {
                $value = ($raw -replace '#.*$', '').Trim()
            }
        }
    }
    return $value
}

function Set-EnvValues {
    param([System.Collections.IDictionary]$Values, [string]$Comment)
    $found = @{}
    $newLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Read-EnvLines)) {
        $replaced = $false
        foreach ($name in $Values.Keys) {
            if ($line -match "^\s*(?:export\s+)?$([regex]::Escape($name))\s*=") {
                $newLines.Add("$name=$($Values[$name])")
                $found[$name] = $true
                $replaced = $true
                break
            }
        }
        if (-not $replaced) { $newLines.Add($line) }
    }
    $missing = @($Values.Keys | Where-Object { -not $found[$_] })
    if ($missing.Count -gt 0) {
        if ($newLines.Count -gt 0 -and $newLines[$newLines.Count - 1].Trim() -ne '') { $newLines.Add('') }
        if ($Comment) { $newLines.Add($Comment) }
        foreach ($name in $missing) { $newLines.Add("$name=$($Values[$name])") }
    }
    [System.IO.File]::WriteAllLines($EnvFile, $newLines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
}

$AppDir = $PSScriptRoot
$ServerDir = Join-Path $AppDir 'server'
$EnvFile = Join-Path $ServerDir '.env'
$LiveKitConfig = Join-Path $AppDir 'livekit\livekit.yaml'
$ComposeDir = Join-Path $AppDir 'call-recording'
$ComposeFile = Join-Path $ComposeDir 'docker-compose.yml'
$NssmExe = Join-Path $AppDir 'tools\nssm.exe'

function Stop-WithMessage {
    param([string]$Message)
    Write-Host ''
    Write-Host $Message -ForegroundColor Red
    Write-Host ''
    Read-Host '엔터를 누르면 닫습니다' | Out-Null
    exit 1
}

function Restart-TangoTalkService {
    param([string]$Name)
    if (Test-Path -LiteralPath $NssmExe) {
        & $NssmExe restart $Name | Out-Null
    } else {
        Restart-Service -Name $Name -ErrorAction SilentlyContinue
    }
}

function Invoke-Compose {
    param([string[]]$ComposeArgs)
    & docker compose -p $ComposeProject -f $ComposeFile @ComposeArgs
    return $LASTEXITCODE
}

Write-Host '=== TangoTalk 화상회의 녹화 서버(Docker) ===' -ForegroundColor Cyan
Write-Host ''

# ── Docker 확인 ─────────────────────────────────────────────────────────
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Stop-WithMessage ('Docker가 없습니다. 녹화 컴포넌트(LiveKit Egress)는 Windows용 실행 파일이 없어 Docker로만 띄울 수 있습니다.' +
        "`r`nDocker Desktop(https://www.docker.com/products/docker-desktop/ — WSL2 사용)을 설치하고 켠 뒤 다시 실행하세요.")
}
& docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Stop-WithMessage 'Docker가 켜져 있지 않습니다. Docker Desktop을 켜고(작업 표시줄의 고래 아이콘이 멈출 때까지) 다시 실행하세요.'
}

if ($Off) {
    if (Test-Path -LiteralPath $ComposeFile) {
        Write-Host '녹화 서버 컨테이너를 내립니다…'
        Invoke-Compose @('down') | Out-Null
    }
    Set-EnvValues -Values ([ordered]@{ CALL_RECORDING_DIR = '' })
    Restart-TangoTalkService $NodeServiceName
    Write-Host ''
    Write-Host '화상회의 녹화를 껐습니다(녹화 폴더와 파일은 그대로 있습니다).' -ForegroundColor Green
    Read-Host '엔터를 누르면 닫습니다' | Out-Null
    exit 0
}

# ── 1. 녹화 폴더 ───────────────────────────────────────────────────────
$envLines = @(Read-EnvLines)
$current = Get-EnvValue -Name 'CALL_RECORDING_DIR' -Lines $envLines
$default = if ($current) { $current } else { Join-Path $AppDir 'recordings' }
$answer = Read-Host "녹화 폴더(서버와 Egress가 같이 씁니다) [$default]"
$RecordingDir = if ($answer.Trim()) { $answer.Trim().Trim('"') } else { $default }
try {
    New-Item -ItemType Directory -Force -Path $RecordingDir | Out-Null
} catch {
    Stop-WithMessage "녹화 폴더를 만들지 못했습니다: $RecordingDir ($($_.Exception.Message))"
}

# ── 2. Egress 설정·compose 파일 ─────────────────────────────────────────
if (-not (Test-Path -LiteralPath $LiveKitConfig)) {
    Stop-WithMessage "LiveKit 설정이 없습니다: $LiveKitConfig — 서버 설치가 끝난 뒤 실행하세요."
}
$liveKitYaml = [System.IO.File]::ReadAllText($LiveKitConfig)
$key = Get-LiveKitKey -Yaml $liveKitYaml
if (-not $key) { Stop-WithMessage "livekit.yaml에서 API 키(keys:)를 찾지 못했습니다: $LiveKitConfig" }
$liveKitPort = Get-LiveKitPort -Yaml $liveKitYaml
New-Item -ItemType Directory -Force -Path $ComposeDir | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $ComposeDir 'egress.yaml'), (New-EgressYaml -ApiKey $key.Key -ApiSecret $key.Secret -LiveKitPort $liveKitPort), $utf8)
[System.IO.File]::WriteAllText($ComposeFile, (New-RecordingCompose -RecordingDir $RecordingDir), $utf8)
Write-Host "1/5 Egress 설정을 썼습니다: $ComposeDir"

# ── 3. livekit.yaml에 Redis ────────────────────────────────────────────
$withRedis = Add-LiveKitRedis -Yaml $liveKitYaml
if ($withRedis -ne $liveKitYaml) {
    [System.IO.File]::WriteAllText($LiveKitConfig, $withRedis, $utf8)
    Write-Host '2/5 livekit.yaml에 Redis 주소를 더했습니다.'
} else {
    Write-Host '2/5 livekit.yaml에 Redis가 이미 있습니다 — 그대로 둡니다.'
}

# ── 4. .env ─────────────────────────────────────────────────────────────
Set-EnvValues -Values ([ordered]@{ CALL_RECORDING_DIR = $RecordingDir; CALL_RECORDING_EGRESS_DIR = '/out' }) `
    -Comment '# Call-Recording.ps1이 정한 화상회의 녹화 폴더(Egress 컨테이너 안에서는 /out)'
Write-Host '3/5 .env에 녹화 폴더를 적었습니다.'

# ── 5. 실시간 자막 포트 ─────────────────────────────────────────────────
& netsh advfirewall firewall delete rule name="$CaptionRuleName" *> $null
& netsh advfirewall firewall add rule name="$CaptionRuleName" dir=in action=allow protocol=TCP localport=$CaptionPort profile=private,domain | Out-Null
Write-Host "4/5 실시간 자막용 포트($CaptionPort)를 열었습니다(개인·도메인 네트워크)."

# ── 6. 띄우기·다시 시작 ─────────────────────────────────────────────────
Write-Host '5/5 Redis와 Egress를 받아 띄웁니다(처음에는 몇 분 걸립니다 — 인터넷이 필요합니다)…'
$code = Invoke-Compose @('up', '-d', '--pull', 'missing')
if ($code -ne 0) {
    Stop-WithMessage "컨테이너를 띄우지 못했습니다(docker compose 종료 코드 $code). 위 메시지를 확인하세요."
}
Restart-TangoTalkService $LiveKitServiceName
Restart-TangoTalkService $NodeServiceName

Write-Host ''
Write-Host '화상회의 녹화를 켰습니다. 통화 화면 위의 ● 단추로 녹화합니다.' -ForegroundColor Green
if (-not (Get-EnvValue -Name 'CALL_TRANSCRIBE_URL' -Lines @(Read-EnvLines))) {
    Write-Host ''
    Write-Host '회의록·실시간 자막을 쓰려면 server\.env에 받아쓰기 서비스(CALL_TRANSCRIBE_URL 등)를 적고 "서버 재시작"을 누르세요.' -ForegroundColor Yellow
}
Write-Host ''
Read-Host '엔터를 누르면 닫습니다' | Out-Null
