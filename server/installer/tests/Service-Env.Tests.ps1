<#
.SYNOPSIS
  설치된 서버가 모든 시작 경로에서 NODE_ENV=production으로 도는지 확인하는 테스트 — 개발 PC 전용(설치 프로그램·업데이트 zip에는
  안 들어감). 관리자 권한 없이 돌고 아무 파일·레지스트리·서비스도 바꾸지 않는다 — 설치용 .ps1은 실행하지 않고 구문만 읽고,
  Set-NodeServiceProductionEnv만 꺼내 레지스트리 읽기·쓰기(Get-Item·Set-ItemProperty)를 이 테스트 안의 가짜 함수로 바꿔 돌린다.

.DESCRIPTION
  1) Setup-TangoTalkServer.ps1·Update-Server.ps1의 Set-NodeServiceProductionEnv가 같은지(주석·들여쓰기 제외), 두 스크립트에서
     서버 서비스($NodeServiceName)를 nssm으로 start/restart하는 곳마다 그 앞에 이 함수를 부르는지.
  2) 설치 폴더의 어떤 스크립트도 자기 환경 변수($env:NODE_ENV)를 바꾸지 않는지 — "서버 콘솔로 실행"(Start-ServerConsole.ps1)만
     예외로, node를 띄우기 전에 정확히 'production'으로 넣는지. (Setup/Update가 넣으면 같은 창의 npm install이 devDependencies를
     빼고 설치해 마이그레이션에 쓰는 drizzle-kit이 깨진다.)
  3) Set-NodeServiceProductionEnv가 NSSM의 서비스 매개변수 키(Parameters\AppEnvironmentExtra)에 쓰는 목록 — REG_MULTI_SZ로, 관리자가
     넣어 둔 다른 변수는 순서 그대로 남기고 있던 NODE_ENV 줄(대소문자 무관)은 빼고 NODE_ENV=production 한 줄만 끝에 붙이는지, 값이
     문자열 하나여도 되는지, 서비스 키가 없으면 만들지 않고 $false인지, 쓰기에 실패하면 $false인지, 결과가 bool 하나인지.

  사용법(저장소 루트): powershell -NoProfile -ExecutionPolicy Bypass -File server\installer\tests\Service-Env.Tests.ps1
  실패가 하나라도 있으면 종료 코드 1.
#>

$ErrorActionPreference = 'Stop'
$installerDir = Split-Path $PSScriptRoot -Parent
$functionName = 'Set-NodeServiceProductionEnv'
$serviceScripts = @('Setup-TangoTalkServer.ps1', 'Update-Server.ps1')

$script:passed = 0
$script:failures = New-Object System.Collections.Generic.List[string]
function Check([string]$Name, $Actual, $Expected) {
  if ("$Actual" -ceq "$Expected") { $script:passed++ } else { $script:failures.Add("$Name -> [$Actual], 기대값 [$Expected]") }
}

# 주석·줄바꿈을 뺀 토큰열 — 스크립트마다 들여쓰기(2칸/4칸)와 주석이 달라도 코드가 같으면 같다(Admin-Verify.Tests.ps1과 같음).
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

# ── 1) 두 스크립트의 함수와, 서버 서비스를 띄우기 전에 부르는지 ──────────────────
$functionTexts = [ordered]@{}
$firstTokens = $null
foreach ($name in $serviceScripts) {
  $ast = Read-ScriptAst $name
  $defs = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $functionName }, $true))
  Check "fn: $name 에 $functionName 정의가 하나" $defs.Count 1
  if ($defs.Count -ne 1) { continue }
  $def = $defs[0]
  $functionTexts[$name] = $def.Extent.Text
  $tokens = Get-CodeTokens $def.Extent.Text
  if ($null -eq $firstTokens) { $firstTokens = $tokens } else {
    Check "fn: $name 의 $functionName 이(가) $($serviceScripts[0])의 것과 같음(주석·들여쓰기 제외)" ($tokens -ceq $firstTokens) $true
  }
  $outside = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | Where-Object {
      $_.Extent.StartOffset -gt $def.Extent.EndOffset -or $_.Extent.EndOffset -lt $def.Extent.StartOffset })
  # 서버 서비스를 nssm으로 start/restart하는 곳과 이 함수를 부르는 곳을 파일 순서대로 늘어놓고, 띄울 때마다 바로 앞(이전에
  # 띄운 곳 뒤)에 함수 호출이 있는지 본다.
  $events = @($outside | Where-Object {
      ($_.GetCommandName() -eq $functionName) -or
      ($_.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
        $_.CommandElements[0].Extent.Text -eq '$NssmExe' -and $_.CommandElements.Count -ge 3 -and
        @('start', 'restart') -contains $_.CommandElements[1].Extent.Text -and $_.CommandElements[2].Extent.Text -eq '$NodeServiceName')
    } | Sort-Object { $_.Extent.StartOffset })
  $starts = 0
  $covered = $false
  foreach ($event in $events) {
    if ($event.GetCommandName() -eq $functionName) { $covered = $true; continue }
    $starts++
    Check "order: $name 줄 $($event.Extent.StartLineNumber)의 nssm $($event.CommandElements[1].Extent.Text) 앞에 $functionName" $covered $true
    $covered = $false
  }
  Check "order: $name 에 서버 서비스를 띄우는 곳이 있음" ($starts -gt 0) $true
}

# ── 2) $env:NODE_ENV는 Start-ServerConsole.ps1만, node를 띄우기 전에 ───────────
foreach ($file in @(Get-ChildItem -LiteralPath $installerDir -Filter '*.ps1' -File)) {
  $ast = Read-ScriptAst $file.Name
  $assignments = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -match '^\$env:NODE_ENV$' }, $true))
  if ($file.Name -ne 'Start-ServerConsole.ps1') {
    Check "env: $($file.Name) 은(는) 자기 환경 변수 NODE_ENV를 바꾸지 않음" $assignments.Count 0
    continue
  }
  Check 'console: Start-ServerConsole.ps1 이(가) NODE_ENV를 한 번 넣음' $assignments.Count 1
  if ($assignments.Count -ne 1) { continue }
  Check 'console: 넣는 값이 production' $assignments[0].Right.Extent.Text "'production'"
  $nodeCalls = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
        $n.CommandElements[0].Extent.Text -eq '$NodeExe' }, $true))
  Check 'console: node 실행이 하나' $nodeCalls.Count 1
  foreach ($call in $nodeCalls) {
    Check 'console: node를 띄우기 전에 NODE_ENV를 넣음' ($assignments[0].Extent.StartOffset -lt $call.Extent.StartOffset) $true
  }
}

# ── 3) 레지스트리에 쓰는 목록 ─────────────────────────────────────────────────
# 함수가 부르는 Get-Item·Set-ItemProperty를 이 테스트 안의 가짜로 바꾼다 — PowerShell은 같은 이름이면 cmdlet보다 함수를 먼저
# 찾는다. 그래서 진짜 레지스트리는 읽지도 쓰지도 않는다.
$NodeServiceName = 'TangoTalkServer'
$script:fakeCurrent = $null
$script:fakeKeyMissing = $false
$script:fakeWriteFails = $false
$script:reads = New-Object System.Collections.Generic.List[string]
$script:writes = New-Object System.Collections.Generic.List[string]
function Get-Item {
  param([string]$LiteralPath, $ErrorAction)
  $script:reads.Add($LiteralPath)
  if ($script:fakeKeyMissing) { throw "가짜: 키 없음($LiteralPath)" }
  $key = New-Object psobject
  $key | Add-Member -MemberType ScriptMethod -Name GetValue -Value {
    param($valueName)
    if ($valueName -eq 'AppEnvironmentExtra') { return $script:fakeCurrent }
    return $null
  }
  return $key
}
function Set-ItemProperty {
  param([string]$LiteralPath, [string]$Name, $Value, $Type, $ErrorAction)
  if ($script:fakeWriteFails) { throw '가짜: 쓰기 실패' }
  $script:writes.Add("$LiteralPath|$Name|$Type|$($Value.GetType().Name)|" + (@($Value | ForEach-Object { "<$_>" }) -join ' '))
}
function Invoke-EnvCase($Current, [switch]$KeyMissing, [switch]$WriteFails) {
  $script:reads.Clear()
  $script:writes.Clear()
  $script:fakeCurrent = $Current
  $script:fakeKeyMissing = [bool]$KeyMissing
  $script:fakeWriteFails = [bool]$WriteFails
  $result = @(Set-NodeServiceProductionEnv)
  return [pscustomobject]@{ Result = "$($result.Count)/$($result -join ',')"; Reads = ($script:reads -join ' | '); Writes = ($script:writes -join ' | ') }
}

$serviceKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\TangoTalkServer\Parameters'
$prefix = "$serviceKey|AppEnvironmentExtra|MultiString|String[]|"
foreach ($name in $functionTexts.Keys) {
  . ([scriptblock]::Create($functionTexts[$name]))

  $case = Invoke-EnvCase $null
  Check "${name}: 값이 없으면 NODE_ENV=production 한 줄(REG_MULTI_SZ)" $case.Writes "$prefix<NODE_ENV=production>"
  Check "${name}: 결과는 bool 하나(성공)" $case.Result '1/True'
  Check "${name}: NSSM 서비스 매개변수 키를 읽음" $case.Reads $serviceKey

  $case = Invoke-EnvCase @('HTTPS_PROXY=http://proxy:8080', 'FOO=a b', 'NODE_ENV=development', 'node_env=test', 'NODE_OPTIONS=--max-old-space-size=4096')
  Check "${name}: 다른 변수는 순서 그대로 두고 NODE_ENV 줄만 바꿈" $case.Writes "$prefix<HTTPS_PROXY=http://proxy:8080> <FOO=a b> <NODE_OPTIONS=--max-old-space-size=4096> <NODE_ENV=production>"

  $case = Invoke-EnvCase @('NODE_ENV=production')
  Check "${name}: 이미 production이어도 한 줄만" $case.Writes "$prefix<NODE_ENV=production>"

  $case = Invoke-EnvCase 'FOO=1'
  Check "${name}: 값이 문자열 하나여도 남김" $case.Writes "$prefix<FOO=1> <NODE_ENV=production>"

  $case = Invoke-EnvCase @('', 'BAR=2')
  Check "${name}: 빈 줄은 버림" $case.Writes "$prefix<BAR=2> <NODE_ENV=production>"

  $case = Invoke-EnvCase $null -KeyMissing
  Check "${name}: 서비스 키가 없으면 만들지 않고 실패" "$($case.Result)/$($case.Writes)" '1/False/'

  $case = Invoke-EnvCase @('FOO=1') -WriteFails
  Check "${name}: 쓰기에 실패하면 `$false" $case.Result '1/False'
}

''
if ($script:failures.Count -gt 0) {
  $script:failures | ForEach-Object { "FAIL $_" }
  "통과 $($script:passed), 실패 $($script:failures.Count)"
  exit 1
}
"통과 $($script:passed), 실패 0"
exit 0
