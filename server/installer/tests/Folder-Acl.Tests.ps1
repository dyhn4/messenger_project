<#
.SYNOPSIS
  Folder-Acl.ps1 확인용 테스트 — 개발 PC 전용(설치 프로그램·업데이트 zip에는 안 들어감). 관리자 권한
  없이 돌리고, %TEMP% 안에 만든 임시 폴더만 건드린다(실제 설치 폴더·서비스·DB는 손대지 않음).

.DESCRIPTION
  1) Get-FolderLockKind / Test-PathUnder / ConvertTo-AccountSid의 판단 규칙
  2) Reset-TreeAcl이 정션 너머(링크가 가리키는 폴더)를 건드리지 않는지
  3) Protect-InstallDir / Set-AdminOnlyAcl을 가짜 설치 폴더에 끝까지 돌린 결과 권한(PostgreSQL 서비스
     계정이 NetworkService / LocalService / LocalSystem / 없음 / 못 알아봄인 경우 각각)

  Folder-Acl.ps1을 실행하지 않고 함수 정의와 $Acl* 상수만 꺼내 쓴다. 관리자 권한 없이 돌리므로 이 테스트
  안에서만 "Administrators" SID를 내 계정 SID로 바꿔 끼운다 — 일반 권한 토큰에서 Administrators는
  "거부 전용"이라 그대로 두면 잠근 임시 폴더를 내가 못 연다(실제 설치에서는 *S-1-5-32-544).
  PostgreSQL 서비스 계정 경우는 Windows 기본 서비스(Dnscache·EventLog·Schedule)의 레지스트리 값을 읽기만
  해서 흉내 낸다.

  사용법(저장소 루트): powershell -NoProfile -ExecutionPolicy Bypass -File server\installer\tests\Folder-Acl.Tests.ps1
  실패가 하나라도 있으면 종료 코드 1.
#>

$ErrorActionPreference = 'Stop'
$helper = Join-Path (Split-Path $PSScriptRoot -Parent) 'Folder-Acl.ps1'

function Import-FolderAcl {
  $parseErrors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($helper, [ref]$null, [ref]$parseErrors)
  if ($parseErrors) { throw "Folder-Acl.ps1 구문 오류: $parseErrors" }
  foreach ($stmt in $ast.EndBlock.Statements) {
    $isFunction = $stmt -is [System.Management.Automation.Language.FunctionDefinitionAst]
    $isConstant = ($stmt -is [System.Management.Automation.Language.AssignmentStatementAst]) -and ($stmt.Left.Extent.Text -like '$Acl*')
    # 함수·상수 말고 다른 것이 생기면(=dot-source만 해도 뭔가 실행되면) 이 테스트 방식이 더는 안전하지 않다.
    if (-not ($isFunction -or $isConstant)) { throw "Folder-Acl.ps1 최상위에 함수/상수가 아닌 문장이 있습니다: $($stmt.Extent.Text)" }
    . ([scriptblock]::Create($stmt.Extent.Text))
  }
}
# 함수 안에서 dot-source한 정의는 그 함수가 끝나면 사라지므로, 함수 호출 자체를 dot-source해서 이 스코프에 남긴다.
. Import-FolderAcl
$me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$AclSidAdmins = $me   # 테스트 전용 치환(위 설명)

$script:passed = 0
$script:failures = New-Object System.Collections.Generic.List[string]
function Check([string]$Name, $Actual, $Expected) {
  if ("$Actual" -ceq "$Expected") { $script:passed++ } else { $script:failures.Add("$Name -> [$Actual], 기대값 [$Expected]") }
}
function Explicit([string]$Path) {
  @((Get-Acl -LiteralPath $Path).GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) |
      ForEach-Object { '{0}:{1}:{2}' -f $_.IdentityReference.Value, ($_.FileSystemRights -replace ', Synchronize', ''), ($_.InheritanceFlags -replace ', ', '+') } |
      Sort-Object) -join ' | '
}
function InheritedSids([string]$Path) {
  @((Get-Acl -LiteralPath $Path).GetAccessRules($false, $true, [System.Security.Principal.SecurityIdentifier]) |
      ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique) -join ','
}
function SidSet([string[]]$Sids) { (@($Sids) | Sort-Object -Unique) -join ',' }
function Grant([string]$Path, [string]$Ace) {
  & icacls.exe $Path /grant $Ace 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "테스트 준비 실패: icacls $Path /grant $Ace" }
}
function New-Junction([string]$Link, [string]$Target) {
  cmd /c mklink /J "$Link" "$Target" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "정션을 만들지 못했습니다: $Link" }
}
# PowerShell 5.1의 Remove-Item -Recurse는 정션을 따라 들어가 대상까지 지울 수 있어서, 정션부터 따로 지운다.
function Remove-TestTree([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $dirs = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
  $dirs.Push((New-Object System.IO.DirectoryInfo($Path)))
  $links = New-Object System.Collections.Generic.List[string]
  while ($dirs.Count -gt 0) {
    foreach ($entry in $dirs.Pop().EnumerateDirectories()) {
      if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $links.Add($entry.FullName) } else { $dirs.Push($entry) }
    }
  }
  foreach ($link in $links) { cmd /c rmdir "$link" | Out-Null }
  Remove-Item -LiteralPath $Path -Recurse -Force
}

$base = Join-Path $env:TEMP ("tangotalk-folder-acl-test-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
try {
  # ── 1) 판단 규칙 ─────────────────────────────────────────────────────────
  New-Item -ItemType Directory -Path "$base\plain", "$base\linktarget" -Force | Out-Null
  New-Junction "$base\junction" "$base\linktarget"
  $docs = [Environment]::GetFolderPath('MyDocuments')
  Check 'kind: 드라이브 최상위'        (Get-FolderLockKind -Path "$env:SystemDrive\") 'Unsafe'
  Check 'kind: "D:"만'                 (Get-FolderLockKind -Path 'D:') 'Unknown'
  Check 'kind: 상대 경로'              (Get-FolderLockKind -Path 'uploads\x') 'Unknown'
  Check 'kind: \\?\ 경로'              (Get-FolderLockKind -Path '\\?\C:\x') 'Unknown'
  Check 'kind: UNC'                    (Get-FolderLockKind -Path '\\nas\share\uploads') 'Network'
  Check 'kind: UNC(/)'                 (Get-FolderLockKind -Path '//nas/share/uploads') 'Network'
  Check 'kind: Windows'                (Get-FolderLockKind -Path $env:SystemRoot) 'Unsafe'
  Check 'kind: Program Files'          (Get-FolderLockKind -Path "$env:ProgramFiles\") 'Unsafe'
  Check 'kind: ProgramData'            (Get-FolderLockKind -Path $env:ProgramData) 'Unsafe'
  Check 'kind: Users'                  (Get-FolderLockKind -Path (Split-Path $env:USERPROFILE -Parent)) 'Unsafe'
  Check 'kind: 내 프로필'              (Get-FolderLockKind -Path $env:USERPROFILE) 'Unsafe'
  Check 'kind: 내 문서'                (Get-FolderLockKind -Path $docs) 'Unsafe'
  Check 'kind: ..로 Windows'           (Get-FolderLockKind -Path "$env:SystemDrive\TangoTalk-Server\..\Windows") 'Unsafe'
  Check 'kind: 예약 경로의 상위'       (Get-FolderLockKind -Path "$env:SystemDrive\Apps" -ReservedPaths @("$env:SystemDrive\Apps\TangoTalk-Server")) 'Unsafe'
  Check 'kind: 예약 경로 자체'         (Get-FolderLockKind -Path "$env:SystemDrive\TangoTalk-Server\server" -ReservedPaths @("$env:SystemDrive\TangoTalk-Server\server")) 'Unsafe'
  Check 'kind: 예약 경로 안쪽'         (Get-FolderLockKind -Path "$env:SystemDrive\TangoTalk-Server\server\uploads" -ReservedPaths @("$env:SystemDrive\TangoTalk-Server\server")) 'Local'
  Check 'kind: 문서 안 전용 폴더'      (Get-FolderLockKind -Path (Join-Path $docs 'TangoUploads')) 'Local'
  Check 'kind: 기본 설치 경로'         (Get-FolderLockKind -Path "$env:SystemDrive\TangoTalk-Server") 'Local'
  Check 'kind: / 구분자'               (Get-FolderLockKind -Path "$env:SystemDrive/TangoTalk-Server") 'Local'
  Check 'kind: 정션 폴더'              (Get-FolderLockKind -Path "$base\junction") 'Unsafe'
  Check 'kind: 임시 일반 폴더'         (Get-FolderLockKind -Path "$base\plain") 'Local'
  $missingDrive = [char[]](90..68) | Where-Object { -not (Test-Path "$($_):\") } | Select-Object -First 1
  if ($missingDrive) { Check 'kind: 없는 드라이브' (Get-FolderLockKind -Path "$($missingDrive):\x") 'Unknown' }
  $fat = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.FileSystem -match '^(FAT|FAT32|exFAT)$' } | Select-Object -First 1
  if ($fat) { Check 'kind: FAT 드라이브 폴더' (Get-FolderLockKind -Path "$($fat.DeviceID)\TangoUploads") 'NoAcl' }

  Check 'under: 같은 경로'      (Test-PathUnder -Path 'C:\A\B' -Parent 'c:\a\b\') $true
  Check 'under: 안쪽'           (Test-PathUnder -Path 'C:\A\B\C' -Parent 'C:\A\B') $true
  Check 'under: 이름만 겹침'    (Test-PathUnder -Path 'C:\A\BC' -Parent 'C:\A\B') $false
  Check 'under: 바깥'           (Test-PathUnder -Path 'C:\A' -Parent 'C:\A\B') $false

  Check 'sid: LocalSystem'                  (ConvertTo-AccountSid -Account 'LocalSystem') 'S-1-5-18'
  Check 'sid: NT AUTHORITY\NetworkService'  (ConvertTo-AccountSid -Account 'NT AUTHORITY\NetworkService') 'S-1-5-20'
  Check 'sid: NT AUTHORITY\NETWORK SERVICE' (ConvertTo-AccountSid -Account 'NT AUTHORITY\NETWORK SERVICE') 'S-1-5-20'
  Check 'sid: NT AUTHORITY\LocalService'    (ConvertTo-AccountSid -Account 'NT AUTHORITY\LocalService') 'S-1-5-19'
  Check 'sid: .\내 계정'                    (ConvertTo-AccountSid -Account ('.\' + ([Security.Principal.WindowsIdentity]::GetCurrent().Name -split '\\')[-1])) $me
  Check 'sid: 없는 계정'                    (ConvertTo-AccountSid -Account 'NoSuchAccountXyz123') ''

  # ── 2) icacls 호출 · 정션 ─────────────────────────────────────────────────
  $threw = $false
  try { Invoke-Icacls -Arguments @("$base\nope", '/reset') } catch { $threw = $_.Exception.Message -match '\(코드 2\)' }
  Check 'icacls: 실패하면 종료 코드와 함께 예외' $threw $true
  $warnings = New-Object System.Collections.Generic.List[string]
  Invoke-IcaclsOrWarn -Warnings $warnings -Arguments @("$base\nope", '/reset')
  Check 'icacls: OrWarn은 빈 목록에도 경고를 쌓음' $warnings.Count 1

  New-Item -ItemType Directory -Path "$base\tree\a\b", "$base\outside\deep" -Force | Out-Null
  foreach ($f in @("$base\tree\a\b\inside.txt", "$base\tree\top.txt", "$base\outside\target.txt", "$base\outside\deep\target2.txt")) {
    Set-Content -LiteralPath $f -Value 'x'
    Grant $f '*S-1-1-0:(R)'
  }
  New-Junction "$base\tree\linked" "$base\outside"
  Check 'link: 정션 있는 트리'   (Test-TreeHasDirLink -Dir "$base\tree") $true
  Check 'link: 정션 없는 트리'   (Test-TreeHasDirLink -Dir "$base\tree\a") $false
  $warnings = New-Object System.Collections.Generic.List[string]
  Reset-TreeAcl -Path "$base\tree" -Warnings $warnings
  Check 'reset: 안쪽 깊은 파일'      (Explicit "$base\tree\a\b\inside.txt") ''
  Check 'reset: 안쪽 파일'           (Explicit "$base\tree\top.txt") ''
  Check 'reset: 정션 너머 파일'      (Explicit "$base\outside\target.txt") 'S-1-1-0:Read:None'
  Check 'reset: 정션 너머 깊은 파일' (Explicit "$base\outside\deep\target2.txt") 'S-1-1-0:Read:None'
  Check 'reset: 정션 경고'           ([bool]($warnings | Where-Object { $_ -like '*linked*' })) $true

  # ── 3) Protect-InstallDir / Set-AdminOnlyAcl 끝까지 ────────────────────────
  $cases = @(
    @{ Service = 'Dnscache'; Sid = 'S-1-5-20' },                          # NT AUTHORITY\NetworkService(EDB 기본값과 같은 표기)
    @{ Service = 'EventLog'; Sid = 'S-1-5-19' },                          # NT AUTHORITY\LocalService
    @{ Service = 'Schedule'; Sid = 'S-1-5-18' },                          # LocalSystem — 추가 권한 없음
    @{ Service = 'tangotalk-no-such-service'; Sid = 'S-1-5-20' }          # 서비스 없음 → EDB 기본값으로 준비
  )
  foreach ($case in $cases) {
    $tag = "[$($case.Service)]"
    $app = Join-Path $base "app-$($case.Service)"
    foreach ($d in @('server\src', 'server\node_modules\pkg', 'server\uploads', 'secrets', 'pgsql\bin', 'pgsql-data\base', 'node', 'backups')) {
      New-Item -ItemType Directory -Path (Join-Path $app $d) -Force | Out-Null
    }
    foreach ($f in @('Setup-TangoTalkServer.ps1', 'Folder-Acl.ps1', 'README-설치후.txt', 'unins000.exe', 'unins000.dat', 'install.log',
        'server\.env', 'server\src\index.js', 'server\node_modules\pkg\index.js', 'server\uploads\a.png', 'secrets\db-app.pw',
        'pgsql\bin\postgres.exe', 'pgsql-data\base\1', 'pgsql-data\postgresql.conf', 'node\node.exe', 'backups\messenger_20260101_000000.dump')) {
      Set-Content -LiteralPath (Join-Path $app $f) -Value 'x'
    }
    New-Item -ItemType Directory -Path "$app-outside" -Force | Out-Null
    Set-Content -LiteralPath "$app-outside\target.txt" -Value 'x'
    Grant "$app-outside\target.txt" '*S-1-1-0:(R)'
    New-Junction "$app\server\uploads\linked" "$app-outside"
    # 잠금 전 버전 흉내: 넓은 직접 항목, 예전 방식의 읽기 전용 .env 잠금, 데이터 폴더의 엉뚱한 Everyone.
    Grant $app '*S-1-5-11:(OI)(CI)M'
    Grant "$app\server\src" '*S-1-5-11:(OI)(CI)M'
    & icacls.exe "$app\server\.env" /inheritance:r /grant:r "*${me}:(R)" '*S-1-5-18:(R)' 2>&1 | Out-Null
    Grant "$app\pgsql-data" '*S-1-1-0:(OI)(CI)R'

    $warnings = @(Protect-InstallDir -AppDir $app -PgServiceName $case.Service)
    $pg = $case.Sid
    $adminsOnly = SidSet @('S-1-5-18', $me)
    $rootExpected = @("S-1-5-18:FullControl:ContainerInherit+ObjectInherit", "${me}:FullControl:ContainerInherit+ObjectInherit", 'S-1-5-32-545:ReadAndExecute:None')
    if ($pg -ne 'S-1-5-18') { $rootExpected += "${pg}:ReadAndExecute:None" }
    Check "$tag 루트 상속 끊김"     (Get-Acl -LiteralPath $app).AreAccessRulesProtected $true
    Check "$tag 루트 직접 항목"     (Explicit $app) (($rootExpected | Sort-Object) -join ' | ')
    Check "$tag 루트 상속 항목 없음" (InheritedSids $app) ''
    Check "$tag .env 상속으로 되돌림" (Get-Acl -LiteralPath "$app\server\.env").AreAccessRulesProtected $false
    Check "$tag .env 직접 항목 없음"  (Explicit "$app\server\.env") ''
    foreach ($f in @('server\.env', 'server\src\index.js', 'server\node_modules\pkg\index.js', 'server\uploads\a.png', 'secrets\db-app.pw', 'node\node.exe', 'backups\messenger_20260101_000000.dump', 'install.log')) {
      Check "$tag 관리자 전용: $f" (InheritedSids (Join-Path $app $f)) $adminsOnly
    }
    Check "$tag src의 Authenticated Users 제거" (Explicit "$app\server\src") ''
    if ($pg -eq 'S-1-5-18') {
      Check "$tag pgsql 추가 권한 없음" (Explicit "$app\pgsql") ''
    } else {
      Check "$tag pgsql: PG 계정 읽기"       (Explicit "$app\pgsql") "${pg}:ReadAndExecute:ContainerInherit+ObjectInherit"
      Check "$tag pgsql-data: PG 계정 전체"  (Explicit "$app\pgsql-data") "${pg}:FullControl:ContainerInherit+ObjectInherit"
      Check "$tag postgres.exe를 PG 계정이 읽음" (InheritedSids "$app\pgsql\bin\postgres.exe") (SidSet @('S-1-5-18', $me, $pg))
      Check "$tag 데이터 파일을 PG 계정이 씀"    (InheritedSids "$app\pgsql-data\base\1") (SidSet @('S-1-5-18', $me, $pg))
    }
    Check "$tag pgsql-data의 Everyone 제거" ([bool]((Explicit "$app\pgsql-data") -like '*S-1-1-0*')) $false
    foreach ($f in @('Setup-TangoTalkServer.ps1', 'Folder-Acl.ps1', 'README-설치후.txt', 'unins000.exe', 'unins000.dat')) {
      Check "$tag Users 읽기: $f" (Explicit (Join-Path $app $f)) 'S-1-5-32-545:ReadAndExecute:None'
    }
    Check "$tag install.log는 Users 못 읽음" (Explicit "$app\install.log") ''
    Check "$tag 정션 너머 그대로"           (Explicit "$app-outside\target.txt") 'S-1-1-0:Read:None'
    Check "$tag 경고는 정션 하나뿐"         (@($warnings).Count) 1
    $before = (Explicit $app), (Explicit "$app\pgsql-data"), (Explicit "$app\README-설치후.txt")
    $null = Protect-InstallDir -AppDir $app -PgServiceName $case.Service
    Check "$tag 다시 실행해도 같음" (((Explicit $app), (Explicit "$app\pgsql-data"), (Explicit "$app\README-설치후.txt")) -join ' / ') ($before -join ' / ')
  }

  # 서비스 계정을 SID로 못 바꾸면: PostgreSQL 두 폴더는 지금 권한 그대로 고정, 나머지는 잠그고 경고.
  $app = Join-Path $base 'app-freeze'
  New-Item -ItemType Directory -Path "$app\pgsql\bin", "$app\pgsql-data", "$app\server" -Force | Out-Null
  Set-Content -LiteralPath "$app\pgsql\bin\postgres.exe" -Value 'x'
  Set-Content -LiteralPath "$app\server\.env" -Value 'x'
  $pgBefore = InheritedSids "$app\pgsql\bin\postgres.exe"
  $realConvert = ${function:ConvertTo-AccountSid}
  ${function:ConvertTo-AccountSid} = { param([string]$Account) $null }
  try { $warnings = @(Protect-InstallDir -AppDir $app -PgServiceName 'Dnscache') } finally { ${function:ConvertTo-AccountSid} = $realConvert }
  $pgAfter = @((Get-Acl -LiteralPath "$app\pgsql\bin\postgres.exe").GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
      ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique) -join ','
  Check '[freeze] pgsql 상속 끊고 고정' (Get-Acl -LiteralPath "$app\pgsql").AreAccessRulesProtected $true
  Check '[freeze] postgres.exe 접근 그대로' $pgAfter $pgBefore
  Check '[freeze] 나머지는 잠김' (InheritedSids "$app\server\.env") (SidSet @('S-1-5-18', $me))
  Check '[freeze] 경고 남김' ([bool]($warnings | Where-Object { $_ -like '*PostgreSQL 서비스 계정*' })) $true

  # Test-ReparsePoint: 링크면 $true, 일반 폴더면 $false.
  Check 'reparse: 정션 폴더'   (Test-ReparsePoint -Path "$base\junction") $true
  Check 'reparse: 일반 폴더'   (Test-ReparsePoint -Path "$base\plain") $false
  Check 'reparse: 없는 경로'   (Test-ReparsePoint -Path "$base\nope-xyz") $false

  # 설치 폴더 안의 핵심 데이터 폴더가 링크면 Protect-InstallDir이 멈춘다(손댄 흔적 — 비밀값/백업/DB가 샐 수 있음).
  foreach ($dataLink in @('secrets', 'backups', 'pgsql-data', 'server\uploads', 'server\certs')) {
    $app = Join-Path $base ("app-datalink-" + ($dataLink -replace '\\', '-'))
    New-Item -ItemType Directory -Path (Join-Path $app 'server'), "$app-linktgt" -Force | Out-Null
    New-Junction (Join-Path $app $dataLink) "$app-linktgt"
    $threw = $false
    try { $null = Protect-InstallDir -AppDir $app -PgServiceName 'Dnscache' } catch { $threw = $_.Exception.Message -match [regex]::Escape($dataLink) }
    Check "data-link: $dataLink 링크면 멈추고 이름을 알림" $threw $true
  }

  # Set-AdminOnlyAcl(설치 폴더 밖 첨부파일 폴더) + 잠그면 안 되는 곳 거부.
  $ext = Join-Path $base 'ext-uploads'
  New-Item -ItemType Directory -Path "$ext\sub" -Force | Out-Null
  Set-Content -LiteralPath "$ext\sub\f.png" -Value 'x'
  Grant "$ext\sub\f.png" '*S-1-1-0:(R)'
  $warnings = @(Set-AdminOnlyAcl -Path $ext)
  Check 'admin-only: 상속 끊김'     (Get-Acl -LiteralPath $ext).AreAccessRulesProtected $true
  Check 'admin-only: 직접 항목'     (Explicit $ext) ((@("S-1-5-18:FullControl:ContainerInherit+ObjectInherit", "${me}:FullControl:ContainerInherit+ObjectInherit") | Sort-Object) -join ' | ')
  Check 'admin-only: 안쪽 파일'     (InheritedSids "$ext\sub\f.png") (SidSet @('S-1-5-18', $me))
  Check 'admin-only: 안쪽 직접 항목' (Explicit "$ext\sub\f.png") ''
  Check 'admin-only: 경고 없음'     $warnings.Count 0
  $threw = $false; try { $null = Set-AdminOnlyAcl -Path "$env:SystemDrive\" } catch { $threw = $true }
  Check 'admin-only: 드라이브 최상위 거부' $threw $true
  $threw = $false; try { $null = Protect-InstallDir -AppDir $env:ProgramFiles } catch { $threw = $true }
  Check 'install-dir: Program Files 거부' $threw $true
} finally {
  Remove-TestTree $base
}

''
if ($script:failures.Count -gt 0) {
  $script:failures | ForEach-Object { "FAIL $_" }
  "통과 $($script:passed), 실패 $($script:failures.Count)"
  exit 1
}
"통과 $($script:passed), 실패 0 (임시 폴더 정리됨: $(-not (Test-Path -LiteralPath $base)))"
exit 0
