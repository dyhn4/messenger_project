<#
.SYNOPSIS
  폴더 접근 권한 잠금 공용 함수 — Setup-TangoTalkServer.ps1 / Update-Server.ps1 / Storage-Path.ps1 /
  Backup-Data.ps1이 dot-source(`. (Join-Path $PSScriptRoot 'Folder-Acl.ps1')`)해서 쓴다. 이 파일을
  직접 실행하면 함수만 정의하고 아무 것도 바꾸지 않는다.

.DESCRIPTION
  왜 필요한가: 기본 설치 경로(C:\TangoTalk-Server)는 C:\의 권한을 그대로 물려받는데, C:\는
  "Authenticated Users: 수정"을 하위 폴더·파일 전체에 상속시킨다. 그래서 이 PC에 로그인할 수 있는
  아무 계정이나 node.exe·서버 코드·nssm.exe·PostgreSQL 실행 파일을 바꿔치기할 수 있었고, 그 코드는
  서비스로(Node 서버·LiveKit은 NSSM이 LocalSystem으로, PostgreSQL은 NetworkService로) 실행되므로 곧바로
  SYSTEM 권한 탈취가 됐다. .env·DB 비밀번호·JWT/암호화 키·인증서 개인키·DB 파일(pgsql-data)·백업
  (.dump)도 아무나 읽을 수 있었다.

  그래서 폴더를 "상속 끊기 + SYSTEM/Administrators만 전체 권한(하위로 상속)"으로 잠근다. 나중에 생기는
  파일(서버가 첫 실행 때 만드는 비밀값, 첨부파일, 로그, 백업)도 이 권한을 그대로 물려받으므로 파일마다
  따로 잠글 필요가 없다. 설치 폴더(Protect-InstallDir)에만 꼭 필요한 예외를 둔다:
    - PostgreSQL 서비스 계정: pgsql(실행 파일) 읽기, pgsql-data 전체 권한.
    - Users: 설치 폴더 "목록"과, 시작 메뉴가 일반 권한으로 여는 루트 파일(*.ps1 런처·README·제거
      프로그램)만 읽기 — 관리용 스크립트는 읽힌 다음 스스로 관리자 권한으로 다시 실행한다.

  그룹은 이름이 아니라 잘 알려진 SID로만 지정한다 — 그룹 이름은 Windows 언어에 따라 다를 수 있고,
  icacls는 이름을 못 찾으면(오류 1332) 그 파일은 아무 것도 바꾸지 않는데, 출력을 버리면 실패한 줄도
  모른다. 그래서 여기서는 icacls의 종료 코드를 반드시 확인한다.
#>

$AclSidSystem = 'S-1-5-18'
$AclSidAdmins = 'S-1-5-32-544'
$AclSidUsers = 'S-1-5-32-545'
$AclSidNetworkService = 'S-1-5-20'
# PATH에 끼워 넣은 가짜 icacls.exe가 관리자 권한으로 실행되지 않게 전체 경로로 부른다.
$AclIcaclsExe = Join-Path $env:SystemRoot 'System32\icacls.exe'
# Get-FolderLockKind 결과를 사용자에게 보여줄 때 쓰는 설명.
$AclKindText = @{
  Network = '네트워크 경로'
  NoAcl   = '접근 권한을 저장할 수 없는 드라이브(FAT32/exFAT 등)'
  Unsafe  = '드라이브 최상위·바로가기(정션) 폴더이거나 Windows·Program Files·사용자 폴더처럼 다른 것과 함께 쓰는 폴더(또는 그 상위)'
  Unknown = '확인할 수 없는 경로(전체 경로가 아니거나 드라이브를 찾을 수 없음)'
}

function Invoke-Icacls {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [scriptblock]$Tick
  )
  # 이 함수 안에서만 'Continue' — 부르는 스크립트가 'Stop'이면 PowerShell 5.1은 네이티브 프로그램의
  # stderr 한 줄을 곧바로 예외로 바꿔서, /C(오류가 나도 계속)로 돌린 작업이 첫 실패에서 끊겨버린다.
  $ErrorActionPreference = 'Continue'
  $errors = New-Object System.Collections.Generic.List[string]
  $lines = 0
  # icacls가 아예 실행되지 못하면 $LASTEXITCODE가 직전 명령의 값(0일 수 있음)으로 남아 성공처럼 보인다.
  $global:LASTEXITCODE = -1
  & $AclIcaclsExe @Arguments 2>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { $errors.Add($_.ToString()) }
    $lines++
    # node_modules처럼 파일이 많은 /T 작업은 수십 초 걸린다 — GUI(Update-Server.ps1 등)가 "응답 없음"으로
    # 보이지 않게 가끔 호출자의 Tick(DoEvents)을 불러준다(그래서 /Q로 출력을 끄지 않는다).
    if ($Tick -and ($lines % 200 -eq 0)) { $null = & $Tick }
  }
  if ($LASTEXITCODE -ne 0) {
    $detail = ($errors | Select-Object -First 3) -join ' / '
    throw "icacls $($Arguments -join ' ') 실패(코드 $LASTEXITCODE) $detail".Trim()
  }
}

# 실패해도 이미 걸린 잠금은 그대로라 "정리" 단계에서 쓴다 — 예외 대신 경고 목록에 남긴다.
# ($Warnings는 처음엔 늘 빈 목록이다 — Mandatory만 두면 PowerShell이 빈 컬렉션을 거부하므로 AllowEmptyCollection 필수.)
function Invoke-IcaclsOrWarn {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Warnings,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [scriptblock]$Tick
  )
  try {
    Invoke-Icacls -Arguments $Arguments -Tick $Tick
  } catch {
    $Warnings.Add($_.Exception.Message)
  }
}

# $Path가 $Parent와 같거나 그 안에 있는지(대소문자 무시). 경로 형식이 잘못됐으면 $false.
function Test-PathUnder {
  param([string]$Path, [string]$Parent)
  if (-not $Path -or -not $Parent) { return $false }
  try {
    $p = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $q = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
  } catch {
    return $false
  }
  return ($p -ieq $q) -or $p.StartsWith("$q\", [System.StringComparison]::OrdinalIgnoreCase)
}

# $Path가 정션/심볼릭 링크(재분석 지점)인지. 없는 경로는 $false(링크가 아니므로). 설치/백업 스크립트가
# "이 폴더가 링크면 비밀값·DB·백업이 링크가 가리키는 다른 폴더로 새어 나가므로 멈춘다"를 판단하는 데 쓴다.
function Test-ReparsePoint {
  param([Parameter(Mandatory = $true)][string]$Path)
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  return [bool]($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint))
}

<#
  사용자가 고른 폴더(첨부파일 저장소, 설치 경로)를 잠가도 되는지 판단한다. 잠금은 그 폴더 안의 기존
  파일까지 전부 관리자 전용으로 바꾸므로, 다른 것과 함께 쓰는 폴더를 잘못 잠그면 다른 사람들이 자기
  파일을 못 열게 된다 — 그래서 확실히 전용 폴더로 볼 수 있을 때만 'Local'을 돌려준다.
    Local   — 잠가도 되는 로컬 NTFS/ReFS 폴더
    Network — UNC(\\서버\공유)·네트워크 드라이브: 이 PC의 SID로 잠그면 NAS 쪽 계정과 맞지 않아 서버까지
              못 쓰게 될 수 있으므로 손대지 않는다(권한은 NAS 쪽에서 제한)
    NoAcl   — FAT32/exFAT 등 접근 권한을 저장하지 못하는 드라이브
    Unsafe  — 드라이브 최상위, 정션/심볼릭 링크(가리키는 대상이 잠길 수 있음), Windows·Program Files·
              ProgramData·사용자 프로필 등 잘 알려진 폴더 자체이거나 그 상위, $ReservedPaths 자체이거나 그 상위
    Unknown — 전체 경로가 아니거나(상대 경로·"D:"처럼 드라이브만) 드라이브를 찾을 수 없음
#>
function Get-FolderLockKind {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string[]]$ReservedPaths = @()
  )
  if ($Path -match '^[\\/]{2}[?.][\\/]') { return 'Unknown' }
  if ($Path -match '^[\\/]{2}') { return 'Network' }
  if ($Path -notmatch '^[A-Za-z]:[\\/]') { return 'Unknown' }
  try {
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [System.IO.Path]::GetPathRoot($full)
    $drive = New-Object System.IO.DriveInfo($root)
  } catch {
    return 'Unknown'
  }
  if ($drive.DriveType -eq [System.IO.DriveType]::Network) { return 'Network' }
  # 없는 드라이브나 준비 안 된 드라이브(빈 카드 리더 등). PowerShell은 DriveFormat 같은 속성에서 난 예외를
  # 삼키고 빈 값을 돌려주므로(직접 확인함) 예외를 기다리지 말고 IsReady로 먼저 걸러야 한다.
  if ($drive.DriveType -eq [System.IO.DriveType]::NoRootDirectory -or -not $drive.IsReady) { return 'Unknown' }
  if ($full.Length -le $root.TrimEnd('\').Length) { return 'Unsafe' }
  if (@('NTFS', 'ReFS') -notcontains $drive.DriveFormat) { return 'NoAcl' }
  $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
  if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return 'Unsafe' }
  $wellKnown = @(
    $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:ProgramData, $env:PUBLIC,
    [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'),
    [Environment]::GetFolderPath('MyPictures'), [Environment]::GetFolderPath('MyMusic'),
    [Environment]::GetFolderPath('MyVideos')
  ) + $ReservedPaths
  if ($env:USERPROFILE) {
    $wellKnown += @($env:USERPROFILE, (Split-Path -Path $env:USERPROFILE -Parent), (Join-Path $env:USERPROFILE 'Downloads'))
  }
  foreach ($known in $wellKnown) {
    if ($known -and (Test-PathUnder -Path $known -Parent $full)) { return 'Unsafe' }
  }
  return 'Local'
}

# 서비스의 실행 계정 이름(레지스트리 ObjectName 값)을 SID로. 못 바꾸면 $null.
function ConvertTo-AccountSid {
  param([string]$Account)
  if (-not $Account) { return $null }
  if ($Account -match '^(LocalSystem|(NT AUTHORITY\\)?SYSTEM)$') { return $AclSidSystem }
  # 서비스 관리자는 언어와 상관없이 "NT AUTHORITY\NetworkService"(공백 없음) 같은 별칭으로 저장한다 —
  # 이 별칭은 NTAccount.Translate가 못 알아볼 수 있어서 따로 처리한다.
  if ($Account -match '^(NT AUTHORITY\\)?Network\s?Service$') { return $AclSidNetworkService }
  if ($Account -match '^(NT AUTHORITY\\)?Local\s?Service$') { return 'S-1-5-19' }
  $name = $Account -replace '^\.\\', "$env:COMPUTERNAME\"
  try {
    return (New-Object System.Security.Principal.NTAccount($name)).Translate([System.Security.Principal.SecurityIdentifier]).Value
  } catch {
    return $null
  }
}

# $Path 자체에 직접 붙은(상속 아닌) 허용 항목 중 $AllowedSids에 없는 것을 지운다 — 상속 끊기(/inheritance:r)는
# 직접 붙은 항목은 그대로 두기 때문(예: 누가 넣어둔 "Users: 수정", EDB 설치 프로그램이 상위 폴더에 단 권한).
function Remove-ExtraAllowAces {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$AllowedSids,
    [scriptblock]$Tick
  )
  $rules = (Get-Acl -LiteralPath $Path -ErrorAction Stop).GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])
  $extra = @($rules |
      Where-Object { $_.AccessControlType -eq 'Allow' -and ($AllowedSids -notcontains $_.IdentityReference.Value) } |
      ForEach-Object { $_.IdentityReference.Value } | Select-Object -Unique)
  if ($extra.Count -gt 0) {
    Invoke-Icacls -Tick $Tick -Arguments (@($Path, '/remove:g') + @($extra | ForEach-Object { "*$_" }))
  }
}

# $Dir 아래(자신 제외)에 폴더 정션/심볼릭 링크가 하나라도 있는지 — 따라 들어가지 않고 찾는다. 목록을 못
# 읽는 폴더가 있으면 모르는 것이므로 $true(조심하는 쪽)를 돌려준다.
function Test-TreeHasDirLink {
  param(
    [Parameter(Mandatory = $true)][string]$Dir,
    [scriptblock]$Tick
  )
  $pending = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
  $pending.Push((New-Object System.IO.DirectoryInfo($Dir)))
  $seen = 0
  try {
    while ($pending.Count -gt 0) {
      foreach ($entry in $pending.Pop().EnumerateFileSystemInfos()) {
        if ($entry -is [System.IO.DirectoryInfo]) {
          if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $true }
          $pending.Push($entry)
        }
        $seen++
        if ($Tick -and ($seen % 500 -eq 0)) { $null = & $Tick }
      }
    }
  } catch {
    return $true
  }
  return $false
}

<#
  $Path(파일 또는 폴더)와 그 아래 전부를 "소유자 Administrators + 직접 붙은 항목 없이 위에서 물려받기만"으로
  되돌린다. 소유자를 먼저 바꾸는 이유: 일반 계정이 만들어 둔 파일은 그 사람이 소유자라, 개별 권한을 지워도
  소유자는 언제든 권한을 다시 바꿀 수 있다.

  정션·폴더 심볼릭 링크는 절대 따라 들어가지 않는다 — icacls의 /T는 /L을 줘도 정션 안으로 들어가는데(직접
  확인함), 이 폴더는 예전에 아무 계정이나 쓸 수 있었으므로 누가 C:\Windows 같은 곳을 가리키는 정션을 심어
  두었다면 관리자 권한으로 그쪽 권한까지 갈아엎게 된다. 그래서 링크가 없는 하위 트리만 icacls /T 한 번으로
  빠르게 처리하고(보통은 전부 이 경우), 링크가 섞인 폴더는 한 단계씩 내려가며 링크는 링크 자체만(/L) 처리한다.
  (루트를 잠글 때의 상속 전파는 정션을 넘어가지 않는다 — 이것도 직접 확인함.)
#>
function Reset-TreeAcl {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Warnings,
    [scriptblock]$Tick
  )
  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  } catch {
    return   # 그 사이 없어진 항목(PostgreSQL 임시 파일 등) — 할 일이 없다.
  }
  $isLink = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
  if ($item.PSIsContainer -and -not $isLink -and -not (Test-TreeHasDirLink -Dir $Path -Tick $Tick)) {
    Invoke-IcaclsOrWarn -Warnings $Warnings -Tick $Tick -Arguments @($Path, '/setowner', "*$AclSidAdmins", '/T', '/C', '/L')
    Invoke-IcaclsOrWarn -Warnings $Warnings -Tick $Tick -Arguments @($Path, '/reset', '/T', '/C', '/L')
    return
  }
  # 파일 하나, 링크 자체, 또는 링크가 섞인 폴더 "자신"만.
  Invoke-IcaclsOrWarn -Warnings $Warnings -Tick $Tick -Arguments @($Path, '/setowner', "*$AclSidAdmins", '/C', '/L')
  Invoke-IcaclsOrWarn -Warnings $Warnings -Tick $Tick -Arguments @($Path, '/reset', '/C', '/L')
  if ($isLink -and $item.PSIsContainer) {
    $Warnings.Add("폴더 링크(정션/심볼릭 링크)는 따라 들어가지 않았습니다 — 링크가 가리키는 폴더의 권한은 직접 확인하세요: $Path")
    return
  }
  if ($item.PSIsContainer) {
    try {
      $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
    } catch {
      $Warnings.Add("$Path 안의 목록을 읽지 못해 그 아래 권한 정리를 건너뛰었습니다: $($_.Exception.Message)")
      return
    }
    foreach ($child in $children) {
      Reset-TreeAcl -Path $child.FullName -Warnings $Warnings -Tick $Tick
    }
  }
}

<#
  폴더 하나를 SYSTEM/Administrators 전용으로 잠근다(비밀값 폴더, 백업 폴더, 설치 폴더 밖의 첨부파일
  저장소). 핵심 잠금(상속 끊기 + 두 SID 전체 권한 + 다른 직접 항목 제거)이 실패하면 예외를 던진다 — 잠긴
  줄 알고 비밀값을 쓰는 일이 없게. 그 뒤의 정리(소유자, 안쪽 항목의 개별 권한)는 실패해도 잠금 자체는
  이미 걸려 있으므로 경고 문자열 목록으로 돌려준다.
#>
function Set-AdminOnlyAcl {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [scriptblock]$Tick
  )
  $Path = $Path.TrimEnd('\')
  $kind = Get-FolderLockKind -Path $Path
  if ($kind -ne 'Local') { throw "$Path 는 $($AclKindText[$kind])라서 접근 권한을 잠그지 않았습니다." }
  $warnings = New-Object System.Collections.Generic.List[string]
  Invoke-Icacls -Tick $Tick -Arguments @($Path, '/inheritance:r', '/grant:r', "*${AclSidSystem}:(OI)(CI)F", "*${AclSidAdmins}:(OI)(CI)F")
  Remove-ExtraAllowAces -Path $Path -AllowedSids @($AclSidSystem, $AclSidAdmins) -Tick $Tick
  Invoke-IcaclsOrWarn -Warnings $warnings -Tick $Tick -Arguments @($Path, '/setowner', "*$AclSidAdmins", '/C', '/L')
  # 안쪽 파일·폴더는 직접 붙은 권한을 지우고 위 권한만 물려받게 한다(이미 잠긴 폴더면 변화 없음).
  foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
    Reset-TreeAcl -Path $child.FullName -Warnings $warnings -Tick $Tick
  }
  return $warnings.ToArray()
}

<#
  설치 폴더({app}) 전체를 잠근다 — Setup-TangoTalkServer.ps1(PostgreSQL 설치 직후)과 Update-Server.ps1
  (매 업데이트)이 부른다. 몇 번을 다시 실행해도 같은 결과가 된다. 핵심 단계가 실패하면 예외를 던지고,
  정리 단계의 실패는 경고 문자열 목록으로 돌려준다.
#>
function Protect-InstallDir {
  param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [string]$PgServiceName = 'postgresql-tangotalk',
    [scriptblock]$Tick
  )
  $AppDir = $AppDir.TrimEnd('\')
  $kind = Get-FolderLockKind -Path $AppDir
  if ($kind -ne 'Local') { throw "설치 경로($AppDir)가 $($AclKindText[$kind])라서 접근 권한을 잠그지 않았습니다." }
  # 설치 폴더 안의 핵심 데이터 폴더가 링크(정션/심볼릭 링크)이면, 그 안에 쓰거나 읽을 비밀값·DB·백업·
  # 첨부파일이 링크가 가리키는 "다른" 폴더로 새어 나가거나 거기서 읽힌다. 정상 설치는 이 폴더들을 링크로
  # 만들지 않으므로(공간이 필요하면 설치 경로 자체나 UPLOADS_DIR로 옮긴다), 링크가 있으면 손댄 흔적으로
  # 보고 잠그지 않고 멈춘다 — 예전 넓은 권한 시절 아무나 여기에 정션을 심을 수 있었다.
  foreach ($rel in @('secrets', 'backups', 'pgsql-data', 'server\uploads', 'server\certs')) {
    if (Test-ReparsePoint -Path (Join-Path $AppDir $rel)) {
      throw "설치 폴더 안의 '$rel' 폴더가 링크(정션/심볼릭 링크)입니다 — 손댄 흔적일 수 있어 접근 권한을 잠그지 않았습니다. 이 링크를 지우거나 서버를 새로 설치한 뒤 다시 시도하세요."
    }
  }
  $warnings = New-Object System.Collections.Generic.List[string]

  # ── 1) PostgreSQL 서비스 계정 권한 — 루트를 잠그기 "전에" ──────────────────
  # PostgreSQL은 LocalSystem이 아니라 EDB 설치 프로그램 기본값인 NetworkService로 돈다. 지금까지는 C:\에서
  # 물려받은 Users 읽기 권한으로 pgsql\bin의 실행 파일을 읽어 왔으므로, 루트를 잠그기 전에 그 계정에 직접
  # 권한을 줘야 한다 — 순서가 바뀌면 실행 중인 DB가 새 연결마다 띄우는 postgres.exe를 못 읽는 순간이 생긴다.
  # (링크로 바뀌어 있는 폴더는 여기서 빼고 4)의 Reset-TreeAcl이 링크로 다룬다 — 권한을 줘도 링크가 가리키는
  # 엉뚱한 폴더에 붙는다. 링크 너머는 루트 잠금이 전파되지도 않으므로 DB는 지금처럼 돈다.)
  $pgRights = @{ 'pgsql' = 'RX'; 'pgsql-data' = 'F' }
  $pgDirs = @($pgRights.Keys | Where-Object {
      $candidate = Get-Item -LiteralPath (Join-Path $AppDir $_) -Force -ErrorAction SilentlyContinue
      $candidate -and $candidate.PSIsContainer -and -not ($candidate.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    })
  $pgSid = $null
  $freezePg = $false
  if ($pgDirs.Count -gt 0) {
    $pgServiceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$PgServiceName"
    if (Test-Path -LiteralPath $pgServiceKey) {
      $pgAccount = (Get-ItemProperty -LiteralPath $pgServiceKey -ErrorAction SilentlyContinue).ObjectName
      if ($pgAccount) { $pgSid = ConvertTo-AccountSid -Account $pgAccount } else { $pgSid = $AclSidSystem }
      if (-not $pgSid) {
        # 계정을 모르는 채로 잠그면 DB가 멈춘다 — pgsql/pgsql-data는 지금 권한을 그대로 고정해 두고 넘어간다.
        $freezePg = $true
        $warnings.Add("PostgreSQL 서비스 계정($pgAccount)을 확인하지 못해 pgsql/pgsql-data 폴더는 지금 권한 그대로 두었습니다 — 그 계정에 두 폴더 권한을 직접 준 뒤 다시 실행하세요.")
      }
    } else {
      # 서비스가 아직(또는 더는) 없으면 EDB 설치 프로그램이 쓸 기본 계정으로 준비해 둔다.
      $pgSid = $AclSidNetworkService
    }
  }
  $pgNeedsGrant = $pgSid -and ($pgSid -ne $AclSidSystem) -and ($pgSid -ne $AclSidAdmins)
  foreach ($name in $pgDirs) {
    $dir = Join-Path $AppDir $name
    if ($freezePg) {
      # 상속을 끊으면서 지금 물려받은 항목을 직접 항목으로 복사해 둔다 — 아래에서 루트를 잠가도 그대로다.
      Invoke-Icacls -Tick $Tick -Arguments @($dir, '/inheritance:d')
    } elseif ($pgNeedsGrant) {
      Invoke-Icacls -Tick $Tick -Arguments @($dir, '/grant:r', "*${pgSid}:(OI)(CI)$($pgRights[$name])")
    }
  }

  # ── 2) 루트: 상속 끊기 + SYSTEM/Administrators 전체 권한(하위 상속) ─────────
  # Users는 이 폴더 "목록"만(하위로 상속 안 됨) — 파일 읽기는 5)에서 시작 메뉴용 파일에만 따로 준다.
  # PostgreSQL 계정에도 이 폴더 목록 권한을 남긴다(EDB 설치 프로그램이 데이터 폴더의 상위 경로마다 주는
  # "경로 읽기" 권한과 같은 것 — 혹시 하위 상속으로 걸려 있었다면 /grant:r이 이 폴더 전용으로 바꾼다).
  $rootAllowed = @($AclSidSystem, $AclSidAdmins, $AclSidUsers)
  $rootGrants = @("*${AclSidSystem}:(OI)(CI)F", "*${AclSidAdmins}:(OI)(CI)F", "*${AclSidUsers}:RX")
  if ($pgNeedsGrant -and -not $freezePg) {
    $rootAllowed += $pgSid
    $rootGrants += "*${pgSid}:RX"
  }
  Invoke-Icacls -Tick $Tick -Arguments (@($AppDir, '/inheritance:r', '/grant:r') + $rootGrants)
  Remove-ExtraAllowAces -Path $AppDir -AllowedSids $rootAllowed -Tick $Tick

  # ── 3) 루트 자신의 소유자 → Administrators(안쪽은 4)의 Reset-TreeAcl이 함께 바꾼다) ──
  Invoke-IcaclsOrWarn -Warnings $warnings -Tick $Tick -Arguments @($AppDir, '/setowner', "*$AclSidAdmins", '/C', '/L')

  # ── 4) 하위 항목: 소유자 Administrators + 직접 붙은 권한을 지우고 루트 권한만 물려받게 ──────
  # 예전 버전이 .env·.jwt-secret·DB 비밀번호 파일마다 걸던 "Administrators:(R)"(읽기 전용이라 관리자도
  # .env를 고칠 수 없었음)와, 누가 넣어둔 개별 권한이 여기서 정리된다. PostgreSQL 두 폴더는 1)의 계정 권한을
  # 폴더 자체에 남겨야 하므로 폴더는 상속만 다시 켜고 다른 직접 항목만 지운 뒤, "안쪽"만 되돌린다.
  foreach ($child in @(Get-ChildItem -LiteralPath $AppDir -Force -ErrorAction Stop)) {
    if ($pgDirs -contains $child.Name) {
      if ($freezePg) { continue }
      try {
        Invoke-Icacls -Tick $Tick -Arguments @($child.FullName, '/inheritance:e')
        $allowed = @($AclSidSystem, $AclSidAdmins)
        if ($pgNeedsGrant) { $allowed += $pgSid }
        Remove-ExtraAllowAces -Path $child.FullName -AllowedSids $allowed -Tick $Tick
      } catch {
        $warnings.Add($_.Exception.Message)
      }
      Invoke-IcaclsOrWarn -Warnings $warnings -Tick $Tick -Arguments @($child.FullName, '/setowner', "*$AclSidAdmins", '/C', '/L')
      try {
        $grandchildren = @(Get-ChildItem -LiteralPath $child.FullName -Force -ErrorAction Stop)
      } catch {
        $grandchildren = @()
        $warnings.Add("$($child.FullName) 안의 목록을 읽지 못해 그 아래 권한 정리를 건너뛰었습니다: $($_.Exception.Message)")
      }
      foreach ($grandchild in $grandchildren) {
        Reset-TreeAcl -Path $grandchild.FullName -Warnings $warnings -Tick $Tick
      }
    } else {
      Reset-TreeAcl -Path $child.FullName -Warnings $warnings -Tick $Tick
    }
  }

  # ── 5) 시작 메뉴가 일반 권한으로 여는 루트 파일만 Users 읽기 ─────────────────
  # 관리용 바로가기("새 기기 페어링 코드 발급" 포함 — .env의 포트를 읽어야 해서)와 탐색기에서 여는
  # Grant-ServerAdmin.ps1은 powershell이 스크립트를 "읽은 뒤"에 스스로 관리자 권한으로 다시 실행한다. 안내문
  # (README*)은 메모장·브라우저가, 제거 프로그램(unins*)은 "설치된 앱"이 일반 권한으로 먼저 연다. install.log 등
  # 나머지는 관리자 전용으로 남긴다.
  $userFiles = @(Get-ChildItem -LiteralPath $AppDir -File -Force -ErrorAction Stop |
      Where-Object { $_.Name -like '*.ps1' -or $_.Name -like 'README*' -or $_.Name -like 'unins*' })
  foreach ($file in $userFiles) {
    Invoke-IcaclsOrWarn -Warnings $warnings -Tick $Tick -Arguments @($file.FullName, '/grant:r', "*${AclSidUsers}:RX")
  }
  return $warnings.ToArray()
}
