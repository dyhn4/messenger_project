<#
.SYNOPSIS
  "웹 앱 주소(정식 인증서)" 시작 메뉴 항목 — 아이폰 사용자가 사파리로 여는 웹 앱의 주소(공유기 DDNS 도메인 등)를 정하면, 서버가
  그 도메인의 공인 인증서(Let's Encrypt)를 스스로 받아 웹 전용 HTTPS 포트로 웹 앱을 연다. 그 설정을 보여주고 바꾸거나 끌 수 있게
  해준다.

.DESCRIPTION
  아이폰 사파리는 공인 인증서가 걸린 주소에서만 웹 앱을 제대로 쓸 수 있다(자체 서명이면 경고 화면이 뜨고, "홈 화면에 추가"한 앱과
  웹 푸시도 안 된다). 그런데 PC·안드로이드 앱은 메인 포트(PORT, 기본 3000)의 자체 서명 인증서를 핀닝하므로(server/src/certs.js,
  client/lib/services/pinned_tls.dart) 그 인증서를 바꾸면 모든 기기를 다시 페어링해야 한다. 그래서 메인 포트는 그대로 두고, 서버가
  같은 앱(웹 앱·API·실시간 연결·화상회의 신호·/pair)을 별도의 웹 HTTPS 포트(WEB_HTTPS_PORT)로 한 번 더 열면서 그 포트에만
  Let's Encrypt 인증서를 받아 건다 — 발급·자동 갱신·상태 표시(앱의 관리자 콘솔)는 서버가 한다.

  이 스크립트는 External-Address.ps1과 같은 방식의 GUI일 뿐이다: .env의 WEB_DOMAIN·WEB_HTTPS_PORT·ACME_HTTP_PORT·ACME_EMAIL(시험
  발급이면 ACME_STAGING)을 쓰고, 그 포트들의 Windows 방화벽 규칙을 맞추고, 서비스를 재시작한다. 공유기 포트포워딩은 해 줄 수 없어서
  안내만 한다 — Let's Encrypt의 발급 확인은 밖의 443(TLS-ALPN-01)과 밖의 80(HTTP-01)으로 오는데, 통신사가 80을 막는 경우가 있어
  서버는 둘 다 쓴다. 이 PC의 웹 포트에 걸린 인증서를 바로 확인하는 [인증서 확인]도 있다. 서비스 재시작과 방화벽 규칙에 관리자
  권한이 필요해서, 관리자가 아니면 스스로 관리자 권한으로 다시 실행한다.
#>

# ── 관리자 권한 확인/승격 ───────────────────────────────────────────────
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$AppDir = $PSScriptRoot
$ServerDir = Join-Path $AppDir 'server'
$EnvFile = Join-Path $ServerDir '.env'
$NodeExe = Join-Path $AppDir 'node\node.exe'
$NssmExe = Join-Path $AppDir 'tools\nssm.exe'
$LiveKitConfig = Join-Path $AppDir 'livekit\livekit.yaml'
$NodeServiceName = 'TangoTalkServer'
# PostgreSQL 전용 포트(Setup-TangoTalkServer.ps1의 $PgPort) — 웹 포트로 고르면 둘 중 하나가 뜨지 못하므로 겹치는지만 본다.
$PgPort = 55432
$Title = 'TangoTalk 웹 앱 주소(정식 인증서)'
# 시험 발급(Let's Encrypt 스테이징)을 켤 때 .env의 ACME_STAGING에 쓰는 값. 읽을 때는 1/true/yes/on을 모두 켜짐으로 본다.
$StagingOnValue = '1'
$EnvComment = '# Web-Domain.ps1이 지정한 웹 앱 주소(아이폰용 — 서버가 Let''s Encrypt 정식 인증서를 자동으로 받음, WEB_DOMAIN을 비우면 꺼짐)'

# ── .env 읽기/쓰기 ───────────────────────────────────────────────────────
# .env를 줄 단위로 읽는다. 설치 프로그램(Set-Content -Encoding utf8)과 "첨부파일 저장소"는 BOM 있는 UTF-8로, "외부 접속 주소"와 이
# 스크립트는 BOM 없는 UTF-8로 쓰고, 손으로 고친 파일은 예전 메모장의 ANSI(한글 Windows는 CP949)일 수도 있다. Get-Content는 BOM이
# 없으면 ANSI로 읽어서(Windows PowerShell 5.1) BOM 없는 UTF-8의 한글 주석을 깨진 채로 다시 쓰게 되므로 쓰지 않는다 — BOM이 있으면
# 그 인코딩으로(ReadAllText가 BOM을 떼어 준다), 없으면 엄격한 UTF-8로 읽고, UTF-8이 아닐 때만 시스템 기본 코드 페이지로 읽는다.
function Read-EnvLines {
    if (-not (Test-Path -LiteralPath $EnvFile)) { return }
    try {
        $text = [System.IO.File]::ReadAllText($EnvFile, (New-Object System.Text.UTF8Encoding($false, $true)))
    } catch {
        $text = [System.IO.File]::ReadAllText($EnvFile, [System.Text.Encoding]::Default)
    }
    $lines = @($text -split '\r?\n')
    # 마지막 줄바꿈 뒤의 빈 조각은 줄이 아니다(다시 쓸 때 WriteAllLines가 줄마다 줄바꿈을 붙인다).
    $count = $lines.Count
    if ($count -gt 0 -and $lines[$count - 1] -eq '') { $count-- }
    for ($i = 0; $i -lt $count; $i++) { $lines[$i] }
}

# dotenv와 같은 규칙으로 값 하나를 읽는다 — 같은 이름이 여러 번 있으면 마지막 줄, 따옴표로 감싼 값은 따옴표를 떼고, 따옴표 없는 값은
# # 부터(주석) 버린다. 없으면 ''.
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

# 이름=값 여러 개를 .env에 반영한다(External-Address.ps1의 Set-ExternalAddressInEnv와 같은 방식) — 다른 줄(주석·빈 줄·다른 설정)은
# 글자 그대로 두고, 그 이름의 줄은 전부 새 값으로 바꾸고, 없던 이름은 설명 주석 한 줄과 함께 끝에 붙인다.
# BOM 없는 UTF-8로 쓴다(External-Address.ps1과 같게) — 지금 서버의 dotenv는 첫 줄 앞의 BOM을 공백으로 보고 넘기지만, BOM을 키 이름의
# 글자로 읽는 도구도 있어 굳이 붙이지 않는다(PowerShell 5.1의 Set-Content -Encoding utf8은 BOM을 붙이므로 쓰지 않는다). 읽을 때 ANSI였던
# 파일도 UTF-8로 바뀌어, dotenv가 한글 값(예: UPLOADS_DIR의 한글 폴더 이름)을 바로 읽는다.
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

# ── 입력 검증 ────────────────────────────────────────────────────────────
# 도메인 칸의 값을 Let's Encrypt가 받아 주는 호스트 이름 하나로 정리한다 — 틀리면 이유를 담아 예외, 비어 있으면 ''(끄기).
# 주소창에서 복사한 값도 되게 앞의 https://와 뒤의 경로·끝 점은 떼고, 한글 도메인은 퓨니코드(xn--)로 바꾼다. 포트는 칸을 따로 받으므로
# 붙어 있으면 거절하고, IP 주소와 인터넷에 없는 이름(점 없는 컴퓨터 이름, .local 같은 사내 전용 이름)은 공인 인증서를 받을 수 없어
# 거절한다 — 그런 값을 .env에 넣으면 서버가 Let's Encrypt에 헛된 요청만 되풀이한다(실패도 한도에 잡힌다).
function ConvertTo-WebDomain {
    param([string]$Raw)
    $value = ("$Raw".Trim() -replace '^https?://', '' -replace '[/?#].*$', '').TrimEnd('.')
    if (-not $value) { return '' }
    if ($value -match '^\[|:.*:') { throw "IP 주소로는 정식 인증서를 받을 수 없습니다 — 공유기 DDNS 도메인(예: xxx.iptime.org)을 넣으세요: $Raw" }
    if ($value -match ':') { throw "포트는 도메인 칸에 붙이지 말고 '웹 HTTPS 포트' 칸에 따로 적으세요: $Raw" }
    if ($value -match '[^\x00-\x7F]') {
        try {
            $value = (New-Object System.Globalization.IdnMapping).GetAscii($value)
        } catch {
            throw "도메인 형식이 올바르지 않습니다: $Raw"
        }
    }
    $value = $value.ToLowerInvariant()
    if ($value -match '^[0-9.]+$') { throw "IP 주소로는 정식 인증서를 받을 수 없습니다 — 공유기 DDNS 도메인(예: xxx.iptime.org)을 넣으세요: $Raw" }
    if ($value -notmatch '\.') { throw "점(.)이 없는 이름은 인터넷에서 찾을 수 없어 정식 인증서를 받을 수 없습니다 — 예: xxx.iptime.org: $Raw" }
    $label = '[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
    if ($value.Length -gt 253 -or $value -notmatch "^$label(\.$label)+$") {
        throw "도메인 형식이 올바르지 않습니다(영문·숫자·하이픈을 점으로 이은 이름 — 예: xxx.iptime.org): $Raw"
    }
    $tld = $value.Substring($value.LastIndexOf('.') + 1)
    $internalTlds = @('local', 'localhost', 'localdomain', 'lan', 'home', 'internal', 'intranet', 'corp', 'private', 'test', 'example', 'invalid', 'arpa', 'onion')
    if ($tld -notmatch '^([a-z]{2,63}|xn--[a-z0-9-]{1,59})$' -or $internalTlds -contains $tld) {
        throw "인터넷에서 찾을 수 없는 사내 전용 이름이라 정식 인증서를 받을 수 없습니다: $Raw"
    }
    return $value
}

# 포트 칸 값 → 정수. 0은 -AllowZero일 때만(인증용 HTTP 포트를 안 쓰는 경우). 틀리면 이유를 담아 예외.
function ConvertTo-PortNumber {
    param([string]$Raw, [string]$Label, [switch]$AllowZero)
    $text = "$Raw".Trim()
    $range = if ($AllowZero) { '0~65535, 안 쓰면 0' } else { '1~65535' }
    if ($text -notmatch '^\d{1,5}$') { throw "$Label 칸에는 숫자($range)를 적으세요: $Raw" }
    $port = [int]$text
    if ($port -gt 65535 -or ($port -eq 0 -and -not $AllowZero)) { throw "$Label 이(가) 올바르지 않습니다($range): $Raw" }
    return $port
}

# 메인 포트(PC·안드로이드 앱이 쓰는 PORT) — 서버와 같은 기본값 3000(server/src/config.js).
function Get-MainPort {
    param([string[]]$Lines)
    $value = Get-EnvValue -Name 'PORT' -Lines $Lines
    if ($value -match '^\d{1,5}$' -and [int]$value -gt 0) { return [int]$value }
    return 3000
}

# 이 서버가 이미 쓰는 TCP 포트(설명 → 번호) — 웹 포트·인증용 포트가 이 중 하나와 같으면 둘 중 하나가 뜨지 못한다. 서버와 같은
# 기본값을 쓴다(config.js: PAIRING_PORT는 PORT+1, LiveKit은 livekit.yaml의 port·rtc.tcp_port — 없으면 7880·7881).
function Get-ReservedPorts {
    param([string[]]$Lines)
    $main = Get-MainPort -Lines $Lines
    $pairing = $main + 1
    $value = Get-EnvValue -Name 'PAIRING_PORT' -Lines $Lines
    if ($value -match '^\d{1,5}$' -and [int]$value -gt 0) { $pairing = [int]$value }
    $signal = 7880
    $mediaTcp = 7881
    if (Test-Path -LiteralPath $LiveKitConfig) {
        $yaml = [System.IO.File]::ReadAllText($LiveKitConfig)
        if ($yaml -match '(?m)^port:\s*(\d+)') { $signal = [int]$Matches[1] }
        if ($yaml -match '(?m)^\s+tcp_port:\s*(\d+)') { $mediaTcp = [int]$Matches[1] }
    }
    return [ordered]@{
        '메인 포트(PORT — PC·안드로이드 앱)' = $main
        '페어링 포트(PAIRING_PORT)'          = $pairing
        '화상회의 신호 포트(LiveKit)'         = $signal
        '화상회의 미디어 TCP 포트(LiveKit)'   = $mediaTcp
        'PostgreSQL 포트'                    = $PgPort
    }
}

# 창에 넣은 값 → 적용할 설정. 틀리면 이유를 담아 예외. 도메인을 비우면 Domain이 ''(끄기)이고 나머지 칸은 보지 않는다.
function Get-WebSettings {
    param([string]$DomainText, [string]$WebPortText, [string]$AcmePortText, [string]$EmailText, [bool]$Staging, [string[]]$Lines)
    $domain = ConvertTo-WebDomain -Raw $DomainText
    if (-not $domain) { return [pscustomobject]@{ Domain = ''; WebPort = 0; AcmePort = 0; Email = ''; Staging = $false } }
    $webPort = ConvertTo-PortNumber -Raw $WebPortText -Label '웹 HTTPS 포트'
    $acmePort = ConvertTo-PortNumber -Raw $AcmePortText -Label '인증용 HTTP 포트' -AllowZero
    if ($acmePort -eq $webPort) { throw '웹 HTTPS 포트와 인증용 HTTP 포트는 서로 달라야 합니다.' }
    $reserved = Get-ReservedPorts -Lines $Lines
    foreach ($check in @(@{ Label = '웹 HTTPS 포트'; Port = $webPort }, @{ Label = '인증용 HTTP 포트'; Port = $acmePort })) {
        foreach ($name in $reserved.Keys) {
            if ($check.Port -gt 0 -and $check.Port -eq $reserved[$name]) {
                throw "$($check.Label) $($check.Port)은(는) 이 서버의 $($name)와(과) 겹칩니다 — 다른 번호를 고르세요."
            }
        }
    }
    # 서버(server/src/webTlsConfig.js의 parseAcmeEmail)보다 좁게 받는다 — 서버가 거르는 값을 쓰면 서버는 이메일 없이 진행해 버린다.
    $email = "$EmailText".Trim()
    if ($email -and $email -notmatch '^[A-Za-z0-9._%+-]+@([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$') {
        throw "이메일 형식이 올바르지 않습니다(비워 둬도 됩니다): $email"
    }
    return [pscustomobject]@{ Domain = $domain; WebPort = $webPort; AcmePort = $acmePort; Email = $email; Staging = $Staging }
}

# 지금 .env에 들어 있는 설정 — 포트 값이 없으면 서버와 같은 기본값(웹 443, 인증용 80)으로 본다.
function Get-CurrentWebSettings {
    param([string[]]$Lines)
    $web = Get-EnvValue -Name 'WEB_HTTPS_PORT' -Lines $Lines
    $acme = Get-EnvValue -Name 'ACME_HTTP_PORT' -Lines $Lines
    return [pscustomobject]@{
        Domain   = (Get-EnvValue -Name 'WEB_DOMAIN' -Lines $Lines).ToLowerInvariant()
        WebPort  = $(if ($web -match '^\d{1,5}$') { [int]$web } else { 443 })
        AcmePort = $(if ($acme -match '^\d{1,5}$') { [int]$acme } else { 80 })
        Email    = Get-EnvValue -Name 'ACME_EMAIL' -Lines $Lines
        Staging  = ((Get-EnvValue -Name 'ACME_STAGING' -Lines $Lines) -match '^(1|true|yes|on)$')
    }
}

# 적용할 설정 → .env에 쓸 이름=값. 시험 발급은 켤 때만 새 줄을 적고, 끌 때는 이미 있는 줄만 비운다 — 한 번도 안 쓴 서버의 .env에
# 쓸데없는 줄을 늘리지 않게. 도메인이 비었으면(끄기) WEB_DOMAIN만 비운다 — 포트·이메일은 남겨 두어 다시 켤 때 그대로 쓴다(서버는
# WEB_DOMAIN이 비면 나머지 값을 보지 않는다 — server/src/webTlsConfig.js).
function Get-EnvValuesForSettings {
    param($Settings, [string[]]$Lines)
    if (-not $Settings.Domain) { return [ordered]@{ WEB_DOMAIN = '' } }
    $values = [ordered]@{
        WEB_DOMAIN     = $Settings.Domain
        WEB_HTTPS_PORT = "$($Settings.WebPort)"
        ACME_HTTP_PORT = "$($Settings.AcmePort)"
        ACME_EMAIL     = $Settings.Email
    }
    if ($Settings.Staging) {
        $values['ACME_STAGING'] = $StagingOnValue
    } elseif (Get-EnvValue -Name 'ACME_STAGING' -Lines $Lines) {
        $values['ACME_STAGING'] = ''
    }
    return $values
}

function Test-SameWebSettings {
    param($A, $B)
    return ($A.Domain -eq $B.Domain) -and ($A.WebPort -eq $B.WebPort) -and ($A.AcmePort -eq $B.AcmePort) -and
        ($A.Email -eq $B.Email) -and ([bool]$A.Staging -eq [bool]$B.Staging)
}

# 아이폰 사용자가 여는 주소 — 서버가 초대 안내 페이지 등에 알려 주는 주소(server/src/webAddress.js)와 같은 모양(443이면 포트 생략).
function Get-WebUrl {
    param($Settings)
    if ($Settings.WebPort -eq 443) { return "https://$($Settings.Domain)" }
    return "https://$($Settings.Domain):$($Settings.WebPort)"
}

# ── 방화벽·포트·DNS ──────────────────────────────────────────────────────
# 웹 앱 주소(정식 인증서)용 방화벽 규칙을 이름으로 지우고, 포트가 0이 아니면 다시 만든다. Setup-TangoTalkServer.ps1에도 똑같이 들어
# 있다 — 고치면 둘 다 고치고 tests\Web-Domain.Tests.ps1을 돌릴 것(둘이 같은지도 본다). 이 규칙 이름은 messenger-server.iss의
# [UninstallRun](일반 제거)도 지운다.
# - 지운 뒤 다시 만든다 — netsh는 같은 이름의 규칙을 여러 개 만들 수 있어서, 포트를 바꿔 다시 실행해도 규칙이 하나만 남게.
# - 메인·페어링 규칙은 포트만 보지만, 이 둘은 IIS 같은 다른 프로그램도 흔히 쓰는 443·80이라 이 서버의 node.exe로만 좁힌다 — 나중에
#   이 PC에 웹 서버가 깔려도 이 규칙 때문에 그 서버가 밖에 열리지 않게.
function Set-WebFirewallRules {
    param([int]$WebPort, [int]$AcmePort)
    foreach ($rule in @(
            @{ Name = 'TangoTalk Server (web)'; Port = $WebPort },
            @{ Name = 'TangoTalk Server (web-acme)'; Port = $AcmePort }
        )) {
        netsh advfirewall firewall delete rule name="$($rule.Name)" | Out-Null
        if ($rule.Port -gt 0) {
            netsh advfirewall firewall add rule name="$($rule.Name)" dir=in action=allow protocol=TCP localport=$($rule.Port) program="$NodeExe" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "방화벽 규칙($($rule.Name), TCP $($rule.Port))을 만들지 못했습니다(netsh 종료 코드 $LASTEXITCODE)." }
        }
    }
}

# 그 포트에서 이미 연결을 기다리는(Listen) 다른 프로그램의 설명 — 없거나 이 서버(node.exe)면 $null. 443·80은 IIS 같은 Windows의
# HTTP 서비스(HTTP.sys — 프로세스는 System, PID 4)가 흔히 쓰는데, 그러면 서버가 그 포트를 열지 못해 웹 앱도 인증서 발급도 안 된다.
function Get-PortUser {
    param([int]$Port)
    try {
        $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    } catch {
        # 확인 자체를 못 하면(드물게 NetTCPIP 모듈을 못 읽는 PC) 막지 않는다 — 경고용 확인일 뿐이다.
        return $null
    }
    foreach ($listener in $listeners) {
        $owner = [int]$listener.OwningProcess
        if ($owner -eq 4) { return 'Windows HTTP 서비스(HTTP.sys — IIS·웹 배포 서비스 등, 프로세스 System)' }
        $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $owner" -ErrorAction SilentlyContinue
        if ($process -and $process.ExecutablePath -and ($process.ExecutablePath -ieq $NodeExe)) { continue }
        if ($process) { return "$($process.Name) (PID $owner)" }
        return "PID $owner"
    }
    return $null
}

# 도메인이 지금 가리키는 IP 목록(이 PC가 쓰는 DNS로 찾음) — 못 찾으면 아무것도 돌려주지 않는다. Let's Encrypt는 인터넷에서 이 이름으로
# 공유기에 접속해 확인하므로, 못 찾거나 사설 IP만 나오면 발급이 실패한다(오타·DDNS 꺼짐을 적용 전에 알려 주려고).
function Resolve-WebDomain {
    param([string]$Domain)
    try {
        [System.Net.Dns]::GetHostAddresses($Domain) | ForEach-Object { $_.IPAddressToString }
    } catch {
        return
    }
}

# 사설·사내 전용 주소인지(10/8, 172.16/12, 192.168/16, 루프백, 링크 로컬, 통신사 공유 IP 100.64/10, IPv6 루프백·ULA·링크 로컬).
function Test-PrivateAddress {
    param([string]$Address)
    return ($Address -match '^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)') -or
        ($Address -match '^(::1$|f[cd][0-9a-f]{2}:|fe[89ab][0-9a-f]:)')
}

# 적용하기 전에 확인할 것(문장 목록) — 이 PC의 다른 프로그램이 쓰는 포트, DNS에서 찾을 수 없거나 사설 IP만 가리키는 도메인.
# 어느 것도 막지는 않는다(사내 DNS가 따로 있는 회사 등 오판할 수 있어서) — 운영자에게 보여 주고 계속할지 묻는다.
function Get-ApplyWarnings {
    param($Settings)
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($check in @(@{ Label = '웹 HTTPS 포트'; Port = $Settings.WebPort }, @{ Label = '인증용 HTTP 포트'; Port = $Settings.AcmePort })) {
        if ($check.Port -le 0) { continue }
        $user = Get-PortUser -Port $check.Port
        if ($user) {
            $warnings.Add("$($check.Label) $($check.Port)을(를) 이 PC의 다른 프로그램이 쓰고 있습니다: $user — 그대로면 서버가 이 포트를 " +
                '열지 못합니다. 그 프로그램을 끄거나, 다른 번호(예: 8443·8080)를 고르고 공유기에서 외부 443·80을 그 번호로 연결하세요.')
        }
    }
    $addresses = @(Resolve-WebDomain -Domain $Settings.Domain)
    if ($addresses.Count -eq 0) {
        $warnings.Add("$($Settings.Domain)을(를) DNS에서 찾을 수 없습니다 — 철자와 공유기의 DDNS 설정을 확인하세요. Let's Encrypt가 이 " +
            '이름으로 공유기에 접속하지 못하면 인증서를 받을 수 없습니다.')
    } elseif (@($addresses | Where-Object { -not (Test-PrivateAddress -Address $_) }).Count -eq 0) {
        $warnings.Add("$($Settings.Domain)이(가) 사설 IP($($addresses -join ', '))를 가리킵니다 — Let's Encrypt는 인터넷에서 이 이름으로 " +
            '접속해 확인하므로 공유기의 공인 IP를 가리켜야 합니다.')
    }
    return $warnings.ToArray()
}

# 공유기에서 포워딩할 대상 — 기본 게이트웨이가 있는(공유기에 연결된) 랜 카드의 IPv4. 못 찾으면 ''.
function Get-LanAddress {
    try {
        $config = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' }) |
            Select-Object -First 1
        if ($config) {
            $address = @($config.IPv4Address) | Select-Object -First 1
            if ($address) { return $address.IPAddress }
        }
    } catch {
    }
    return ''
}

# 서버를 다시 시작하고 그 뒤 서비스 상태를 돌려준다 — 콘솔 모드로 설치해 서비스가 없으면 ''(그 콘솔 창을 닫았다가 다시 열어야 바뀐
# .env를 읽는다).
function Restart-NodeService {
    $service = Get-Service -Name $NodeServiceName -ErrorAction SilentlyContinue
    if (-not $service) { return '' }
    if (Test-Path -LiteralPath $NssmExe) {
        & $NssmExe restart $NodeServiceName | Out-Null
    } else {
        Restart-Service -Name $NodeServiceName -Force -ErrorAction Stop
    }
    Start-Sleep -Seconds 2
    $service.Refresh()
    return "$($service.Status)"
}

# ── 안내 문구 ────────────────────────────────────────────────────────────
function Get-RestartText {
    param([string]$Status, [string]$Done)
    if (-not $Status) {
        return "$Done 서버를 콘솔 창으로 실행 중이면 그 창을 닫았다가 시작 메뉴 ""서버 콘솔로 실행""으로 다시 여세요 — 그래야 바뀐 설정을 읽습니다."
    }
    if ($Status -eq 'Running') { return "$Done 서버를 다시 시작했습니다." }
    return "$Done 서버를 다시 시작했지만 지금 상태가 '$Status'입니다 — 시작 메뉴 ""서버 재시작""으로 다시 시작해 보고, 계속 안 되면 그 " +
        '창에서 오류 기록(service-err.log)을 확인하세요.'
}

# 적용한 뒤 보여 줄 안내(복사할 수 있게 글 상자에 넣는다) — 공유기 포트포워딩, 인증서 발급, iptime.org 주간 한도, 아이폰에서 여는 법.
# Let's Encrypt의 발급 확인은 늘 밖의 443(TLS-ALPN-01)·80(HTTP-01)으로 오므로 그 둘을 이 PC의 웹 포트·인증용 포트로 보내야 하고,
# 웹 포트가 443이 아니면 서버가 알려 주는 주소(webAddress.js)에 그 번호가 붙으므로 밖에서도 같은 번호를 열어야 한다.
# iptime.org는 공개 접미사 목록(PSL)에 없어서 Let's Encrypt가 그 아래 이름을 모두 도메인 하나로 센다 — "등록 도메인당 7일에 새
# 인증서 50개" 한도를 모든 iptime DDNS 사용자가 함께 써서 첫 발급이 한도 초과(rateLimited)로 실패할 수 있다(갱신은 예외).
function Get-WebGuideText {
    param($Settings, [string]$LanIp)
    $pc = if ($LanIp) { "이 PC($LanIp)" } else { '이 PC' }
    $url = Get-WebUrl -Settings $Settings
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('1) 공유기 포트포워딩 — iptime이면 관리 화면의 고급 설정 → NAT/라우터 관리 → 포트포워드 설정')
    $lines.Add("   - 외부 TCP 443 → $pc TCP $($Settings.WebPort): 웹 앱과 인증서 발급 확인(TLS-ALPN)")
    if ($Settings.WebPort -ne 443) {
        $lines.Add("   - 외부 TCP $($Settings.WebPort) → $pc TCP $($Settings.WebPort): 웹 앱 주소가 $url 이라 같은 번호도 엽니다")
    }
    if ($Settings.AcmePort -gt 0) {
        $lines.Add("   - 외부 TCP 80 → $pc TCP $($Settings.AcmePort): 인증서 발급 확인(HTTP) — 통신사가 80을 막으면 443으로 확인합니다")
    } else {
        $lines.Add('   - 인증용 HTTP 포트가 0이라 인증서 발급은 밖의 443으로만 확인합니다 — 위 443 포워딩이 꼭 있어야 합니다')
    }
    # 서버는 실패한 뒤 다음 시도 시각을 certs\acme-state.json에 남겨 두고, 재시작해도 그 전에는 Let's Encrypt에 다시 묻지 않는다
    # (도메인이나 시험 발급 설정이 바뀔 때만 새로 시작 — server/src/acmeRenewal.js). 포트포워딩을 고친 뒤 "왜 바로 안 받지?"가 되지
    # 않게 그 규칙을 알려 준다.
    $n = 2
    $lines.Add('')
    if ($Settings.Staging) {
        $lines.Add("$n) 시험 발급(스테이징) 중입니다 — 받는 인증서는 브라우저가 믿지 않는 시험용이라 아이폰에서는 아직 쓸 수 없습니다. " +
            '1~2분 뒤 [인증서 확인]에 시험용 인증서가 보이면 포트포워딩이 맞는 것이니, "시험 발급"을 끄고 다시 [적용]하세요(그러면 바로 ' +
            '정식 인증서를 받으러 갑니다). 실패 이유는 앱의 관리자 콘솔에서 볼 수 있습니다.')
    } else {
        $lines.Add("$n) 인증서는 서버가 Let's Encrypt에서 자동으로 받고 만료 전에 알아서 갱신합니다. 1~2분 뒤 이 창의 [인증서 확인]이나 " +
            '앱의 관리자 콘솔에서 확인하세요. 실패하면 서버가 간격을 두고(1시간부터 점점 늘려 최대 하루) 알아서 다시 시도합니다 — ' +
            '서버를 다시 시작해도 그 시각 전에는 다시 묻지 않으니, 실패 이유와 다음 시도 시각은 관리자 콘솔에서 보세요.')
    }
    if ($Settings.Domain -match '(^|\.)iptime\.org$') {
        $n++
        $lines.Add('')
        $lines.Add("$n) iptime.org 주의: Let's Encrypt는 iptime.org 아래 이름을 모두 도메인 하나로 세서, 모든 iptime DDNS 사용자가 " +
            '"같은 도메인 7일에 새 인증서 50개" 한도를 함께 씁니다. 그래서 처음 발급이 한도 초과(rateLimited)로 실패할 수 있습니다 — ' +
            '그러면 서버가 Let''s Encrypt가 알려 준 시각(몇 시간~며칠 뒤)에 알아서 다시 시도하니 기다리거나, 회사 도메인을 사서 하위 ' +
            "이름(예: chat.회사도메인)을 CNAME으로 $($Settings.Domain)에 연결한 뒤 그 이름을 여기에 넣으세요(도메인을 바꾸면 바로 다시 " +
            '시도합니다). 한 번 받은 인증서의 갱신은 이 한도에 걸리지 않습니다.')
    }
    $n++
    $lines.Add('')
    $lines.Add("$n) 아이폰 사용자: 사파리에서 $url 을 열어 로그인한 뒤 공유 버튼 → ""홈 화면에 추가""를 누르면 앱처럼 쓸 수 있습니다. " +
        '알림(웹 푸시)은 홈 화면에 추가한 아이콘으로 연 앱에서 켤 수 있습니다(iOS 16.4 이상).')
    $lines.Add('')
    $lines.Add('PC·안드로이드 앱은 지금처럼 메인 포트로 접속하므로 다시 페어링할 필요가 없습니다.')
    return ($lines -join "`r`n")
}

# ── 인증서 확인 ──────────────────────────────────────────────────────────
# 이 PC의 웹 포트에 직접(127.0.0.1) 붙어 지금 걸린 인증서를 읽는다 — 공유기·DNS를 거치지 않으므로 "서버가 인증서를 받아 걸었는지"만
# 알 수 있다(밖에서 열리는지는 포트포워딩에 달려 있다). 서버가 도메인에 맞는 인증서를 고를 수 있게 SNI로 도메인을 보낸다.
# 판정은 Windows에 맡기고(오류 종류가 None이면 이 PC가 믿는 공인 인증서이고 이름도 맞음) 연결은 늘 받아들인다 — 자체 서명·시험용
# 인증서여도 무엇이 걸려 있는지 보여 주려고. 콜백은 AuthenticateAsClient 안에서 이 스레드로 불리므로 스크립트 블록으로 충분하다.
function Get-WebCertificateStatus {
    param([string]$Domain, [int]$Port, [int]$TimeoutMs = 5000)
    $status = [ordered]@{ Reachable = $false; Trusted = $false; Staging = $false; Subject = ''; Issuer = ''; NotAfter = $null; Error = '' }
    $seen = @{}
    $tcp = New-Object System.Net.Sockets.TcpClient
    $ssl = $null
    try {
        $connect = $tcp.BeginConnect([System.Net.IPAddress]::Loopback, $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw "연결 시간($([int]($TimeoutMs / 1000))초)이 지났습니다." }
        $tcp.EndConnect($connect)
        $status.Reachable = $true
        $callback = [System.Net.Security.RemoteCertificateValidationCallback] {
            param($source, $certificate, $chain, $policyErrors)
            if ($certificate) { $seen.Raw = $certificate.GetRawCertData() }
            $seen.Errors = $policyErrors
            return $true
        }
        $ssl = New-Object System.Net.Security.SslStream -ArgumentList $tcp.GetStream(), $false, $callback
        $ssl.ReadTimeout = $TimeoutMs
        $ssl.WriteTimeout = $TimeoutMs
        # 프로토콜은 Windows 기본값에 맡긴다(None — .NET 4.7+): 서버(Node 24)가 도는 Windows 10/Server 2016 이상은 기본값에 TLS 1.2가
        # 들어 있고, Windows 11이면 1.3도 쓴다. 버전을 박아 두면 서버가 나중에 1.3만 받게 바뀔 때 "인증서 없음"으로 잘못 보인다.
        $ssl.AuthenticateAsClient($Domain, $null, [System.Security.Authentication.SslProtocols]::None, $false)
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        $status.Error = $e.Message
    } finally {
        if ($ssl) { $ssl.Dispose() }
        $tcp.Close()
    }
    if ($seen.Raw) {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, [byte[]]$seen.Raw)
        $status.Subject = $cert.Subject
        $status.Issuer = $cert.Issuer
        $status.NotAfter = $cert.NotAfter
        $status.Trusted = ($seen.Errors -eq [System.Net.Security.SslPolicyErrors]::None)
        # Let's Encrypt 스테이징의 발급자 이름에는 "(STAGING)"이 붙는다(예: CN=(STAGING) Pretend Pear X1).
        $status.Staging = ($cert.Issuer -match '\(STAGING\)')
    }
    return [pscustomobject]$status
}

function Get-WebCertificateStatusText {
    param($Status, $Settings)
    $url = Get-WebUrl -Settings $Settings
    if (-not $Status.Reachable) {
        return "이 PC의 웹 HTTPS 포트($($Settings.WebPort))에서 응답이 없습니다 — 서버가 아직 시작 중이거나 이 포트를 열지 못했습니다(다른 " +
            '프로그램이 이 포트를 쓰는 경우 등). 잠시 뒤 다시 확인하고, 계속 이러면 앱의 관리자 콘솔이나 서버 오류 기록(시작 메뉴 "서버 ' +
            '재시작"에서 service-err.log)을 확인하세요.'
    }
    if (-not $Status.Issuer) {
        return "이 PC의 웹 HTTPS 포트($($Settings.WebPort))는 열려 있지만 인증서를 받아 오지 못했습니다($($Status.Error)) — 서버가 아직 " +
            '인증서를 받는 중일 수 있습니다. 잠시 뒤 다시 확인하고, 앱의 관리자 콘솔에서 발급 상태(실패 이유·다음 시도 시각)를 보세요.'
    }
    $until = $Status.NotAfter.ToString('yyyy-MM-dd')
    if ($Status.Trusted) {
        return "정식 인증서가 걸려 있습니다 — 발급자: $($Status.Issuer), $until 까지(그 전에 서버가 자동으로 갱신합니다).`r`n`r`n" +
            "아이폰에서 사파리로 $url 을 열어 보세요(밖에서 열리는지는 공유기 포트포워딩에 달려 있습니다)."
    }
    if ($Status.Staging) {
        return "시험용(스테이징) 인증서가 걸려 있습니다 — 발급자: $($Status.Issuer).`r`n`r`n공유기 포트포워딩과 발급 과정은 정상입니다. " +
            '"시험 발급"을 끄고 다시 [적용]하면 정식 인증서를 받습니다.'
    }
    $expired = if ($Status.NotAfter -lt (Get-Date)) { ", $until 에 만료됨" } else { '' }
    return "아직 정식 인증서가 아닙니다 — 지금 인증서: $($Status.Subject), 발급자: $($Status.Issuer)$expired.`r`n`r`n" +
        '서버가 인증서를 받는 중이거나 받지 못했습니다. 앱의 관리자 콘솔에서 실패 이유(공유기 포트포워딩, iptime.org 주간 한도 등)와 ' +
        '다음 시도 시각을 확인하세요.'
}

# ── 창 구성 ──────────────────────────────────────────────────────────────
$envLines = @(Read-EnvLines)
$current = Get-CurrentWebSettings -Lines $envLines
$mainPort = Get-MainPort -Lines $envLines

# 아직 켠 적이 없으면 "외부 접속 주소"(EXTERNAL_ADDRESS)에 넣어 둔 DDNS 도메인을 미리 채워 둔다 — 보통 같은 이름을 쓴다(IP면 건너뜀).
$domainText = $current.Domain
$suggested = $false
if (-not $domainText) {
    $external = (Get-EnvValue -Name 'EXTERNAL_ADDRESS' -Lines $envLines) -replace '^https?://', '' -replace '[/?#].*$', '' -replace ':\d+$', ''
    try {
        $domainText = ConvertTo-WebDomain -Raw $external
        $suggested = [bool]$domainText
    } catch {
        $domainText = ''
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = $Title
$form.ClientSize = New-Object System.Drawing.Size(560, 574)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

function Add-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 20, [switch]$Gray)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    if ($Gray) { $label.ForeColor = [System.Drawing.Color]::Gray }
    $form.Controls.Add($label)
    return $label
}

function Add-TextBox {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Text = $Text
    $box.Location = New-Object System.Drawing.Point($X, $Y)
    $box.Size = New-Object System.Drawing.Size($Width, 24)
    $form.Controls.Add($box)
    return $box
}

function Add-Button {
    param([string]$Text, [int]$X, [int]$Width)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, 532)
    $button.Size = New-Object System.Drawing.Size($Width, 30)
    $form.Controls.Add($button)
    return $button
}

[void](Add-Label -X 15 -Y 12 -Width 530 -Height 82 -Text (
        "아이폰은 앱 대신 사파리로 웹 앱을 씁니다. 사파리에서 경고 없이 열고 홈 화면에 추가해 알림까지 받으려면 공인 인증서가 " +
        "필요해서, 여기에 도메인(공유기 DDNS 이름 등)을 넣으면 서버가 Let's Encrypt 인증서를 스스로 받고 갱신해 웹 전용 HTTPS 포트로 " +
        "웹 앱을 엽니다. PC·안드로이드 앱은 지금처럼 메인 포트($mainPort)와 기존 인증서를 그대로 씁니다(다시 페어링할 필요 없음)."))

[void](Add-Label -X 15 -Y 103 -Width 130 -Text '도메인')
$domainBox = Add-TextBox -X 150 -Y 100 -Width 395 -Text $domainText
[void](Add-Label -X 150 -Y 127 -Width 395 -Gray -Text '예: xxx.iptime.org(공유기 DDNS 이름) — 비우고 [적용]하면 끕니다')

[void](Add-Label -X 15 -Y 155 -Width 130 -Text '웹 HTTPS 포트')
$webPortBox = Add-TextBox -X 150 -Y 152 -Width 70 -Text "$($current.WebPort)"
[void](Add-Label -X 228 -Y 155 -Width 317 -Gray -Text '기본 443(IIS 등이 쓰고 있으면 예: 8443)')

[void](Add-Label -X 15 -Y 185 -Width 130 -Text '인증용 HTTP 포트')
$acmePortBox = Add-TextBox -X 150 -Y 182 -Width 70 -Text "$($current.AcmePort)"
[void](Add-Label -X 228 -Y 185 -Width 317 -Gray -Text '기본 80, 0 = 안 씀(밖의 443으로만 확인)')

[void](Add-Label -X 15 -Y 215 -Width 130 -Text '이메일(선택)')
$emailBox = Add-TextBox -X 150 -Y 212 -Width 220 -Text $current.Email
[void](Add-Label -X 378 -Y 215 -Width 167 -Gray -Text 'Let''s Encrypt 연락처')

$stagingBox = New-Object System.Windows.Forms.CheckBox
$stagingBox.Text = '시험 발급(Let''s Encrypt 스테이징) — 정식 발급 한도를 쓰지 않고 공유기 포트포워딩이 맞는지 먼저 확인할 때 씁니다. ' +
    '받는 인증서는 시험용이라 아이폰에서는 쓸 수 없습니다.'
$stagingBox.Location = New-Object System.Drawing.Point(15, 242)
$stagingBox.Size = New-Object System.Drawing.Size(530, 36)
$stagingBox.Checked = [bool]$current.Staging
$form.Controls.Add($stagingBox)

$stateLabel = Add-Label -X 15 -Y 284 -Width 530
$forwardHint = Add-Label -X 15 -Y 306 -Width 530 -Height 34 -Gray

$guideBox = New-Object System.Windows.Forms.TextBox
$guideBox.Location = New-Object System.Drawing.Point(15, 344)
$guideBox.Size = New-Object System.Drawing.Size(530, 178)
$guideBox.Multiline = $true
$guideBox.ScrollBars = 'Vertical'
$guideBox.ReadOnly = $true
$guideBox.BackColor = [System.Drawing.SystemColors]::Window
$form.Controls.Add($guideBox)

$checkButton = Add-Button -Text '인증서 확인' -X 15 -Width 110
$offButton = Add-Button -Text '끄기' -X 265 -Width 90
$applyButton = Add-Button -Text '적용' -X 360 -Width 90
$closeButton = Add-Button -Text '닫기' -X 455 -Width 90
$closeButton.Add_Click({ $form.Close() })

function Update-StateLabel {
    $now = Get-CurrentWebSettings -Lines @(Read-EnvLines)
    if ($now.Domain) {
        $stateLabel.ForeColor = [System.Drawing.Color]::Green
        $stateLabel.Text = "지금: 켜짐 — $(Get-WebUrl -Settings $now)$(if ($now.Staging) { ' (시험 발급 중)' })"
    } else {
        $stateLabel.ForeColor = [System.Drawing.Color]::Black
        $stateLabel.Text = '지금: 꺼짐 — 웹 앱용 정식 인증서를 쓰지 않습니다.'
    }
    $checkButton.Enabled = [bool]$now.Domain
}

function Update-ForwardHint {
    $web = "$($webPortBox.Text)".Trim()
    $acme = "$($acmePortBox.Text)".Trim()
    if ($web -notmatch '^\d{1,5}$') { $web = '?' }
    if ($acme -notmatch '^\d{1,5}$') { $acme = '?' }
    $text = "공유기에서 이 PC로 포워딩: 외부 TCP 443 → TCP $web"
    if ($web -ne '443' -and $web -ne '?') { $text += ", 외부 TCP $web → TCP $web" }
    if ($acme -ne '0') { $text += ", 외부 TCP 80 → TCP $acme" }
    $forwardHint.Text = "$text. 이 PC의 방화벽 규칙은 [적용]이 만들어 줍니다."
}

function Show-Guide {
    param([string]$Text, [System.Drawing.Color]$Color = [System.Drawing.Color]::Black)
    $guideBox.ForeColor = $Color
    $guideBox.Text = $Text
    $guideBox.SelectionStart = 0
    $guideBox.SelectionLength = 0
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Busy {
    param([bool]$Busy)
    foreach ($button in @($applyButton, $offButton, $checkButton, $closeButton)) { $button.Enabled = -not $Busy }
    $form.Cursor = if ($Busy) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
    if (-not $Busy) { Update-StateLabel }
    [System.Windows.Forms.Application]::DoEvents()
}

function Invoke-ApplySettings {
    param($Settings)
    Set-Busy $true
    try {
        Show-Guide -Text '설정 저장 중...'
        Set-EnvValues -Values (Get-EnvValuesForSettings -Settings $Settings -Lines @(Read-EnvLines)) -Comment $EnvComment
        # 칸에는 .env에 실제로 쓴 값(정리된 도메인·포트·이메일)을 다시 보여 준다.
        $domainBox.Text = $Settings.Domain
        $webPortBox.Text = "$($Settings.WebPort)"
        $acmePortBox.Text = "$($Settings.AcmePort)"
        $emailBox.Text = $Settings.Email

        Show-Guide -Text '이 PC의 방화벽 규칙 맞추는 중...'
        Set-WebFirewallRules -WebPort $Settings.WebPort -AcmePort $Settings.AcmePort

        Show-Guide -Text '서버 재시작 중...'
        $serviceStatus = Restart-NodeService
        $color = if ($serviceStatus -and $serviceStatus -ne 'Running') { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::Black }
        Show-Guide -Color $color -Text ((Get-RestartText -Status $serviceStatus -Done '적용했습니다.') + "`r`n`r`n" +
            (Get-WebGuideText -Settings $Settings -LanIp (Get-LanAddress)))
    } catch {
        Show-Guide -Color ([System.Drawing.Color]::Red) -Text ("오류: $($_.Exception.Message)`r`n`r`n" +
            '일부만 바뀌었을 수 있습니다 — 값을 확인하고 다시 [적용]하세요.')
    } finally {
        Set-Busy $false
    }
}

function Invoke-TurnOff {
    $now = Get-CurrentWebSettings -Lines @(Read-EnvLines)
    if (-not $now.Domain) {
        # 남아 있을지 모르는 규칙만 조용히 지운다(손으로 .env를 비운 경우 등).
        try { Set-WebFirewallRules -WebPort 0 -AcmePort 0 } catch { }
        $domainBox.Text = ''
        [System.Windows.Forms.MessageBox]::Show('웹 앱 주소는 이미 꺼져 있습니다.', $Title, 'OK', 'Information') | Out-Null
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "웹 앱 주소($(Get-WebUrl -Settings $now))를 끕니다.`n`n아이폰 등 웹 앱 사용자는 이 주소로 접속할 수 없게 되고, 이 PC의 방화벽 " +
        "규칙도 지웁니다. PC·안드로이드 앱은 그대로 접속됩니다.`n`n계속할까요?",
        $Title, 'YesNo', 'Warning', 'Button2'
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    Set-Busy $true
    try {
        Show-Guide -Text '설정 저장 중...'
        $off = [pscustomobject]@{ Domain = ''; WebPort = 0; AcmePort = 0; Email = ''; Staging = $false }
        Set-EnvValues -Values (Get-EnvValuesForSettings -Settings $off -Lines @(Read-EnvLines)) -Comment $EnvComment
        $domainBox.Text = ''
        Show-Guide -Text '이 PC의 방화벽 규칙 지우는 중...'
        Set-WebFirewallRules -WebPort 0 -AcmePort 0
        Show-Guide -Text '서버 재시작 중...'
        $serviceStatus = Restart-NodeService
        $color = if ($serviceStatus -and $serviceStatus -ne 'Running') { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::Black }
        Show-Guide -Color $color -Text ((Get-RestartText -Status $serviceStatus -Done '웹 앱 주소를 껐습니다.') + "`r`n`r`n" +
            '공유기의 포트포워딩(외부 443·80 → 이 PC)도 지우세요 — 열어 둘 이유가 없습니다. 서버가 받아 둔 인증서는 지우지 않아서, 같은 ' +
            '도메인으로 다시 켜면 그대로 씁니다.')
    } catch {
        Show-Guide -Color ([System.Drawing.Color]::Red) -Text "오류: $($_.Exception.Message)"
    } finally {
        Set-Busy $false
    }
}

$applyButton.Add_Click({
    try {
        $params = @{
            DomainText   = $domainBox.Text
            WebPortText  = $webPortBox.Text
            AcmePortText = $acmePortBox.Text
            EmailText    = $emailBox.Text
            Staging      = $stagingBox.Checked
            Lines        = @(Read-EnvLines)
        }
        $settings = Get-WebSettings @params
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '오류', 'OK', 'Error') | Out-Null
        return
    }
    if (-not $settings.Domain) {
        Invoke-TurnOff
        return
    }
    $now = Get-CurrentWebSettings -Lines @(Read-EnvLines)
    if (Test-SameWebSettings -A $now -B $settings) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "이미 이 설정으로 켜져 있습니다.`n`n이 PC의 방화벽 규칙을 다시 맞추고 서버를 다시 시작할까요?`n`n" +
            '(인증서 발급에 실패했었다면, 서버를 다시 시작해도 서버가 정해 둔 다음 시도 시각까지는 기다립니다 — 실패 이유와 다음 시도 ' +
            '시각은 앱의 관리자 콘솔에서 볼 수 있습니다.)',
            $Title, 'YesNo', 'Question'
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $warnings = @(Get-ApplyWarnings -Settings $settings)
    } catch {
        # 확인이 중간에 실패해도 창이 죽지 않게, 그 사실을 경고로 보여 주고 운영자가 고르게 한다.
        $warnings = @("적용 전 확인(포트 사용·DNS)을 끝내지 못했습니다: $($_.Exception.Message)")
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
    if ($warnings.Count -gt 0) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "적용하기 전에 확인할 것이 있습니다:`n`n- $($warnings -join "`n- ")`n`n그래도 적용할까요?",
            $Title, 'YesNo', 'Warning', 'Button2'
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    Invoke-ApplySettings -Settings $settings
})

$offButton.Add_Click({ Invoke-TurnOff })

$checkButton.Add_Click({
    $now = Get-CurrentWebSettings -Lines @(Read-EnvLines)
    if (-not $now.Domain) { return }
    Set-Busy $true
    try {
        Show-Guide -Text "이 PC의 웹 HTTPS 포트($($now.WebPort))에 걸린 인증서를 확인하는 중..."
        $status = Get-WebCertificateStatus -Domain $now.Domain -Port $now.WebPort
        $color = if ($status.Trusted) { [System.Drawing.Color]::Green } elseif ($status.Staging) { [System.Drawing.Color]::DarkGoldenrod } else { [System.Drawing.Color]::Firebrick }
        Show-Guide -Color $color -Text (Get-WebCertificateStatusText -Status $status -Settings $now)
    } catch {
        Show-Guide -Color ([System.Drawing.Color]::Red) -Text "오류: $($_.Exception.Message)"
    } finally {
        Set-Busy $false
    }
})

$webPortBox.Add_TextChanged({ Update-ForwardHint })
$acmePortBox.Add_TextChanged({ Update-ForwardHint })

Update-StateLabel
Update-ForwardHint
if ($current.Domain) {
    Show-Guide -Text (Get-WebGuideText -Settings $current -LanIp (Get-LanAddress))
} else {
    $intro = '도메인을 넣고 [적용]을 누르면 .env에 저장하고, 이 PC의 방화벽 규칙을 만들고, 서버를 다시 시작합니다. 그다음 공유기에서 ' +
        '포트포워딩을 하면 서버가 인증서를 받습니다(보통 1~2분 — [인증서 확인]이나 앱의 관리자 콘솔에서 확인).'
    if ($suggested) { $intro += "`r`n`r`n도메인 칸에는 ""외부 접속 주소""에 넣어 둔 이름을 미리 채워 두었습니다 — 아직 켜진 것은 아닙니다." }
    Show-Guide -Text $intro
}

[System.Windows.Forms.Application]::Run($form)
