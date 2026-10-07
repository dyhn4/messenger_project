<#
.SYNOPSIS
  설치 프로그램(messenger-server.iss)의 "설치 전 폴더 검증"과 설치 폴더 루트 스크립트 구성 확인용 테스트 — 개발 PC
  전용(설치 프로그램·업데이트 zip에는 안 들어감). 관리자 권한 없이 돌고, %TEMP% 안에 만든 임시 폴더만 만들고 지운다
  (실제 설치 폴더·서비스·DB는 손대지 않고, 설치용 .ps1은 실행하지 않고 구문만 읽는다. 시스템 폴더와 C:\ 바로 아래
  폴더는 권한을 읽기만 한다).

.DESCRIPTION
  1) PrepareToInstall의 기존 폴더 검사(CheckExistingAppDir) — 이 PC에 ISCC(Inno Setup)가 없어도 확인할 수 있게,
     messenger-server.iss의 AppDirCheckParams 상수를 그대로 꺼내 Inno의 Exec와 같은 방식(powershell.exe 전체 경로 +
     그 인자 문자열 하나, 작업 폴더 System32)으로 실제로 실행해 본다.
     - [Code]의 결과 코드 상수(AppDir*)와 명령의 exit 코드, 쓰기류 권한 마스크(이름 붙은 권한 값으로 따로 계산)가 맞는지.
     - 따옴표 처리: 작은따옴표·굽은 작은따옴표·$·`·;·[ ]·한글이 든 폴더 이름에서도 내가 만든 폴더는 "다른 소유자"(2)여야
       하고(따옴표 처리가 틀리면 구문 오류 1이나 경로가 잘린 3 같은 다른 값이 나온다), PsQuoteLiteral로 감싼 문자열을
       PowerShell 파서가 "원래 이름 그대로인 문자열 하나"로 읽어야 한다. 없는 경로는 3. PsQuoteLiteral(Pascal)은 여기서
       돌릴 수 없어서 같은 규칙을 PowerShell로 옮겨 쓴다 — 한쪽을 고치면 다른 쪽도 고칠 것.
     - 권한 판정: 일반 권한 토큰은 소유자를 Administrators로 만들 수 없으므로, 받아들이는 계정 목록($ok)에 내 계정을 더한
       명령으로 권한을 정해 둔 임시 폴더를 돌린다 — 다른 계정에 쓰기류 권한(수정·쓰기·추가·특성 쓰기·삭제·권한 변경·
       소유권, 상속 전용 항목, 일반 권한 비트, 물려받은 항목)이 있으면 4, 읽기·실행 항목과 거부 항목뿐이면 0. 잠금 전 모양의
       설치 폴더가 4였다가 Folder-Acl.ps1의 Protect-InstallDir로 잠근 뒤 0이 되는지(잠긴 폴더는 확인 창 없이 통과)도 본다.
     - 이 PC의 시스템 폴더와 C:\ 바로 아래 폴더: 이 프로세스에서 읽은 실제 소유자·권한으로 기대값을 따로 계산해 비교한다.
     링크 검사(DirIsReparsePoint)가 쓰는 GetFileAttributesW가 끊어진 정션도 링크로 보는지도 확인한다.
  2) 설치 폴더 루트의 *.ps1이 전부 [Files]에 있는지(하나씩 적어야 설치된다), [Icons]/[Run]이 가리키는 스크립트가
     실제로 있는지.
  3) 일반 권한으로 열리는 관리 스크립트(시작 메뉴·탐색기)가 맨 처음에 스스로 관리자 권한으로 승격하는지 — 설치 폴더가
     관리자 전용이라(Folder-Acl.ps1) 승격 전에는 node.exe·.env·서버 코드를 못 읽는다 — 그리고 node를 부르기 전에 서버
     폴더로 이동하는지(dotenv/config를 쓰는 서버 스크립트는 .env를 "현재 폴더"에서 읽는데, 승격된 PowerShell은
     System32에서 시작한다).

  사용법(저장소 루트): powershell -NoProfile -ExecutionPolicy Bypass -File server\installer\tests\Install-Guard.Tests.ps1
  실패가 하나라도 있으면 종료 코드 1.
#>

$ErrorActionPreference = 'Stop'
$installerDir = Split-Path $PSScriptRoot -Parent
$issPath = Join-Path $installerDir 'messenger-server.iss'
$folderAcl = Join-Path $installerDir 'Folder-Acl.ps1'
# messenger-server.iss는 BOM 없는 UTF-8이다.
$iss = [System.IO.File]::ReadAllText($issPath, [System.Text.Encoding]::UTF8)

$script:passed = 0
$script:failures = New-Object System.Collections.Generic.List[string]
$script:notes = New-Object System.Collections.Generic.List[string]
function Check([string]$Name, $Actual, $Expected) {
  if ("$Actual" -ceq "$Expected") { $script:passed++ } else { $script:failures.Add("$Name -> [$Actual], 기대값 [$Expected]") }
}

# Folder-Acl.ps1은 실행하지 않고 함수 정의와 $Acl* 상수만 꺼내 쓴다(Folder-Acl.Tests.ps1과 같은 방식).
function Import-FolderAcl {
  $parseErrors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($folderAcl, [ref]$null, [ref]$parseErrors)
  if ($parseErrors) { throw "Folder-Acl.ps1 구문 오류: $parseErrors" }
  foreach ($stmt in $ast.EndBlock.Statements) {
    $isFunction = $stmt -is [System.Management.Automation.Language.FunctionDefinitionAst]
    $isConstant = ($stmt -is [System.Management.Automation.Language.AssignmentStatementAst]) -and ($stmt.Left.Extent.Text -like '$Acl*')
    if (-not ($isFunction -or $isConstant)) { throw "Folder-Acl.ps1 최상위에 함수/상수가 아닌 문장이 있습니다: $($stmt.Extent.Text)" }
    . ([scriptblock]::Create($stmt.Extent.Text))
  }
}
# 함수 안에서 dot-source한 정의는 그 함수가 끝나면 사라지므로, 함수 호출 자체를 dot-source해서 이 스코프에 남긴다.
. Import-FolderAcl
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
# 일반 권한 토큰에서 Administrators는 "거부 전용"이라, 이 테스트 안에서만 잠금 대상 SID를 내 계정으로 바꿔 끼운다
# (Folder-Acl.Tests.ps1과 같은 치환 — 실제 설치에서는 *S-1-5-32-544).
$AclSidAdmins = $me

$systemDir = [Environment]::SystemDirectory
$psExe = Join-Path $systemDir 'WindowsPowerShell\v1.0\powershell.exe'
$icaclsExe = Join-Path $systemDir 'icacls.exe'

# ── 1) 기존 폴더 검사 명령 ─────────────────────────────────────────────────
# Pascal 문자열 상수에서는 작은따옴표를 두 번 쓴다('') — 꺼낸 뒤 하나로 되돌린다.
if ($iss -notmatch "(?m)^\s*AppDirCheckParams\s*=\s*'((?:[^']|'')*)';\s*$") { throw 'messenger-server.iss에서 AppDirCheckParams 상수를 찾지 못했습니다.' }
$checkParams = $Matches[1].Replace("''", "'")
Check 'iss: 인자에 @DIR@ 자리가 하나' ([regex]::Matches($checkParams, '@DIR@').Count) 1
Check 'iss: 인자 안에 큰따옴표는 -Command "..." 한 쌍뿐' ([regex]::Matches($checkParams, '"').Count) 2
# [Code]의 결과 코드 상수와 명령의 exit 코드가 서로 맞는지.
$codes = [ordered]@{ AppDirLocked = 0; AppDirOtherOwner = 2; AppDirUnreadable = 3; AppDirAdminShared = 4 }
foreach ($name in $codes.Keys) {
  Check "iss: $name 상수" ([regex]::Match($iss, "(?m)^\s*$name\s*=\s*(-?\d+)\s*;").Groups[1].Value) $codes[$name]
  Check "iss: 명령에 exit $($codes[$name])이 하나" ([regex]::Matches($checkParams, "\bexit $($codes[$name])\b").Count) 1
}
# 쓰기류 권한 마스크 — 이름 붙은 권한 값으로 따로 계산한 값과 같아야 한다(일반 권한 GENERIC_ALL 0x10000000·GENERIC_WRITE
# 0x40000000 포함 — 상속 전용 항목에는 일반 권한 비트가 그대로 남는다).
$writeMask = [int][System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, DeleteSubdirectoriesAndFiles, WriteAttributes, Delete, ChangePermissions, TakeOwnership'
$writeMask = $writeMask -bor 0x10000000 -bor 0x40000000
$maskHex = [regex]::Match($checkParams, '-band 0x([0-9A-Fa-f]+)\b').Groups[1].Value
Check 'iss: 쓰기류 권한 마스크' $(if ($maskHex) { '{0:X8}' -f [Convert]::ToInt32($maskHex, 16) }) ('{0:X8}' -f $writeMask)
# 권한 판정만 따로 볼 때 쓰는 명령 — 받아들이는 계정 목록($ok)에 내 계정을 더한다(일반 권한 토큰은 소유자를 Administrators로
# 만들 수 없어서, 내가 만든 임시 폴더는 원래 명령으로는 늘 "다른 소유자"(2)에서 끝난다).
$okText = "`$ok = @('S-1-5-32-544', 'S-1-5-18')"
Check 'iss: 받아들이는 계정 목록($ok)이 한 곳' ([regex]::Matches($checkParams, [regex]::Escape($okText)).Count) 1
$checkParamsTrustMe = $checkParams.Replace($okText, "`$ok = @('S-1-5-32-544', 'S-1-5-18', '$me')")

# messenger-server.iss의 PsQuoteLiteral과 같은 규칙 — ' 와 U+2018~U+201B를 두 번 쓰고 작은따옴표로 감싼다.
function PsQuoteLiteral([string]$S) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append("'")
  foreach ($ch in $S.ToCharArray()) {
    $code = [int]$ch
    if ($code -eq 39 -or ($code -ge 0x2018 -and $code -le 0x201B)) { [void]$sb.Append($ch) }
    [void]$sb.Append($ch)
  }
  [void]$sb.Append("'")
  return $sb.ToString()
}

# Inno의 Exec처럼 "실행 파일" + 인자 문자열 하나로 프로세스를 만든다(PowerShell의 & 호출은 인자를 다시 따옴표 처리해서
# Inno와 같은 명령줄이 되지 않는다).
function Invoke-DirCheck([string]$Dir, [switch]$TrustMe) {
  $params = if ($TrustMe) { $checkParamsTrustMe } else { $checkParams }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe
  $psi.Arguments = $params.Replace('@DIR@', (PsQuoteLiteral $Dir))
  $psi.WorkingDirectory = $systemDir
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $p.WaitForExit()
  return $p.ExitCode
}

# PC마다 다른 폴더(시스템 폴더 등)의 기대값 — 이 프로세스에서 읽은 실제 소유자·권한에 같은 규칙을 적용한다(쓰기류 권한은
# 위에서 이름으로 계산한 $writeMask).
function Get-ExpectedDirCheck([string]$Dir) {
  $trusted = @('S-1-5-32-544', 'S-1-5-18')
  try {
    $acl = Get-Acl -LiteralPath $Dir
    $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
  } catch {
    return 3
  }
  if ($trusted -notcontains $owner) { return 2 }
  foreach ($rule in $rules) {
    if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
    if ($trusted -contains $rule.IdentityReference.Value) { continue }
    if (([int]$rule.FileSystemRights -band $writeMask) -ne 0) { return 4 }
  }
  return 0
}

# 테스트 준비용 icacls — 이 함수 안에서만 'Continue'(PowerShell 5.1은 'Stop'이면 네이티브 stderr 한 줄을 곧바로 예외로 바꾼다).
function Invoke-TestIcacls([string[]]$Arguments) {
  $ErrorActionPreference = 'Continue'
  $out = & $icaclsExe @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw "테스트 준비 실패: icacls $($Arguments -join ' ') — $out" }
}
# 권한 판정용 임시 폴더 — 상속을 끊고 SYSTEM·Administrators·내 계정 전체 권한만 둔 "깨끗한" 상태에서 시작한다(%TEMP%가
# 물려주는 항목은 PC마다 다를 수 있어서).
function New-CleanDir([string]$Path) {
  [void][System.IO.Directory]::CreateDirectory($Path)
  Invoke-TestIcacls @($Path, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', "*${me}:(OI)(CI)F")
}
# icacls는 일반 권한(GW 등)을 구체적인 권한으로 바꿔 저장하므로, 상속 전용 항목에 일반 권한 비트를 그대로 남기려면 SDDL로
# 넣는다(직접 붙은 항목이 앞에 오도록 DACL 맨 앞에).
function Add-SddlAce([string]$Path, [string]$Ace) {
  $access = [System.Security.AccessControl.AccessControlSections]::Access
  $di = New-Object System.IO.DirectoryInfo($Path)
  $sec = $di.GetAccessControl($access)
  $sddl = [regex]::Replace($sec.GetSecurityDescriptorSddlForm($access), '^(D:[A-Z]*)', ('$1' + $Ace))
  $sec.SetSecurityDescriptorSddlForm($sddl, $access)
  $di.SetAccessControl($sec)
}

Add-Type -Namespace TangoTalkInstallGuardTest -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern uint GetFileAttributesW(string lpFileName);
'@

$base = Join-Path $env:TEMP ("tangotalk-install-guard-test-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$target = Join-Path $base 'linktarget'
$link = Join-Path $base 'dangling'
try {
  [void][System.IO.Directory]::CreateDirectory($base)

  # 따옴표 처리 — 따옴표 처리가 틀리면 그 글자에서 경로 문자열이 끝나 뒷부분이 명령으로 읽힌다. 아래 폴더는 내가 만든
  # 폴더라 "다른 소유자"(2)여야 하고, 구문 오류(1)·경로가 잘림(3) 같은 다른 값이면 따옴표 처리가 틀린 것이다. 같은 경로를
  # PsQuoteLiteral로 감싼 문자열을 PowerShell 파서가 "원래 경로 그대로인 문자열 하나"로 읽는지도 따로 본다.
  $q = [char]0x2019
  $names = [ordered]@{
    '일반 폴더'                     = 'plain'
    '작은따옴표·[ ]·$·`·; ·한글'    = "it's [a] `$x ``tick; 한글 폴더"
    '작은따옴표 + 세미콜론'         = "x'; Write-Output y; 'z"
    '굽은 작은따옴표 + 세미콜론'    = "x$q; Write-Output y; ${q}z"
    '작은따옴표 + 괄호'             = "x'); Write-Output y; ('z"
    '굽은 작은따옴표 + 괄호'        = "x$q); Write-Output y; (${q}z"
    '굽은 따옴표 네 종류'           = "q$([char]0x2018)$([char]0x2019)$([char]0x201A)$([char]0x201B)q"
    '작은따옴표로 끝남'             = "trail'"
  }
  foreach ($label in $names.Keys) {
    $dir = Join-Path $base $names[$label]
    [void][System.IO.Directory]::CreateDirectory($dir)
    Check "quote: $label" (Invoke-DirCheck $dir) 2
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput('Write-Output ' + (PsQuoteLiteral $dir), [ref]$null, [ref]$parseErrors)
    $elements = @(@($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))[0].CommandElements)
    $isOneString = (@($parseErrors).Count -eq 0) -and ($elements.Count -eq 2) -and
      ($elements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and ($elements[1].Value -ceq $dir)
    Check "quote-parse: $label" $isOneString $true
  }
  Check 'quote: 없는 경로' (Invoke-DirCheck (Join-Path $base 'nope')) 3

  # 권한 판정 — 받아들이는 계정 목록에 내 계정을 더한 명령($checkParamsTrustMe)으로, 권한을 정해 둔 임시 폴더를 돌린다.
  # Grant = icacls /grant 인자, Deny = icacls /deny 인자, Sddl = DACL 맨 앞에 넣을 ACE.
  $aclCases = New-Object System.Collections.Generic.List[object]
  $aclCases.Add(@{ Label = '깨끗한 폴더(SYSTEM·Administrators·나만 전체 권한)'; Expected = 0 })
  $aclCases.Add(@{ Label = 'Users·NetworkService 읽기·실행(잠근 설치 폴더 루트와 같은 모양)'; Grant = @('*S-1-5-32-545:(RX)', '*S-1-5-20:(RX)'); Expected = 0 })
  $aclCases.Add(@{ Label = 'Authenticated Users 수정'; Grant = @('*S-1-5-11:(OI)(CI)M'); Expected = 4 })
  $aclCases.Add(@{ Label = 'Everyone 전체 권한'; Grant = @('*S-1-1-0:(F)'); Expected = 4 })
  $aclCases.Add(@{ Label = 'CREATOR OWNER 상속 전용 전체 권한'; Grant = @('*S-1-3-0:(OI)(CI)(IO)(F)'); Expected = 4 })
  foreach ($right in @('WD', 'AD', 'WEA', 'WA', 'DC', 'DE', 'WDAC', 'WO')) {
    $aclCases.Add(@{ Label = "Authenticated Users $right 하나"; Grant = @("*S-1-5-11:($right)"); Expected = 4 })
  }
  foreach ($right in @('RD', 'REA', 'X', 'RA', 'RC', 'S')) {
    $aclCases.Add(@{ Label = "Authenticated Users $right 하나(읽기류)"; Grant = @("*S-1-5-11:($right)"); Expected = 0 })
  }
  $aclCases.Add(@{ Label = 'Users 상속 전용 GENERIC_WRITE(일반 권한 비트 그대로)'; Sddl = '(A;OICIIO;GW;;;BU)'; Expected = 4 })
  $aclCases.Add(@{ Label = 'Users 상속 전용 GENERIC_ALL'; Sddl = '(A;OICIIO;GA;;;BU)'; Expected = 4 })
  $aclCases.Add(@{ Label = 'Users 상속 전용 GENERIC_READ·EXECUTE(음수가 되는 마스크)'; Sddl = '(A;OICIIO;GRGX;;;BU)'; Expected = 0 })
  $aclCases.Add(@{ Label = 'Guests 쓰기 거부(Deny) 항목만'; Deny = @('*S-1-5-32-546:(OI)(CI)(W)'); Expected = 0 })
  $i = 0
  foreach ($case in $aclCases) {
    $i++
    $dir = Join-Path $base "acl-$i"
    New-CleanDir $dir
    if ($case.Grant) { Invoke-TestIcacls (@($dir, '/grant') + $case.Grant) }
    if ($case.Deny) { Invoke-TestIcacls (@($dir, '/deny') + $case.Deny) }
    if ($case.Sddl) { Add-SddlAce $dir $case.Sddl }
    Check "acl: $($case.Label)" (Invoke-DirCheck $dir -TrustMe) $case.Expected
  }

  # C:\ 바로 아래 폴더처럼 위에서 물려받은(I) 항목도 본다. 원래 명령(받아들이는 계정에 나 없음)으로는 같은 권한이어도
  # 소유자(나)에서 먼저 "다른 소유자"(2)로 거부돼야 한다 — 일반 계정이 만든 폴더는 권한 모양과 상관없이 확인 창 없이 막힌다.
  $parent = Join-Path $base 'inherit-parent'
  New-CleanDir $parent
  Invoke-TestIcacls @($parent, '/grant', '*S-1-5-11:(OI)(CI)M')
  $child = Join-Path $parent 'child'
  [void][System.IO.Directory]::CreateDirectory($child)
  Check 'acl: 물려받은 Authenticated Users 수정' (Invoke-DirCheck $child -TrustMe) 4
  Check 'acl: 내가 만든 폴더 + Authenticated Users 수정(원래 명령)' (Invoke-DirCheck $child) 2

  # 잠금 전 버전이 남긴 설치 폴더 모양(위에서 "Authenticated Users: 수정"을 물려받음) → 4(확인 창). Folder-Acl.ps1의
  # Protect-InstallDir로 잠근 뒤 → 0(확인 창 없이 통과) — 잠금 뒤의 설치는 일반 제거·완전 삭제 뒤 같은 경로에 다시 설치해도
  # 묻지 않는다. Protect-InstallDir이 루트에 다른 계정의 쓰기 권한을 남기게 바뀌면 여기서 걸린다.
  $app = Join-Path $parent 'TangoTalk-Server'
  foreach ($d in @('server\src', 'pgsql\bin', 'pgsql-data', 'secrets', 'node')) { [void][System.IO.Directory]::CreateDirectory((Join-Path $app $d)) }
  foreach ($f in @('Setup-TangoTalkServer.ps1', 'README-설치후.txt', 'unins000.exe', 'server\.env', 'node\node.exe', 'pgsql\bin\postgres.exe', 'secrets\db-app.pw')) {
    [System.IO.File]::WriteAllText((Join-Path $app $f), 'x')
  }
  Check 'lock: 잠금 전 모양의 설치 폴더 → 확인 창(4)' (Invoke-DirCheck $app -TrustMe) 4
  $lockWarnings = @(Protect-InstallDir -AppDir $app -PgServiceName 'Dnscache')
  Check 'lock: Protect-InstallDir 경고 없음' ($lockWarnings -join ' / ') ''
  Check 'lock: 잠근 설치 폴더 → 통과(0)' (Invoke-DirCheck $app -TrustMe) 0

  # 이 PC의 시스템 폴더·C:\ 바로 아래 폴더 — 권한은 읽기만 하고, 기대값은 이 프로세스에서 읽은 실제 소유자·권한으로 따로
  # 계산한다(PC마다 달라서). C:\ 바로 아래에는 관리자 권한 프로그램이 만들어 소유자는 Administrators인데 C:\의 "Authenticated
  # Users: 수정"을 물려받은 폴더가 흔하다 — 소유자만 보던 예전 검사는 이런 폴더를 받아들였고, 지금은 4가 나와야 한다.
  # 링크는 설치 프로그램이 이 검사 전에 막으므로 뺀다.
  $candidates = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($path in @("$env:SystemDrive\", $env:ProgramData, (Split-Path $env:USERPROFILE -Parent), $env:SystemRoot, $env:ProgramFiles, $env:PUBLIC)) {
    if ($path) { [void]$candidates.Add($path) }
  }
  foreach ($entry in @(Get-ChildItem -LiteralPath "$env:SystemDrive\" -Directory -Force -ErrorAction SilentlyContinue)) {
    if (-not ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { [void]$candidates.Add($entry.FullName) }
  }
  $seenCodes = @{}
  foreach ($candidate in $candidates) {
    $expected = Get-ExpectedDirCheck $candidate
    $seenCodes[$expected] = $true
    Check "system: $candidate" (Invoke-DirCheck $candidate) $expected
  }
  if (-not $seenCodes[0]) { $script:notes.Add('잠긴 폴더(0)로 보이는 시스템 폴더가 없어 실제 폴더의 "받아들임"은 확인하지 못했습니다(임시 폴더로는 확인함).') }
  if (-not $seenCodes[4]) { $script:notes.Add('관리자 소유지만 다른 계정도 쓸 수 있는 폴더(4)가 이 PC에 없어 실제 폴더로는 확인하지 못했습니다(임시 폴더로는 확인함).') }

  # 링크 검사 — GetFileAttributesW는 링크를 따라가지 않으므로, 대상이 지워진(끊어진) 정션도 재분석 지점으로 보여야 한다.
  [void][System.IO.Directory]::CreateDirectory($target)
  cmd /c mklink /J "$link" "$target" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "정션을 만들지 못했습니다: $link" }
  [System.IO.Directory]::Delete($target)
  $attrs = [TangoTalkInstallGuardTest.Native]::GetFileAttributesW($link)
  Check 'reparse: 끊어진 정션도 속성을 읽음' ($attrs -ne [uint32]::MaxValue) $true
  Check 'reparse: 끊어진 정션이 재분석 지점으로 보임' (($attrs -band 0x400) -ne 0) $true
  $plainAttrs = [TangoTalkInstallGuardTest.Native]::GetFileAttributesW((Join-Path $base 'plain'))
  Check 'reparse: 일반 폴더는 재분석 지점 아님' (($plainAttrs -band 0x400) -ne 0) $false
} finally {
  # 정션은 따라 들어가지 않게 정션 자체만 먼저 지운다(끊어진 정션은 Test-Path가 없다고 할 수 있어 속성으로 확인).
  if ([TangoTalkInstallGuardTest.Native]::GetFileAttributesW($link) -ne [uint32]::MaxValue) { cmd /c rmdir "$link" | Out-Null }
  if (Test-Path -LiteralPath $base) { [System.IO.Directory]::Delete($base, $true) }
}

# ── 2) [Files] / [Icons] / [Run] ─────────────────────────────────────────────
$rootScripts = @(Get-ChildItem -LiteralPath $installerDir -Filter '*.ps1' -File | ForEach-Object { $_.Name })
$shipped = @([regex]::Matches($iss, '(?m)^Source:\s*"([^"\\]+\.ps1)"\s*;\s*DestDir:\s*"\{app\}"') | ForEach-Object { $_.Groups[1].Value })
foreach ($name in $rootScripts) {
  Check "files: $name 이(가) [Files]에 있음" ($shipped -contains $name) $true
}
foreach ($name in $shipped) {
  Check "files: [Files]의 $name 이(가) 실제로 있음" ($rootScripts -contains $name) $true
}
$referenced = @([regex]::Matches($iss, '\{app\}\\([A-Za-z0-9_-]+\.ps1)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
foreach ($name in $referenced) {
  Check "icons: {app}\$name 이(가) [Files]에 있음" ($shipped -contains $name) $true
}

# ── 3) 승격 · 서버 폴더에서 node 실행 ────────────────────────────────────────
# Folder-Acl.ps1은 dot-source용 함수 모음이고, Setup-TangoTalkServer.ps1은 설치 프로그램이 관리자 권한으로 부른다.
$notLaunchers = @('Folder-Acl.ps1', 'Setup-TangoTalkServer.ps1')
foreach ($name in $rootScripts) {
  $path = Join-Path $installerDir $name
  $parseErrors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$parseErrors)
  Check "parse: $name 구문 오류 없음" (@($parseErrors).Count) 0
  if ($notLaunchers -notcontains $name) {
    # 승격 블록이 맨 위(첫 문장 또는 그 바로 다음 — $currentPrincipal 대입 뒤)에 있어야 한다.
    $statements = @($ast.EndBlock.Statements)
    $elevateAt = -1
    for ($i = 0; $i -lt $statements.Count; $i++) {
      $text = $statements[$i].Extent.Text
      if ($text -match 'IsInRole\(' -and $text -match '-Verb\s+RunAs' -and $text -match '\bexit\b') { $elevateAt = $i; break }
    }
    Check "elevate: $name 이(가) 맨 처음에 스스로 승격" ($elevateAt -ge 0 -and $elevateAt -le 1) $true
  }
  $nodeCalls = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
        $n.CommandElements[0].Extent.Text -eq '$NodeExe' }, $true))
  $locationCalls = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        (@('Set-Location', 'Push-Location') -contains $n.GetCommandName()) -and
        $n.Extent.Text -match '\$ServerDir' }, $true))
  foreach ($call in $nodeCalls) {
    $before = @($locationCalls | Where-Object { $_.Extent.StartOffset -lt $call.Extent.StartOffset })
    Check "cwd: $name 줄 $($call.Extent.StartLineNumber)의 node 실행 전에 서버 폴더로 이동" ($before.Count -gt 0) $true
  }
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
