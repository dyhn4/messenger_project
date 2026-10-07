<#
.SYNOPSIS
  "웹 앱 주소(정식 인증서)"(Web-Domain.ps1) 확인용 테스트 — 개발 PC 전용(설치 프로그램·업데이트 zip에는 안 들어감). 관리자 권한 없이
  돌고, %TEMP% 안에 만든 임시 폴더와 127.0.0.1의 임시 포트만 쓴다. 실제 .env·방화벽·서비스·인증서 저장소는 건드리지 않는다 — 설치용
  .ps1은 실행하지 않고 함수(와 상수 몇 개)만 꺼내 쓰고, netsh는 이 테스트 안의 가짜 함수로 바꿔 돌리며, 시험용 인증서는 메모리에서
  만들어 쓰고 버린다. 도메인 DNS 조회처럼 밖으로 나가는 요청은 하지 않는다(그 부분은 가짜 함수로 바꿔 판단만 본다).

.DESCRIPTION
  1) 구성: Web-Domain.ps1·Setup-TangoTalkServer.ps1의 Set-WebFirewallRules가 같은지(주석·들여쓰기 제외), Setup이 그 함수를 경고만
     남기는 try 안에서 부르는지와 .env의 WEB_DOMAIN 줄을 읽는 규칙, 그 규칙 이름을 일반 제거([UninstallRun])가 지우는지, 시작 메뉴
     바로가기가 있는지, Web-Domain.ps1이 BOM 있는 UTF-8 + CRLF인지(Windows PowerShell 5.1이 한글을 깨뜨리지 않게).
  2) 입력 검증: 도메인(ConvertTo-WebDomain), 포트(ConvertTo-PortNumber), 서버가 이미 쓰는 포트와의 겹침·이메일(Get-WebSettings),
     지금 설정 읽기(Get-CurrentWebSettings)와 주소 모양(Get-WebUrl).
  3) .env 고치기(Read-EnvLines·Get-EnvValue·Set-EnvValues): BOM 있는/없는 UTF-8, ANSI(CP949) 한글 주석, LF 줄바꿈, 중복 키·export·
     따옴표·주석, 없는 키는 설명 주석과 함께 끝에 붙임. 결과는 BOM 없는 UTF-8 + CRLF이고 다른 줄은 글자 그대로인지.
  4) 방화벽 규칙(Set-WebFirewallRules): 이름으로 지우고 다시 만드는지, node.exe로만 좁히는지(공백 든 경로도 인자 하나), 0이면 지우기만
     하는지, 만들지 못하면 예외인지.
  5) 포트 사용 확인(Get-PortUser): 이 테스트가 연 포트는 이 프로세스로 보이고, 서버(node.exe) 자신이면 $null.
  6) 인증서 확인(Get-WebCertificateStatus): 127.0.0.1의 빈 포트, TLS가 아닌 서버, 자체 서명 인증서와 "(STAGING)" 발급자 인증서를 내는
     TLS 서버, 이름이 다른 경우. 안내 문구(Get-WebCertificateStatusText·Get-WebGuideText·Get-RestartText), 사설 IP 판단
     (Test-PrivateAddress), 적용 전 경고(Get-ApplyWarnings — DNS·포트 확인은 가짜 함수로).

  사용법(저장소 루트): powershell -NoProfile -ExecutionPolicy Bypass -File server\installer\tests\Web-Domain.Tests.ps1
  실패가 하나라도 있으면 종료 코드 1.
#>

$ErrorActionPreference = 'Stop'
$installerDir = Split-Path $PSScriptRoot -Parent
$webDomainPath = Join-Path $installerDir 'Web-Domain.ps1'
$issPath = Join-Path $installerDir 'messenger-server.iss'
# messenger-server.iss는 BOM 없는 UTF-8이다.
$iss = [System.IO.File]::ReadAllText($issPath, [System.Text.Encoding]::UTF8)

$script:passed = 0
$script:failures = New-Object System.Collections.Generic.List[string]
$script:notes = New-Object System.Collections.Generic.List[string]
function Check([string]$Name, $Actual, $Expected) {
  if ("$Actual" -ceq "$Expected") { $script:passed++ } else { $script:failures.Add("$Name -> [$Actual], 기대값 [$Expected]") }
}
function CheckContains([string]$Name, [string]$Text, [string]$Part) {
  if ($Text.Contains($Part)) { $script:passed++ } else { $script:failures.Add("$Name -> [$Text]에 '$Part'이(가) 없음") }
}
function CheckNotContains([string]$Name, [string]$Text, [string]$Part) {
  if (-not $Text.Contains($Part)) { $script:passed++ } else { $script:failures.Add("$Name -> [$Text]에 '$Part'이(가) 있음") }
}
# 블록이 예외를 던지고 그 메시지에 $Part가 들어 있어야 통과.
function CheckThrows([string]$Name, [scriptblock]$Block, [string]$Part) {
  $message = $null
  try { & $Block | Out-Null } catch { $message = $_.Exception.Message }
  if ($null -ne $message -and $message.Contains($Part)) { $script:passed++ } else { $script:failures.Add("$Name -> 예외 [$message], 기대: '$Part'이(가) 든 예외") }
}

# 주석·줄바꿈을 뺀 토큰열 — 스크립트마다 들여쓰기(2칸/4칸)와 주석이 달라도 코드가 같으면 같다(Service-Env.Tests.ps1과 같음).
function Get-CodeTokens([string]$Text) {
  $tokens = $null
  $parseErrors = $null
  [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
  $kinds = @('Comment', 'NewLine', 'LineContinuation', 'EndOfInput')
  (@($tokens) | Where-Object { $kinds -notcontains "$($_.Kind)" } | ForEach-Object { $_.Text }) -join ' '
}

function Read-ScriptAst([string]$Name) {
  $parseErrors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $installerDir $Name), [ref]$null, [ref]$parseErrors)
  Check "parse: $Name 구문 오류 없음" (@($parseErrors).Count) 0
  return $ast
}

function Get-FunctionDefinitions($Ast, [string]$Name) {
  @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true))
}

# ── 1) 구성 ───────────────────────────────────────────────────────────────────
$webAst = Read-ScriptAst 'Web-Domain.ps1'
$setupAst = Read-ScriptAst 'Setup-TangoTalkServer.ps1'

# 문자열 안의 "$이름" 바로 뒤에 한글이 붙으면 PowerShell은 그 한글까지 변수 이름으로 읽어 빈 값을 넣는다("$name와" → $name와).
# 이 기능의 두 스크립트는 실패로, 다른 설치 스크립트는 메모로만 알린다($($name)이나 ${name}으로 감싸야 한다).
foreach ($file in @(Get-ChildItem -LiteralPath $installerDir -Filter '*.ps1' -File)) {
  $tokens = $null
  $parseErrors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
  $nested = @($tokens | Where-Object { $_ -is [System.Management.Automation.Language.StringExpandableToken] } | ForEach-Object { $_.NestedTokens })
  $glued = @(@($tokens) + $nested | Where-Object { $_.Kind -eq 'Variable' -and $_.Name -match '[가-힣]' } |
      ForEach-Object { "줄 $($_.Extent.StartLineNumber) `$$($_.Name)" })
  if (@('Web-Domain.ps1', 'Setup-TangoTalkServer.ps1') -contains $file.Name) {
    Check "hangul: $($file.Name)에 한글이 붙은 변수 이름 없음" ($glued -join ', ') ''
  } elseif ($glued.Count -gt 0) {
    $script:notes.Add("$($file.Name): 한글이 붙어 빈 값이 되는 변수 — $($glued -join ', ')")
  }
}

$bytes = [System.IO.File]::ReadAllBytes($webDomainPath)
Check 'file: Web-Domain.ps1이 BOM 있는 UTF-8' (($bytes.Length -ge 3) -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) $true
$webText = [System.IO.File]::ReadAllText($webDomainPath)
Check 'file: Web-Domain.ps1의 줄바꿈이 모두 CRLF' (($webText -replace "`r`n", '') -notmatch "[`r`n]") $true

$webFirewall = @(Get-FunctionDefinitions $webAst 'Set-WebFirewallRules')
$setupFirewall = @(Get-FunctionDefinitions $setupAst 'Set-WebFirewallRules')
Check 'fw: Web-Domain.ps1에 Set-WebFirewallRules 정의가 하나' $webFirewall.Count 1
Check 'fw: Setup-TangoTalkServer.ps1에 Set-WebFirewallRules 정의가 하나' $setupFirewall.Count 1
if ($webFirewall.Count -eq 1 -and $setupFirewall.Count -eq 1) {
  Check 'fw: 두 스크립트의 Set-WebFirewallRules가 같음(주석·들여쓰기 제외)' ((Get-CodeTokens $webFirewall[0].Extent.Text) -ceq (Get-CodeTokens $setupFirewall[0].Extent.Text)) $true
}
$ruleNames = @()
if ($webFirewall.Count -eq 1) {
  $ruleNames = @([regex]::Matches($webFirewall[0].Extent.Text, "Name = '([^']+)'") | ForEach-Object { $_.Groups[1].Value })
}
Check 'fw: 규칙 이름이 둘' $ruleNames.Count 2
$uninstallRun = [regex]::Match($iss, '(?ms)^\[UninstallRun\]\r?\n(.*?)(?=^\[)').Groups[1].Value
foreach ($ruleName in $ruleNames) {
  CheckContains "iss: 일반 제거가 '$ruleName' 규칙을 지움" $uninstallRun "advfirewall firewall delete rule name=""""$ruleName"""""
}
$icons = [regex]::Match($iss, '(?ms)^\[Icons\]\r?\n(.*?)(?=^\[)').Groups[1].Value
CheckContains 'iss: 시작 메뉴에 "웹 앱 주소(정식 인증서)"' $icons 'Name: "{group}\웹 앱 주소(정식 인증서)"'
CheckContains 'iss: 바로가기가 Web-Domain.ps1을 실행' $icons '-File ""{app}\Web-Domain.ps1""'

# Setup은 규칙을 경고만 남기는 try 안에서 다시 맞춘다(선택 기능이 설치를 멈추면 안 된다 — 본문 전체를 감싼 바깥 try는 Fail).
$setupCalls = @($setupAst.FindAll({ param($n)
      $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-WebFirewallRules' }, $true))
Check 'setup: Set-WebFirewallRules를 한 번 부름' $setupCalls.Count 1
foreach ($call in $setupCalls) {
  $parent = $call.Parent
  while ($parent -and -not ($parent -is [System.Management.Automation.Language.TryStatementAst])) { $parent = $parent.Parent }
  $catchText = if ($parent) { ($parent.CatchClauses | ForEach-Object { $_.Extent.Text }) -join ' ' } else { '' }
  Check 'setup: 가장 가까운 try의 catch가 경고만 남김(Write-SetupWarning)' ($catchText -match 'Write-SetupWarning' -and $catchText -notmatch '\bFail\b') $true
}
# Setup이 .env의 WEB_DOMAIN 줄에서 값을 꺼내는 규칙(그 if 문을 그대로 꺼내 돌린다).
$setupParse = @($setupAst.FindAll({ param($n)
      $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -like '$webDomainLine -match*' }, $true))
Check 'setup: WEB_DOMAIN 값을 꺼내는 if 문이 하나' $setupParse.Count 1
if ($setupParse.Count -eq 1) {
  $setupDomainCases = [ordered]@{
    'WEB_DOMAIN=xxx.iptime.org'          = 'xxx.iptime.org'
    'WEB_DOMAIN = xxx.iptime.org  '      = 'xxx.iptime.org'
    'export WEB_DOMAIN="chat.example.kr"' = 'chat.example.kr'
    "WEB_DOMAIN='a.example.org' # 주석"  = 'a.example.org'
    'WEB_DOMAIN='                        = ''
    'WEB_DOMAIN=   # 꺼 둠'               = ''
    'WEB_DOMAIN=""'                      = ''
  }
  foreach ($line in $setupDomainCases.Keys) {
    $webDomainLine = $line
    $webDomain = ''
    . ([scriptblock]::Create($setupParse[0].Extent.Text))
    Check "setup: [$line] → WEB_DOMAIN 값" $webDomain $setupDomainCases[$line]
  }
  $webDomainLine = $null
  $webDomain = ''
  . ([scriptblock]::Create($setupParse[0].Extent.Text))
  Check 'setup: WEB_DOMAIN 줄이 없으면 꺼짐' $webDomain ''
}

# ── Web-Domain.ps1의 함수와 상수 꺼내기 ───────────────────────────────────────
# 승격·창 만들기 같은 최상위 코드는 돌리지 않고, 함수 정의와 이 테스트가 그대로 쓰는 상수만 이 스코프에 정의한다.
$constants = @('$PgPort', '$StagingOnValue', '$EnvComment')
foreach ($stmt in $webAst.EndBlock.Statements) {
  $isFunction = $stmt -is [System.Management.Automation.Language.FunctionDefinitionAst]
  $isConstant = ($stmt -is [System.Management.Automation.Language.AssignmentStatementAst]) -and ($constants -contains $stmt.Left.Extent.Text)
  if ($isFunction -or $isConstant) { . ([scriptblock]::Create($stmt.Extent.Text)) }
}
Check 'const: PostgreSQL 포트가 Setup과 같음' $PgPort ([regex]::Match([System.IO.File]::ReadAllText((Join-Path $installerDir 'Setup-TangoTalkServer.ps1')), '(?m)^\$PgPort = (\d+)').Groups[1].Value)

$base = Join-Path $env:TEMP ('tangotalk-web-domain-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][System.IO.Directory]::CreateDirectory($base)
$EnvFile = Join-Path $base '.env'
$LiveKitConfig = Join-Path $base 'livekit.yaml'
$NodeExe = Join-Path $base 'node\node.exe'
$NodeServiceName = 'TangoTalkServer'
$listeners = New-Object System.Collections.Generic.List[object]
$certificates = New-Object System.Collections.Generic.List[object]
try {

  # ── 2) 입력 검증 ─────────────────────────────────────────────────────────────
  $validDomains = [ordered]@{
    'xxx.iptime.org'                             = 'xxx.iptime.org'
    '  HTTPS://Chat.Example.co.kr/path?x=1#top ' = 'chat.example.co.kr'
    'http://xxx.iptime.org/'                     = 'xxx.iptime.org'
    'xxx.iptime.org.'                            = 'xxx.iptime.org'
    'a-b.c-d9.com'                               = 'a-b.c-d9.com'
    '채팅.회사.한국'                              = 'xn--ou6bo7j.xn--vf4b131b.xn--3e0b707e'
    ''                                           = ''
    '   '                                        = ''
  }
  foreach ($raw in $validDomains.Keys) {
    Check "domain: [$raw]" (ConvertTo-WebDomain -Raw $raw) $validDomains[$raw]
  }
  $longLabel = 'a' * 64
  $longName = (@('a' * 63) * 4 -join '.') + '.com'
  $invalidDomains = [ordered]@{
    'xxx.iptime.org:443'         = '포트'
    'https://xxx.iptime.org:8443/' = '포트'
    '192.168.0.10'               = 'IP 주소'
    '203.0.113.5'                = 'IP 주소'
    '[::1]'                      = 'IP 주소'
    '2001:db8::1'                = 'IP 주소'
    'localhost'                  = '점(.)'
    'messenger-server'           = '점(.)'
    'nas.local'                  = '사내 전용'
    'pc.lan'                     = '사내 전용'
    'server.internal'            = '사내 전용'
    'a.b.123'                    = '사내 전용'
    '*.iptime.org'               = '형식'
    'a_b.iptime.org'             = '형식'
    '-a.iptime.org'              = '형식'
    'a-.iptime.org'              = '형식'
    'a..b.org'                   = '형식'
    'a b.org'                    = '형식'
    "$longLabel.com"             = '형식'
    $longName                    = '형식'
  }
  foreach ($raw in $invalidDomains.Keys) {
    CheckThrows "domain: [$raw] 거절" { ConvertTo-WebDomain -Raw $raw } $invalidDomains[$raw]
  }

  Check 'port: 443' (ConvertTo-PortNumber -Raw '443' -Label '웹 HTTPS 포트') 443
  Check 'port: 앞뒤 공백' (ConvertTo-PortNumber -Raw ' 8443 ' -Label '웹 HTTPS 포트') 8443
  Check 'port: 0(-AllowZero)' (ConvertTo-PortNumber -Raw '0' -Label '인증용 HTTP 포트' -AllowZero) 0
  Check 'port: 65535' (ConvertTo-PortNumber -Raw '65535' -Label '웹 HTTPS 포트') 65535
  CheckThrows 'port: 0 거절' { ConvertTo-PortNumber -Raw '0' -Label '웹 HTTPS 포트' } '웹 HTTPS 포트'
  foreach ($raw in @('65536', '99999', 'abc', '', '-1', '44 3', '443x', '123456')) {
    CheckThrows "port: [$raw] 거절" { ConvertTo-PortNumber -Raw $raw -Label '인증용 HTTP 포트' -AllowZero } '인증용 HTTP 포트'
  }

  function New-Settings([string]$Domain = 'xxx.iptime.org', [string]$Web = '443', [string]$Acme = '80', [string]$Email = '', [bool]$Staging = $false, [string[]]$Lines = @()) {
    Get-WebSettings -DomainText $Domain -WebPortText $Web -AcmePortText $Acme -EmailText $Email -Staging $Staging -Lines $Lines
  }
  $s = New-Settings -Domain ' XXX.iptime.org ' -Email ' it@example.co.kr ' -Staging $true
  Check 'settings: 정리된 값' "$($s.Domain)|$($s.WebPort)|$($s.AcmePort)|$($s.Email)|$($s.Staging)" 'xxx.iptime.org|443|80|it@example.co.kr|True'
  $s = New-Settings -Domain '' -Web 'abc' -Acme 'xyz' -Email 'nope'
  Check 'settings: 도메인을 비우면 끄기(다른 칸은 안 봄)' "$($s.Domain)|$($s.WebPort)|$($s.AcmePort)" '|0|0'
  $s = New-Settings -Web '443' -Acme '0'
  Check 'settings: 인증용 포트 0' $s.AcmePort 0
  CheckThrows 'settings: 웹=인증용 거절' { New-Settings -Web '8443' -Acme '8443' } '서로 달라야'
  CheckThrows 'settings: 메인 포트(기본 3000)와 겹침' { New-Settings -Web '3000' } '메인 포트'
  CheckThrows 'settings: 페어링 포트(기본 3001)와 겹침' { New-Settings -Acme '3001' } '페어링 포트'
  CheckThrows 'settings: LiveKit 신호(기본 7880)와 겹침' { New-Settings -Web '7880' } '화상회의 신호'
  CheckThrows 'settings: LiveKit 미디어 TCP(기본 7881)와 겹침' { New-Settings -Acme '7881' } '화상회의 미디어'
  CheckThrows 'settings: PostgreSQL 포트와 겹침' { New-Settings -Web '55432' } 'PostgreSQL'
  CheckThrows 'settings: .env의 PORT=3100이면 페어링 3101과 겹침' { New-Settings -Web '3101' -Lines @('PORT=3100') } '페어링 포트'
  $s = New-Settings -Web '3001' -Lines @('PORT=3100')
  Check 'settings: PORT=3100이면 3001은 비어 있음' $s.WebPort 3001
  CheckThrows 'settings: PAIRING_PORT=4000과 겹침' { New-Settings -Web '4000' -Lines @('PAIRING_PORT=4000') } '페어링 포트'
  [System.IO.File]::WriteAllText($LiveKitConfig, "port: 7990`r`nrtc:`r`n  port_range_start: 50000`r`n  tcp_port: 7991`r`n")
  CheckThrows 'settings: livekit.yaml의 port와 겹침' { New-Settings -Web '7990' } '화상회의 신호'
  CheckThrows 'settings: livekit.yaml의 tcp_port와 겹침' { New-Settings -Acme '7991' } '화상회의 미디어'
  Check 'settings: livekit.yaml이 있으면 기본 7880은 비어 있음' (New-Settings -Web '7880').WebPort 7880
  Remove-Item -LiteralPath $LiveKitConfig
  foreach ($email in @('abc', 'a@b', 'a@b.c', 'a b@example.com', 'a@exam_ple.com', '"a"@example.com', 'a@example.com#x', 'a@-x.com', 'a@x-.example.com', 'a@x..com')) {
    CheckThrows "settings: 이메일 [$email] 거절" { New-Settings -Email $email } '이메일'
  }
  Check 'settings: 이메일 비워도 됨' (New-Settings -Email '   ').Email ''

  $c = Get-CurrentWebSettings -Lines @()
  Check 'current: 빈 .env는 꺼짐 + 기본 포트' "$($c.Domain)|$($c.WebPort)|$($c.AcmePort)|$($c.Email)|$($c.Staging)" '|443|80||False'
  $c = Get-CurrentWebSettings -Lines @('WEB_DOMAIN=Chat.Example.org', 'WEB_HTTPS_PORT=8443', 'ACME_HTTP_PORT=0', 'ACME_EMAIL="a@b.co"', 'ACME_STAGING=true')
  Check 'current: 값 읽기' "$($c.Domain)|$($c.WebPort)|$($c.AcmePort)|$($c.Email)|$($c.Staging)" 'chat.example.org|8443|0|a@b.co|True'
  foreach ($case in @(@('1', $true), @('TRUE', $true), @('yes', $true), @('on', $true), @('0', $false), @('false', $false), @('', $false))) {
    Check "current: ACME_STAGING=[$($case[0])]" (Get-CurrentWebSettings -Lines @("ACME_STAGING=$($case[0])")).Staging $case[1]
  }
  Check 'current: 시험 발급을 켤 때 쓰는 값도 켜짐으로 읽힘' (Get-CurrentWebSettings -Lines @("ACME_STAGING=$StagingOnValue")).Staging $true
  Check 'current: 포트 값이 이상하면 기본값' "$((Get-CurrentWebSettings -Lines @('WEB_HTTPS_PORT=abc', 'ACME_HTTP_PORT=')).WebPort)" '443'

  Check 'same: 같은 설정' (Test-SameWebSettings -A (New-Settings) -B (New-Settings)) $true
  Check 'same: 도메인 대소문자만 다름' (Test-SameWebSettings -A (Get-CurrentWebSettings -Lines @('WEB_DOMAIN=XXX.iptime.org')) -B (New-Settings)) $true
  Check 'same: 시험 발급이 다름' (Test-SameWebSettings -A (New-Settings) -B (New-Settings -Staging $true)) $false
  Check 'same: 포트가 다름' (Test-SameWebSettings -A (New-Settings) -B (New-Settings -Acme '0')) $false

  Check 'url: 443은 포트 생략' (Get-WebUrl -Settings (New-Settings)) 'https://xxx.iptime.org'
  Check 'url: 다른 포트는 붙임' (Get-WebUrl -Settings (New-Settings -Web '8443')) 'https://xxx.iptime.org:8443'

  # ── 3) .env 고치기 ──────────────────────────────────────────────────────────
  $values = [ordered]@{ WEB_DOMAIN = 'xxx.iptime.org'; WEB_HTTPS_PORT = '443'; ACME_HTTP_PORT = '80'; ACME_EMAIL = '' }
  $crlf = "`r`n"
  $appended = @('', $EnvComment, 'WEB_DOMAIN=xxx.iptime.org', 'WEB_HTTPS_PORT=443', 'ACME_HTTP_PORT=80', 'ACME_EMAIL=')
  function Test-EnvFileShape([string]$Label) {
    $raw = [System.IO.File]::ReadAllBytes($EnvFile)
    Check "$Label — BOM 없음" (($raw.Length -lt 3) -or -not ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)) $true
    $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($raw)
    Check "$Label — 줄바꿈이 모두 CRLF" (($text -replace "`r`n", '') -notmatch "[`r`n]") $true
    Check "$Label — CRLF로 끝남" ($text.EndsWith("`r`n")) $true
    return $text
  }

  # (a) 설치 프로그램이 만든 모양 — BOM 있는 UTF-8, 한글 주석.
  $setupLines = @('# Setup-TangoTalkServer.ps1이 설치 시점에 자동으로 만들었습니다.', 'DATABASE_URL=postgres://messenger_app:pw@localhost:55432/messenger', '',
    '# JWT_SECRET / DB_ENCRYPTION_KEY는 일부러 비워둡니다 — 서버가 첫 실행 때 알아서 만듭니다.')
  [System.IO.File]::WriteAllText($EnvFile, ($setupLines -join $crlf), (New-Object System.Text.UTF8Encoding($true)))
  Check 'env(a): BOM은 줄로 읽히지 않음' ((@(Read-EnvLines))[0]) $setupLines[0]
  Set-EnvValues -Values $values -Comment $EnvComment
  $text = Test-EnvFileShape 'env(a)'
  $expectedText = ((@($setupLines) + $appended) -join $crlf) + $crlf
  Check 'env(a): 원래 줄은 그대로, 새 키는 주석과 함께 끝에' $text $expectedText

  # (b) External-Address.ps1이 쓴 모양 — BOM 없는 UTF-8, 이미 있는 키(중복·export·주석 처리된 줄 포함), 빈 줄로 끝남.
  $existing = @('DATABASE_URL=x', '# WEB_DOMAIN=주석이라 그대로', 'export WEB_DOMAIN=old.example.org', 'EXTERNAL_ADDRESS=xxx.iptime.org', ' WEB_HTTPS_PORT = 8443 ',
    'WEB_DOMAIN=old2.example.org', 'ACME_STAGING=1', '')
  [System.IO.File]::WriteAllText($EnvFile, (($existing -join $crlf) + $crlf), (New-Object System.Text.UTF8Encoding($false)))
  Check 'env(b): 마지막 줄바꿈 뒤 빈 조각은 줄이 아님' (@(Read-EnvLines).Count) $existing.Count
  Check 'env(b): 같은 키는 마지막 줄 값' (Get-EnvValue -Name 'WEB_DOMAIN' -Lines @(Read-EnvLines)) 'old2.example.org'
  Set-EnvValues -Values ([ordered]@{ WEB_DOMAIN = 'new.example.org'; WEB_HTTPS_PORT = '443'; ACME_STAGING = '' }) -Comment $EnvComment
  $text = Test-EnvFileShape 'env(b)'
  $expected = @('DATABASE_URL=x', '# WEB_DOMAIN=주석이라 그대로', 'WEB_DOMAIN=new.example.org', 'EXTERNAL_ADDRESS=xxx.iptime.org', 'WEB_HTTPS_PORT=443',
    'WEB_DOMAIN=new.example.org', 'ACME_STAGING=', '')
  Check 'env(b): 있던 키는 그 자리에서 바꾸고(중복 모두), 주석 줄은 그대로, 새로 붙일 것 없음' $text (($expected -join $crlf) + $crlf)

  # (c) 예전 메모장의 ANSI(한글 Windows는 CP949) — UTF-8이 아니면 시스템 기본 코드 페이지로 읽고, UTF-8로 다시 쓴다.
  $ansi = [System.Text.Encoding]::Default
  $ansiLines = @('# 한글 주석 - 손으로 고친 파일', 'UPLOADS_DIR=D:\첨부파일', 'PORT=3000')
  $ansiBytes = $ansi.GetBytes(($ansiLines -join $crlf) + $crlf)
  $isValidUtf8 = $true
  try { [void](New-Object System.Text.UTF8Encoding($false, $true)).GetString($ansiBytes) } catch { $isValidUtf8 = $false }
  if ($isValidUtf8) {
    $script:notes.Add("이 PC의 기본 코드 페이지($($ansi.CodePage))로 쓴 한글이 UTF-8로도 읽혀서 ANSI 대체 읽기는 확인하지 못했습니다.")
  } else {
    [System.IO.File]::WriteAllBytes($EnvFile, $ansiBytes)
    $expectedAnsi = @($ansi.GetString($ansiBytes) -split "`r`n" | Select-Object -First $ansiLines.Count)
    Check 'env(c): ANSI 파일을 기본 코드 페이지로 읽음' ((@(Read-EnvLines)) -join '|') ($expectedAnsi -join '|')
    Set-EnvValues -Values $values -Comment $EnvComment
    $text = Test-EnvFileShape 'env(c)'
    $expectedText = ((@($expectedAnsi) + $appended) -join $crlf) + $crlf
    Check 'env(c): 한글 줄이 UTF-8로 그대로' $text $expectedText
  }

  # (d) .env가 없으면 새로 만든다(주석 + 키). LF 줄바꿈·마지막 줄바꿈 없음도 CRLF로 맞춘다.
  Remove-Item -LiteralPath $EnvFile
  Check 'env(d): 없는 파일은 빈 줄 목록' (@(Read-EnvLines).Count) 0
  Set-EnvValues -Values $values -Comment $EnvComment
  $text = Test-EnvFileShape 'env(d)'
  Check 'env(d): 새 파일 — 맨 앞 빈 줄 없이 주석 + 키' $text ((@($appended | Select-Object -Skip 1) -join $crlf) + $crlf)
  [System.IO.File]::WriteAllText($EnvFile, "A=1`nB=2", (New-Object System.Text.UTF8Encoding($false)))
  Check 'env(d): 마지막 줄바꿈 없는 LF 파일' ((@(Read-EnvLines)) -join '|') 'A=1|B=2'
  Set-EnvValues -Values ([ordered]@{ WEB_DOMAIN = '' }) -Comment ''
  $text = Test-EnvFileShape 'env(d) LF'
  Check 'env(d): 주석 없이 끄기 값만 붙임' $text ((@('A=1', 'B=2', '', 'WEB_DOMAIN=') -join $crlf) + $crlf)
  [System.IO.File]::WriteAllText($EnvFile, '', (New-Object System.Text.UTF8Encoding($false)))
  Check 'env(d): 빈 파일은 빈 줄 목록' (@(Read-EnvLines).Count) 0

  # Get-EnvValue — dotenv와 같은 규칙.
  $valueLines = @('A="quoted value"', "B='single'", 'C=`back`', 'D=plain # 주석', 'E=no#space', 'F=', 'export G=exported', '  H = spaced  ', 'I="unterminated', 'J=x', 'J=y')
  $expectedValues = [ordered]@{ A = 'quoted value'; B = 'single'; C = 'back'; D = 'plain'; E = 'no'; F = ''; G = 'exported'; H = 'spaced'; I = '"unterminated'; J = 'y'; Z = '' }
  foreach ($name in $expectedValues.Keys) {
    Check "env value: $name" (Get-EnvValue -Name $name -Lines $valueLines) $expectedValues[$name]
  }
  Check 'env value: 이름 일부만 같은 키는 아님' (Get-EnvValue -Name 'WEB_DOMAIN' -Lines @('WEB_DOMAIN_OLD=x', 'MY_WEB_DOMAIN=y')) ''

  # Get-EnvValuesForSettings — 적용·끄기가 .env에 쓰는 이름=값.
  function Format-Values($Values) { (@($Values.Keys | ForEach-Object { "$_=$($Values[$_])" })) -join ';' }
  $off = [pscustomobject]@{ Domain = ''; WebPort = 0; AcmePort = 0; Email = ''; Staging = $false }
  Check 'values: 켜기' (Format-Values (Get-EnvValuesForSettings -Settings (New-Settings -Email 'it@example.co.kr') -Lines @())) 'WEB_DOMAIN=xxx.iptime.org;WEB_HTTPS_PORT=443;ACME_HTTP_PORT=80;ACME_EMAIL=it@example.co.kr'
  Check 'values: 시험 발급 켜기' (Format-Values (Get-EnvValuesForSettings -Settings (New-Settings -Web '8443' -Acme '0' -Staging $true) -Lines @())) "WEB_DOMAIN=xxx.iptime.org;WEB_HTTPS_PORT=8443;ACME_HTTP_PORT=0;ACME_EMAIL=;ACME_STAGING=$StagingOnValue"
  Check 'values: 시험 발급 끄기 — 있던 줄만 비움' (Format-Values (Get-EnvValuesForSettings -Settings (New-Settings) -Lines @('ACME_STAGING=1'))) 'WEB_DOMAIN=xxx.iptime.org;WEB_HTTPS_PORT=443;ACME_HTTP_PORT=80;ACME_EMAIL=;ACME_STAGING='
  Check 'values: 끄기 — WEB_DOMAIN만 비움' (Format-Values (Get-EnvValuesForSettings -Settings $off -Lines @('ACME_STAGING=1', 'WEB_DOMAIN=a.example.org'))) 'WEB_DOMAIN='

  # 서버가 이 .env를 같은 뜻으로 읽는지 — 서버의 dotenv와 server/src/webTlsConfig.js(readWebTlsConfig)를 그대로 돌린다(node 필요, DB·
  # 네트워크 안 씀). 다른 쪽(서버)이 규칙을 바꾸면 여기서 걸린다.
  $serverDir = Split-Path $installerDir -Parent
  $webTlsConfig = Join-Path $serverDir 'src\webTlsConfig.js'
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node -or -not (Test-Path -LiteralPath $webTlsConfig) -or -not (Test-Path -LiteralPath (Join-Path $serverDir 'node_modules\dotenv'))) {
    $script:notes.Add('node나 server\src\webTlsConfig.js·server\node_modules\dotenv가 없어 서버가 .env를 읽는 결과는 확인하지 못했습니다.')
  } else {
    $helper = Join-Path $base 'read-web-tls.mjs'
    $helperOut = Join-Path $base 'read-web-tls.json'
    [System.IO.File]::WriteAllText($helper, (@(
          "import fs from 'node:fs';"
          "import path from 'node:path';"
          "import { createRequire } from 'node:module';"
          "import { pathToFileURL } from 'node:url';"
          'const [serverDir, envFile, outFile] = process.argv.slice(2);'
          "const dotenv = createRequire(path.join(serverDir, 'package.json'))('dotenv');"
          "const { readWebTlsConfig } = await import(pathToFileURL(path.join(serverDir, 'src', 'webTlsConfig.js')).href);"
          'const env = dotenv.parse(fs.readFileSync(envFile));'
          'const port = Number(env.PORT) || 3000;'
          'const cfg = readWebTlsConfig(env, { port, pairingPort: Number(env.PAIRING_PORT) || port + 1 });'
          'fs.writeFileSync(outFile, JSON.stringify({ ...cfg, uploadsDir: env.UPLOADS_DIR ?? null }));'
        ) -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
    # 이 함수 안에서만 'Continue' — PowerShell 5.1은 'Stop'이면 2>&1로 받은 네이티브 stderr 한 줄을 곧바로 예외로 바꾼다.
    function Read-ServerWebTls {
      $ErrorActionPreference = 'Continue'
      if (Test-Path -LiteralPath $helperOut) { Remove-Item -LiteralPath $helperOut }
      $output = & $node.Source $helper $serverDir $EnvFile $helperOut 2>&1
      if ($LASTEXITCODE -ne 0) { throw "node 실패(종료 코드 $LASTEXITCODE): $output" }
      return ([System.IO.File]::ReadAllText($helperOut, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    }
    function Format-ServerWebTls($Config) {
      "$($Config.domain)|$($Config.httpsPort)|$($Config.httpPort)|$($Config.email)|$($Config.staging)|$($Config.error)|$(@($Config.warnings).Count)"
    }
    function Write-SettingsToEnv($Settings) {
      Set-EnvValues -Values (Get-EnvValuesForSettings -Settings $Settings -Lines @(Read-EnvLines)) -Comment $EnvComment
    }
    [System.IO.File]::WriteAllText($EnvFile, ($setupLines -join $crlf), (New-Object System.Text.UTF8Encoding($true)))
    Write-SettingsToEnv (New-Settings)
    Check 'server: 기본 설정(443/80)' (Format-ServerWebTls (Read-ServerWebTls)) 'xxx.iptime.org|443|80||False||0'
    Write-SettingsToEnv (New-Settings -Domain 'Chat.Example.co.kr' -Web '8443' -Acme '0' -Email 'it@example.co.kr' -Staging $true)
    Check 'server: 다른 포트·인증용 끔·이메일·시험 발급' (Format-ServerWebTls (Read-ServerWebTls)) 'chat.example.co.kr|8443|0|it@example.co.kr|True||0'
    Write-SettingsToEnv (New-Settings -Domain 'chat.example.co.kr' -Web '8443' -Acme '8080')
    Check 'server: 시험 발급을 끄면 빈 값(경고 없음)' (Format-ServerWebTls (Read-ServerWebTls)) 'chat.example.co.kr|8443|8080||False||0'
    Write-SettingsToEnv (New-Settings -Domain '채팅.회사.한국')
    Check 'server: 한글 도메인(퓨니코드)' (Format-ServerWebTls (Read-ServerWebTls)) 'xn--ou6bo7j.xn--vf4b131b.xn--3e0b707e|443|80||False||0'
    Write-SettingsToEnv $off
    Check 'server: 끄기' (Format-ServerWebTls (Read-ServerWebTls)) '|443|80||False||0'
    if (-not $isValidUtf8) {
      [System.IO.File]::WriteAllBytes($EnvFile, $ansiBytes)
      Write-SettingsToEnv (New-Settings)
      $config = Read-ServerWebTls
      Check 'server: ANSI였던 .env의 한글 값을 UTF-8로 읽음' $config.uploadsDir $expectedAnsi[1].Substring('UPLOADS_DIR='.Length)
      Check 'server: ANSI였던 .env도 웹 설정을 읽음' (Format-ServerWebTls $config) 'xxx.iptime.org|443|80||False||0'
    }
  }

  # ── 4) 방화벽 규칙(가짜 netsh) ────────────────────────────────────────────────
  # PowerShell은 같은 이름이면 외부 프로그램보다 함수를 먼저 찾으므로, 이 스코프의 netsh 함수가 진짜 netsh.exe 대신 불린다.
  $script:netshCalls = New-Object System.Collections.Generic.List[string]
  $script:netshFailAdd = $false
  function netsh {
    $script:netshCalls.Add((@($args | ForEach-Object { "<$_>" }) -join ' '))
    $global:LASTEXITCODE = $(if ($script:netshFailAdd -and $args -contains 'add') { 1 } else { 0 })
    'Ok.'
  }
  function Invoke-FirewallCase([int]$Web, [int]$Acme) {
    $script:netshCalls.Clear()
    Set-WebFirewallRules -WebPort $Web -AcmePort $Acme
    return ($script:netshCalls -join ' | ')
  }
  $del = '<advfirewall> <firewall> <delete> <rule>'
  $add = '<advfirewall> <firewall> <add> <rule>'
  $prog = "<program=$NodeExe>"
  Check 'fw: 443/80 — 지우고 node.exe 전용으로 다시 만듦' (Invoke-FirewallCase 443 80) (
    "$del <name=TangoTalk Server (web)> | $add <name=TangoTalk Server (web)> <dir=in> <action=allow> <protocol=TCP> <localport=443> $prog | " +
    "$del <name=TangoTalk Server (web-acme)> | $add <name=TangoTalk Server (web-acme)> <dir=in> <action=allow> <protocol=TCP> <localport=80> $prog")
  Check 'fw: 인증용 0 — 그 규칙은 지우기만' (Invoke-FirewallCase 8443 0) (
    "$del <name=TangoTalk Server (web)> | $add <name=TangoTalk Server (web)> <dir=in> <action=allow> <protocol=TCP> <localport=8443> $prog | " +
    "$del <name=TangoTalk Server (web-acme)>")
  Check 'fw: 끄기(0, 0) — 둘 다 지우기만' (Invoke-FirewallCase 0 0) "$del <name=TangoTalk Server (web)> | $del <name=TangoTalk Server (web-acme)>"
  $savedNodeExe = $NodeExe
  $NodeExe = 'C:\My Server\TangoTalk\node\node.exe'
  $calls = Invoke-FirewallCase 443 0
  CheckContains 'fw: 공백 든 node.exe 경로도 인자 하나' $calls '<localport=443> <program=C:\My Server\TangoTalk\node\node.exe>'
  $NodeExe = $savedNodeExe
  $script:netshFailAdd = $true
  CheckThrows 'fw: 만들지 못하면 예외' { Invoke-FirewallCase 443 80 } 'TangoTalk Server (web), TCP 443'
  $script:netshFailAdd = $false
  Remove-Item -LiteralPath Function:\netsh

  # ── 5) 포트 사용 확인 ────────────────────────────────────────────────────────
  $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  $listeners.Add($listener)
  $busyPort = $listener.LocalEndpoint.Port
  $user = Get-PortUser -Port $busyPort
  CheckContains 'port user: 이 테스트가 연 포트는 이 프로세스' "$user" "(PID $PID)"
  $savedNodeExe = $NodeExe
  $NodeExe = (Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $PID").ExecutablePath
  Check 'port user: 서버(node.exe) 자신이면 $null' ($null -eq (Get-PortUser -Port $busyPort)) $true
  $NodeExe = $savedNodeExe
  $listener.Stop()
  Check 'port user: 아무도 안 쓰면 $null' ($null -eq (Get-PortUser -Port $busyPort)) $true

  $lan = Get-LanAddress
  Check 'lan: 빈 값이거나 IPv4' ($lan -eq '' -or $lan -match '^\d{1,3}(\.\d{1,3}){3}$') $true

  # ── 6) 인증서 확인 ───────────────────────────────────────────────────────────
  # 시험용 인증서 — Schannel(서버 쪽 SslStream)은 메모리에만 있는 키를 못 쓰므로 PFX로 내보냈다가 다시 읽는다. PersistKeySet 없이
  # 읽은 키는 Dispose 때 지워지고, 인증서 저장소에는 넣지 않는다.
  function New-TestCertificate([string]$Subject, [string]$DnsName) {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
    try {
      $request = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest($Subject, $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
      $sanBuilder = New-Object System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder
      $sanBuilder.AddDnsName($DnsName)
      $request.CertificateExtensions.Add($sanBuilder.Build())
      $ephemeral = $request.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-1), [DateTimeOffset]::Now.AddDays(30))
      try {
        $pfx = $ephemeral.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, 'test')
      } finally {
        $ephemeral.Dispose()
      }
      $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $pfx, 'test',
        ([System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet)
      $certificates.Add($cert)
      return $cert
    } finally {
      $rsa.Dispose()
    }
  }
  # 127.0.0.1의 임시 포트에서 연결 하나를 받는 서버를 다른 런스페이스에서 돌린다(클라이언트는 이 스레드에서 막혀 기다리므로).
  # 인증서가 없으면 TLS 없이 받자마자 끊는다.
  function Start-TestServer($Certificate) {
    $serverListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $serverListener.Start()
    $listeners.Add($serverListener)
    $shell = [PowerShell]::Create()
    [void]$shell.AddScript({
        param($Listener, $Certificate)
        $client = $Listener.AcceptTcpClient()
        try {
          if ($Certificate) {
            $ssl = New-Object System.Net.Security.SslStream -ArgumentList $client.GetStream(), $false
            try {
              $ssl.AuthenticateAsServer($Certificate, $false, [System.Security.Authentication.SslProtocols]::Tls12, $false)
            } finally {
              $ssl.Dispose()
            }
          }
        } catch {
        } finally {
          $client.Close()
        }
      }).AddArgument($serverListener).AddArgument($Certificate)
    return [pscustomobject]@{ Port = $serverListener.LocalEndpoint.Port; Listener = $serverListener; Shell = $shell; Handle = $shell.BeginInvoke() }
  }
  function Stop-TestServer($Server) {
    $Server.Listener.Stop()
    [void]$Server.Handle.AsyncWaitHandle.WaitOne(10000)
    try { [void]$Server.Shell.EndInvoke($Server.Handle) } catch { }
    $Server.Shell.Dispose()
  }

  $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
  $probe.Start()
  $freePort = $probe.LocalEndpoint.Port
  $probe.Stop()
  $status = Get-WebCertificateStatus -Domain 'web.example.org' -Port $freePort -TimeoutMs 4000
  Check 'cert: 빈 포트 — 연결 안 됨' "$($status.Reachable)|$($status.Issuer)" 'False|'
  $settings = New-Settings -Domain 'web.example.org' -Web "$freePort" -Acme '0'
  CheckContains 'cert text: 빈 포트' (Get-WebCertificateStatusText -Status $status -Settings $settings) "웹 HTTPS 포트($freePort)에서 응답이 없습니다"

  $server = Start-TestServer $null
  $status = Get-WebCertificateStatus -Domain 'web.example.org' -Port $server.Port -TimeoutMs 4000
  Stop-TestServer $server
  Check 'cert: TLS가 아닌 서버 — 연결은 되지만 인증서 없음' "$($status.Reachable)|$($status.Issuer)|$($status.Trusted)" 'True||False'
  Check 'cert: TLS가 아닌 서버 — 오류 문구가 있음' ([bool]$status.Error) $true
  CheckContains 'cert text: TLS가 아닌 서버' (Get-WebCertificateStatusText -Status $status -Settings $settings) '인증서를 받아 오지 못했습니다'

  $selfSigned = New-TestCertificate -Subject 'CN=web.example.org' -DnsName 'web.example.org'
  $server = Start-TestServer $selfSigned
  $status = Get-WebCertificateStatus -Domain 'web.example.org' -Port $server.Port -TimeoutMs 5000
  Stop-TestServer $server
  Check 'cert: 자체 서명 — 읽었지만 믿지 않음' "$($status.Reachable)|$($status.Trusted)|$($status.Staging)|$($status.Subject)|$($status.Issuer)" 'True|False|False|CN=web.example.org|CN=web.example.org'
  Check 'cert: 만료일을 읽음' ($status.NotAfter -gt (Get-Date).AddDays(29) -and $status.NotAfter -lt (Get-Date).AddDays(31)) $true
  $text = Get-WebCertificateStatusText -Status $status -Settings $settings
  CheckContains 'cert text: 자체 서명' $text '아직 정식 인증서가 아닙니다'
  CheckNotContains 'cert text: 자체 서명은 만료 아님' $text '만료됨'

  $server = Start-TestServer $selfSigned
  $status = Get-WebCertificateStatus -Domain 'other.example.org' -Port $server.Port -TimeoutMs 5000
  Stop-TestServer $server
  Check 'cert: 이름이 다르면 믿지 않음' "$($status.Reachable)|$($status.Trusted)|$($status.Subject)" 'True|False|CN=web.example.org'

  $staging = New-TestCertificate -Subject 'CN=(STAGING) Pretend Pear X1, O=(STAGING) Let''s Encrypt, C=US' -DnsName 'web.example.org'
  $server = Start-TestServer $staging
  $status = Get-WebCertificateStatus -Domain 'web.example.org' -Port $server.Port -TimeoutMs 5000
  Stop-TestServer $server
  Check 'cert: "(STAGING)" 발급자는 시험용' "$($status.Trusted)|$($status.Staging)" 'False|True'
  CheckContains 'cert text: 시험용' (Get-WebCertificateStatusText -Status $status -Settings $settings) '시험용(스테이징) 인증서가 걸려 있습니다'

  # 공인 인증서는 여기서 만들 수 없으므로 판정 결과만 꾸며서 문구를 본다.
  $fake = [pscustomobject]@{ Reachable = $true; Trusted = $true; Staging = $false; Subject = 'CN=xxx.iptime.org'; Issuer = 'CN=R11, O=Let''s Encrypt, C=US'; NotAfter = [datetime]'2027-01-05'; Error = '' }
  $text = Get-WebCertificateStatusText -Status $fake -Settings (New-Settings -Web '8443')
  CheckContains 'cert text: 정식 인증서' $text '정식 인증서가 걸려 있습니다'
  CheckContains 'cert text: 정식 인증서 — 만료일' $text '2027-01-05'
  CheckContains 'cert text: 정식 인증서 — 아이폰 주소' $text 'https://xxx.iptime.org:8443'
  $fake.Trusted = $false
  $fake.NotAfter = [datetime]'2020-01-01'
  CheckContains 'cert text: 만료된 인증서' (Get-WebCertificateStatusText -Status $fake -Settings (New-Settings)) '2020-01-01 에 만료됨'

  # ── 안내 문구 ───────────────────────────────────────────────────────────────
  $guide = Get-WebGuideText -Settings (New-Settings) -LanIp '192.168.0.10'
  CheckContains 'guide(443/80): 외부 443 → 웹 포트' $guide '외부 TCP 443 → 이 PC(192.168.0.10) TCP 443'
  CheckContains 'guide(443/80): 외부 80 → 인증용 포트' $guide '외부 TCP 80 → 이 PC(192.168.0.10) TCP 80'
  CheckNotContains 'guide(443/80): 같은 번호 포워딩은 없음' $guide '이라 같은 번호도 엽니다'
  CheckContains 'guide(443/80): iptime.org 한도 안내' $guide 'iptime.org 주의'
  CheckContains 'guide(443/80): CNAME 안내' $guide 'CNAME으로 xxx.iptime.org에 연결'
  CheckContains 'guide(443/80): 한도에 걸리면 서버가 알아서 다시 시도' $guide '알려 준 시각(몇 시간~며칠 뒤)에 알아서 다시 시도'
  CheckContains 'guide(443/80): 재시작해도 다음 시도 시각 전에는 안 물음' $guide '서버를 다시 시작해도 그 시각 전에는 다시 묻지 않으니'
  CheckContains 'guide(443/80): 아이폰 주소(포트 생략)' $guide '사파리에서 https://xxx.iptime.org 을 열어'
  CheckContains 'guide(443/80): 아이폰이 4번' $guide '4) 아이폰 사용자'
  CheckContains 'guide(443/80): 홈 화면에 추가' $guide '"홈 화면에 추가"'
  CheckContains 'guide(443/80): 정식 발급 안내' $guide '자동으로 받고 만료 전에 알아서 갱신'
  $guide = Get-WebGuideText -Settings (New-Settings -Domain 'chat.example.co.kr' -Web '8443' -Acme '8080') -LanIp ''
  CheckContains 'guide(8443/8080): 외부 443 → 8443' $guide '외부 TCP 443 → 이 PC TCP 8443'
  CheckContains 'guide(8443/8080): 외부 8443 → 8443(주소에 포트가 붙음)' $guide '외부 TCP 8443 → 이 PC TCP 8443'
  CheckContains 'guide(8443/8080): 외부 80 → 8080' $guide '외부 TCP 80 → 이 PC TCP 8080'
  CheckContains 'guide(8443/8080): 주소에 포트' $guide 'https://chat.example.co.kr:8443'
  CheckNotContains 'guide(8443/8080): iptime이 아니면 한도 안내 없음' $guide 'iptime.org 주의'
  CheckContains 'guide(8443/8080): 아이폰이 3번' $guide '3) 아이폰 사용자'
  $guide = Get-WebGuideText -Settings (New-Settings -Acme '0' -Staging $true) -LanIp ''
  CheckContains 'guide(443/0): 443으로만 확인' $guide '인증용 HTTP 포트가 0이라'
  CheckNotContains 'guide(443/0): 외부 80 포워딩 없음' $guide '외부 TCP 80'
  CheckContains 'guide(시험 발급): 시험용 안내' $guide '시험 발급(스테이징) 중입니다'
  CheckNotContains 'guide(시험 발급): 정식 발급 안내 없음' $guide '자동으로 받고 만료 전에 알아서 갱신'

  CheckContains 'restart text: 서비스 없음(콘솔 모드)' (Get-RestartText -Status '' -Done '적용했습니다.') '서버 콘솔로 실행'
  Check 'restart text: 실행 중' (Get-RestartText -Status 'Running' -Done '적용했습니다.') '적용했습니다. 서버를 다시 시작했습니다.'
  CheckContains 'restart text: 다른 상태' (Get-RestartText -Status 'Stopped' -Done '적용했습니다.') "'Stopped'"

  $privateCases = [ordered]@{
    '192.168.0.1' = $true; '10.1.2.3' = $true; '172.16.0.1' = $true; '172.31.255.1' = $true; '172.32.0.1' = $false; '100.64.0.1' = $true
    '100.127.1.1' = $true; '100.128.0.1' = $false; '127.0.0.1' = $true; '169.254.1.1' = $true; '203.0.113.5' = $false; '8.8.8.8' = $false
    '::1' = $true; 'fd12:3456::1' = $true; 'fe80::1%12' = $true; '2001:db8::1' = $false
  }
  foreach ($address in $privateCases.Keys) {
    Check "private: $address" (Test-PrivateAddress -Address $address) $privateCases[$address]
  }

  # 적용 전 경고 — DNS 조회와 포트 확인을 가짜로 바꿔(밖으로 나가지 않게) 판단만 본다. 이 뒤로는 진짜 함수를 쓰지 않는다.
  $script:fakeAddresses = @()
  $script:fakeBusyPort = 0
  function Resolve-WebDomain { param([string]$Domain) $script:fakeAddresses }
  function Get-PortUser { param([int]$Port) if ($Port -eq $script:fakeBusyPort) { 'httpd.exe (PID 1234)' } else { $null } }
  $warnings = @(Get-ApplyWarnings -Settings (New-Settings))
  Check 'warn: DNS에서 못 찾음 — 하나' $warnings.Count 1
  CheckContains 'warn: DNS에서 못 찾음' ($warnings -join ' / ') 'DNS에서 찾을 수 없습니다'
  $script:fakeAddresses = @('192.168.0.5', 'fd00::5')
  CheckContains 'warn: 사설 IP만' (@(Get-ApplyWarnings -Settings (New-Settings)) -join ' / ') '사설 IP(192.168.0.5, fd00::5)'
  $script:fakeAddresses = @('192.168.0.5', '203.0.113.5')
  Check 'warn: 공인 IP가 하나라도 있으면 없음' (@(Get-ApplyWarnings -Settings (New-Settings)).Count) 0
  $script:fakeBusyPort = 80
  $warnings = @(Get-ApplyWarnings -Settings (New-Settings))
  Check 'warn: 인증용 포트를 다른 프로그램이 씀 — 하나' $warnings.Count 1
  CheckContains 'warn: 인증용 포트를 다른 프로그램이 씀' ($warnings -join ' / ') '인증용 HTTP 포트 80을(를) 이 PC의 다른 프로그램이 쓰고 있습니다: httpd.exe (PID 1234)'
  Check 'warn: 인증용 포트 0이면 확인하지 않음' (@(Get-ApplyWarnings -Settings (New-Settings -Acme '0')).Count) 0
} finally {
  foreach ($item in $listeners) { try { $item.Stop() } catch { } }
  foreach ($item in $certificates) { try { $item.Dispose() } catch { } }
  if (Test-Path -LiteralPath $base) { [System.IO.Directory]::Delete($base, $true) }
}

''
foreach ($note in $script:notes) { "메모: $note" }
if ($script:failures.Count -gt 0) {
  $script:failures | ForEach-Object { "FAIL $_" }
  "통과 $($script:passed), 실패 $($script:failures.Count)"
  exit 1
}
"통과 $($script:passed), 실패 0"
exit 0
