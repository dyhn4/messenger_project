<#
.SYNOPSIS
  운영자 확인(Test-ServerAdminPassword — Reset-Data.ps1·Restore-Data.ps1·Uninstall-Full.ps1)이 비밀번호를 node에 글자 그대로
  넘기는지 확인하는 테스트 — 개발 PC 전용(설치 프로그램·업데이트 zip에는 안 들어감). 관리자 권한 없이 돌고, %TEMP% 안에 만든
  임시 폴더만 만들고 지운다. 실제 DB·.env·서비스·설치 폴더는 손대지 않고, 세 스크립트는 실행하지 않고 그 함수만 꺼내 쓴다.

.DESCRIPTION
  진짜 server\scripts\verify-admin.mjs를 임시 폴더(가짜 서버 폴더)에 복사하고, 그 옆 node_modules에 가짜 pg(정해 둔 운영자 한
  명만 돌려줌)·dotenv(아무것도 안 읽음)·bcryptjs(받은 비밀번호를 코드 포인트로 파일에 적고, 정해 둔 비밀번호와 글자 그대로
  같은지만 봄)를 둔다 — server\test\verifyAdminStdin.test.js와 같은 방식(그쪽은 verify-admin.mjs의 stdin 규칙을 바이트 단위로 본다).
  1) 세 스크립트의 Test-ServerAdminPassword가 같은지(주석·들여쓰기는 빼고), 세 스크립트가 그 함수를 한 번씩만 부르고 그 밖에서는
     verify-admin.mjs를 부르거나 node에 파이프로 무엇을 넘기지 않는지.
  2) 이 창의 $OutputEncoding을 Windows PowerShell 5.1 기본값(ASCII)으로 둔 채, 세 스크립트의 함수를 하나씩 꺼내:
     - 예전 방식(그냥 파이프)은 한글이 '?'로 바뀌어 실패한다 — 이 테스트가 그 버그를 실제로 재현하는지,
     - 한글·이모지·앞뒤 공백·따옴표가 든 비밀번호와 한글 아이디를 글자 그대로 넘겨 통과하고, 틀린 비밀번호·없는 아이디는
       실패하며, 결과는 bool 하나이고(node가 stdout에 무엇을 써도), 끝난 뒤 이 창의 $OutputEncoding·현재 위치가 그대로인지,
     - node를 실행하지 못하면(예전 $LASTEXITCODE가 0으로 남아 있어도) 예외 없이 실패인지.

  사용법(저장소 루트): powershell -NoProfile -ExecutionPolicy Bypass -File server\installer\tests\Admin-Verify.Tests.ps1
  node가 PATH에 있어야 한다. 실패가 하나라도 있으면 종료 코드 1.
#>

$ErrorActionPreference = 'Stop'
$installerDir = Split-Path $PSScriptRoot -Parent
$verifySource = Join-Path (Split-Path $installerDir -Parent) 'scripts\verify-admin.mjs'
$scriptNames = @('Reset-Data.ps1', 'Restore-Data.ps1', 'Uninstall-Full.ps1')
$functionName = 'Test-ServerAdminPassword'

$script:passed = 0
$script:failures = New-Object System.Collections.Generic.List[string]
function Check([string]$Name, $Actual, $Expected) {
  if ("$Actual" -ceq "$Expected") { $script:passed++ } else { $script:failures.Add("$Name -> [$Actual], 기대값 [$Expected]") }
}

# 주석·줄바꿈을 뺀 토큰열 — 스크립트마다 들여쓰기(2칸/4칸)와 주석이 달라도 코드가 같으면 같다.
function Get-CodeTokens([string]$Text) {
  $tokens = $null
  $parseErrors = $null
  [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
  $kinds = @('Comment', 'NewLine', 'LineContinuation', 'EndOfInput')
  (@($tokens) | Where-Object { $kinds -notcontains "$($_.Kind)" } | ForEach-Object { $_.Text }) -join ' '
}

# 문자열의 코드 포인트(16진수, 쉼표로 이음) — 이모지처럼 BMP 밖 글자도 한 글자로 센다(가짜 bcryptjs가 적는 형식과 같다).
function Get-CodePoints([string]$Text) {
  $points = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $Text.Length; $i++) {
    $codePoint = [char]::ConvertToUtf32($Text, $i)
    if ($codePoint -gt 0xFFFF) { $i++ }
    $points.Add(('{0:x}' -f $codePoint))
  }
  $points -join ','
}

# ── 1) 세 스크립트의 함수와 부르는 곳 ─────────────────────────────────────────
$functionTexts = [ordered]@{}
$firstTokens = $null
foreach ($name in $scriptNames) {
  $parseErrors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $installerDir $name), [ref]$null, [ref]$parseErrors)
  Check "parse: $name 구문 오류 없음" (@($parseErrors).Count) 0
  $defs = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $functionName }, $true))
  Check "fn: $name 에 $functionName 정의가 하나" $defs.Count 1
  if ($defs.Count -ne 1) { continue }
  $def = $defs[0]
  $functionTexts[$name] = $def.Extent.Text
  $tokens = Get-CodeTokens $def.Extent.Text
  if ($null -eq $firstTokens) { $firstTokens = $tokens } else {
    Check "fn: $name 의 $functionName 이(가) $($scriptNames[0])의 것과 같음(주석·들여쓰기 제외)" ($tokens -ceq $firstTokens) $true
  }
  $outside = @($ast.FindAll({ param($n) $true }, $true) | Where-Object {
      $_.Extent.StartOffset -lt $def.Extent.StartOffset -or $_.Extent.EndOffset -gt $def.Extent.EndOffset })
  $calls = @($outside | Where-Object { $_ -is [System.Management.Automation.Language.CommandAst] -and $_.GetCommandName() -eq $functionName })
  Check "call: $name 이(가) $functionName 을(를) 한 번 부름" $calls.Count 1
  $verifyRefs = @($outside | Where-Object {
      ($_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $_ -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and $_.Value -match 'verify-admin' })
  Check "call: $name 은(는) 함수 밖에서 verify-admin.mjs를 부르지 않음" $verifyRefs.Count 0
  $nodePipes = @($outside | Where-Object {
      $_ -is [System.Management.Automation.Language.PipelineAst] -and
      @($_.PipelineElements | Select-Object -Skip 1 | Where-Object {
          $_ -is [System.Management.Automation.Language.CommandAst] -and $_.CommandElements[0].Extent.Text -eq '$NodeExe' }).Count -gt 0 })
  Check "call: $name 은(는) 함수 밖에서 node에 파이프로 넘기지 않음" $nodePipes.Count 0
}

# ── 2) 가짜 서버 폴더에서 실제로 돌려 보기 ───────────────────────────────────
$nodeCommand = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $nodeCommand) { throw 'node를 PATH에서 찾지 못했습니다 — Node.js를 설치하거나 PATH에 넣은 뒤 다시 실행하세요.' }
$nodeExe = $nodeCommand.Source

$base = Join-Path $env:TEMP ('tt-admin-verify-' + [guid]::NewGuid().ToString('N'))
$fakeServer = Join-Path $base 'server'
$receivedFile = Join-Path $base 'received.txt'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
function Write-TestFile([string]$Path, [string]$Text) {
  [void][System.IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
  [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}
function Write-FakePackage([string]$Name, [string]$Source) {
  $dir = Join-Path $fakeServer "node_modules\$Name"
  Write-TestFile (Join-Path $dir 'package.json') ('{"name":"' + $Name + '","type":"module","exports":"./index.js"}')
  Write-TestFile (Join-Path $dir 'index.js') $Source
}
function Read-Received {
  if (Test-Path -LiteralPath $receivedFile) { return [System.IO.File]::ReadAllText($receivedFile) }
  return '(비교 안 함)'
}

$admin = '운영자kim'
# 한글·악센트·BMP 밖 글자(이모지)·앞뒤 공백 — 앞뒤 공백까지 비밀번호다.
$password = ' 한글비번 Pässwörd 🔑 끝 '
$envNames = @('DATABASE_URL', 'TT_TEST_ADMIN_USER', 'TT_TEST_ADMIN_PASSWORD', 'TT_TEST_RECEIVED_FILE', 'TT_TEST_STDOUT_NOISE')
$savedEnv = @{}
foreach ($envName in $envNames) { $savedEnv[$envName] = [Environment]::GetEnvironmentVariable($envName, 'Process') }
$savedOutputEncoding = $OutputEncoding

try {
  [void][System.IO.Directory]::CreateDirectory((Join-Path $fakeServer 'scripts'))
  Copy-Item -LiteralPath $verifySource -Destination (Join-Path $fakeServer 'scripts\verify-admin.mjs')
  Write-FakePackage 'dotenv' "export default { config: () => ({ parsed: {} }) };`n"
  Write-FakePackage 'pg' @'
class Client {
  async connect() {}
  async query(_sql, params) {
    if (params[0] !== process.env.TT_TEST_ADMIN_USER) return { rows: [] };
    return { rows: [{ password_hash: 'fake-hash', is_server_admin: true, deleted_at: null, suspended_at: null }] };
  }
  async end() {}
}
export default { Client };
'@
  Write-FakePackage 'bcryptjs' @'
import fs from 'node:fs';
export default {
  async compare(password, hash) {
    fs.writeFileSync(process.env.TT_TEST_RECEIVED_FILE, [...password].map((c) => c.codePointAt(0).toString(16)).join(','));
    if (process.env.TT_TEST_STDOUT_NOISE) process.stdout.write('stdout noise from fake bcryptjs\n');
    return hash === 'fake-hash' && password === process.env.TT_TEST_ADMIN_PASSWORD;
  },
};
'@
  # 혹시 가짜 pg 대신 진짜가 쓰이더라도 닿지 않는 주소로 접속하다 실패하게 둔다.
  $env:DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused'
  $env:TT_TEST_ADMIN_USER = $admin
  $env:TT_TEST_RECEIVED_FILE = $receivedFile
  $env:TT_TEST_STDOUT_NOISE = $null

  # Windows PowerShell 5.1 기본값과 같게 둔다(PowerShell 7에서 돌려도 같은 조건이 되게).
  $OutputEncoding = [System.Text.ASCIIEncoding]::new()

  # 예전 방식 — 이 테스트가 버그를 실제로 재현하는지(한글·이모지가 '?'로 바뀌어 실패해야 한다).
  $env:TT_TEST_ADMIN_PASSWORD = $password
  Remove-Item -LiteralPath $receivedFile -ErrorAction SilentlyContinue
  Push-Location -LiteralPath $fakeServer
  try {
    $password | & $nodeExe (Join-Path $fakeServer 'scripts\verify-admin.mjs') $admin | Out-Host
    $oldOk = ($LASTEXITCODE -eq 0)
  } finally {
    Pop-Location
  }
  $asciiRoundTrip = [System.Text.Encoding]::ASCII.GetString([System.Text.Encoding]::ASCII.GetBytes($password))
  Check "old: 예전 방식(그냥 파이프)은 맞는 비밀번호도 실패" $oldOk $false
  Check "old: 예전 방식은 한글·이모지를 '?'로 보냄" (Read-Received) (Get-CodePoints $asciiRoundTrip)

  foreach ($name in $functionTexts.Keys) {
    . ([scriptblock]::Create($functionTexts[$name]))
    # 세 스크립트는 $ErrorActionPreference를 바꾸지 않으므로(기본값 Continue) 함수도 그 조건에서 부른다.
    function Invoke-Case([string]$User, [string]$Typed) {
      $ErrorActionPreference = 'Continue'
      Remove-Item -LiteralPath $receivedFile -ErrorAction SilentlyContinue
      $secure = ConvertTo-SecureString -String $Typed -AsPlainText -Force
      return @(Test-ServerAdminPassword -NodeExe $nodeExe -ServerDir $fakeServer -Username $User -Password $secure)
    }

    $locationBefore = (Get-Location).Path
    $env:TT_TEST_ADMIN_PASSWORD = $password
    $env:TT_TEST_STDOUT_NOISE = '1'
    $result = Invoke-Case $admin $password
    $env:TT_TEST_STDOUT_NOISE = $null
    Check "${name}: 한글·이모지·앞뒤 공백 비밀번호 + 한글 아이디 → 통과" "$result" 'True'
    Check "${name}: 결과는 bool 하나(node가 stdout에 써도)" "$($result.Count)/$($result[0] -is [bool])" '1/True'
    Check "${name}: verify-admin.mjs가 받은 글자가 친 그대로" (Read-Received) (Get-CodePoints $password)
    Check "${name}: 끝난 뒤 이 창의 `$OutputEncoding 그대로" $OutputEncoding.WebName 'us-ascii'
    Check "${name}: 끝난 뒤 현재 위치 그대로" (Get-Location).Path $locationBefore

    Check "${name}: 틀린 비밀번호 → 실패" "$(Invoke-Case $admin '한글비번')" 'False'
    Check "${name}: 틀린 비밀번호도 글자 그대로 넘어감" (Read-Received) (Get-CodePoints '한글비번')
    Check "${name}: 없는 아이디 → 실패(비교 안 함)" "$(Invoke-Case '운영자lee' $password)/$(Read-Received)" 'False/(비교 안 함)'

    # 따옴표·역슬래시·$·백틱 — stdin으로 넘기므로 명령줄 따옴표 처리(PowerShell 5.1이 큰따옴표를 지움)와 상관없다.
    $tricky = 'a"b\c$d`e''f'
    $env:TT_TEST_ADMIN_PASSWORD = $tricky
    Check "${name}: 따옴표·역슬래시가 든 비밀번호 → 통과" "$(Invoke-Case $admin $tricky)" 'True'
    $env:TT_TEST_ADMIN_PASSWORD = 'Plain-ASCII_pw!'
    Check "${name}: 영문만 든 비밀번호 → 통과" "$(Invoke-Case $admin 'Plain-ASCII_pw!')" 'True'

    # node를 실행하지 못하면 $LASTEXITCODE가 예전 값 그대로라 0이 남아 있어도 통과로 보면 안 된다.
    $global:LASTEXITCODE = 0
    $missing = $null
    try {
      $missing = @(& {
          $ErrorActionPreference = 'Continue'
          Test-ServerAdminPassword -NodeExe (Join-Path $base 'no-such-node.exe') -ServerDir $fakeServer -Username $admin `
            -Password (ConvertTo-SecureString -String 'Plain-ASCII_pw!' -AsPlainText -Force) 6>$null
        })
    } catch {
      $missing = "예외: $($_.Exception.Message)"
    }
    Check "${name}: node를 실행하지 못하면 예외 없이 실패" "$missing" 'False'
    Check "${name}: node를 실행하지 못해도 현재 위치 그대로" (Get-Location).Path $locationBefore
  }
} finally {
  $OutputEncoding = $savedOutputEncoding
  foreach ($envName in $envNames) { [Environment]::SetEnvironmentVariable($envName, $savedEnv[$envName], 'Process') }
  if (Test-Path -LiteralPath $base) { [System.IO.Directory]::Delete($base, $true) }
}

''
if ($script:failures.Count -gt 0) {
  $script:failures | ForEach-Object { "FAIL $_" }
  "통과 $($script:passed), 실패 $($script:failures.Count)"
  exit 1
}
"통과 $($script:passed), 실패 0"
exit 0
