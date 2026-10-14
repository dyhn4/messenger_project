<#
.SYNOPSIS
  "복원" 시작 메뉴 항목 — 백업으로 서버를 되돌린다. 지금 DB에 있는 내용은 전부 그 백업 시점 내용으로 바뀐다.

.DESCRIPTION
  두 가지 백업을 받는다(파일 선택 창에서 고른 파일로 가른다):
  - 전체 백업(관리자 콘솔 "백업" 탭·시작 메뉴 "백업" — server\src\backup.js): 백업 폴더 안의 manifest.json을 고르면
    server\scripts\restore-backup.mjs가 DB·서버 설정·인증서와(옆에 있으면) 첨부파일까지 되돌린다. 백업 암호가 필요하다.
    DB는 한 트랜잭션으로 바꿔 실패하면 그대로 남고, 바꾸기 전 DB·설정은 backups 폴더에 따로 남긴다. 끝나면 마이그레이션으로
    지금 서버 버전에 맞춘다. 서버 PC가 고장 나 새 PC에 서버를 새로 설치한 뒤 되살릴 때도 이것으로 한다 — 새 설치에는 회원이
    없어 운영자 확인 대신 백업 암호로만 확인한다.
  - 예전 백업(.dump — 예전 "백업"이 만든 DB만의 백업): 예전처럼 pg_restore --clean --if-exists로 되돌린다.
  DB 데이터 초기화(Reset-Data.ps1)만큼 위험한 작업이라 같은 방식으로 안전장치를 둔다 —
  서버 운영자 계정 본인 확인 + "RESTORE" 입력 확인.
#>

# ── 관리자 권한 확인/승격 ───────────────────────────────────────────────
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$AppDir = $PSScriptRoot
$ServerDir = Join-Path $AppDir 'server'
$PgBin = Join-Path $AppDir 'pgsql\bin'
$SecretsDir = Join-Path $AppDir 'secrets'
$BackupsDir = Join-Path $AppDir 'backups'
$NssmExe = Join-Path $AppDir 'tools\nssm.exe'
$NodeExe = Join-Path $AppDir 'node\node.exe'
$NodeServiceName = 'TangoTalkServer'
$PgPort = 55432
$DbName = 'messenger'
$DbAppUser = 'messenger_app'

# 서버 운영자 아이디/비밀번호 확인(server\scripts\verify-admin.mjs) — 맞으면 $true. Reset-Data.ps1·Restore-Data.ps1·
# Uninstall-Full.ps1에 똑같이 들어 있다 — 고치면 셋 다 고치고 tests\Admin-Verify.Tests.ps1을 돌릴 것(셋이 같은지도 본다).
# - 비밀번호는 stdin(파이프)으로만 넘긴다 — 명령줄 인자는 이 PC의 다른 계정도 프로세스 목록에서 볼 수 있고, 환경 변수나
#   파일로 넘기면 흔적이 남는다.
# - Windows PowerShell 5.1은 파이프로 외부 프로그램에 넘기는 글자를 $OutputEncoding(기본값 ASCII)으로 바꿔 한글 등 ASCII
#   밖의 글자를 전부 '?'로 보낸다 — 그런 글자가 든 비밀번호는 맞게 쳐도 늘 실패했다. 그래서 이 함수 안에서만 BOM 없는
#   UTF-8로 바꾼다(verify-admin.mjs가 UTF-8로 읽는다). New-Object로 만들면 PSObject로 감싸여, 함수 안 지역 변수에서는
#   인코딩으로 인식되지 않고 조용히 ASCII로 돌아간다(직접 확인) — 그래서 ::new()로 만든다.
# - node는 서버 폴더에서 실행하고(다른 관리 스크립트와 같은 규칙) 끝나면 원래 위치로 돌아온다 — 뒤에서 띄우는 프로그램이
#   지울 대상인 server 폴더를 작업 폴더로 물려받지 않게(Uninstall-Full.ps1).
function Test-ServerAdminPassword {
    param([string]$NodeExe, [string]$ServerDir, [string]$Username, [securestring]$Password)
    $ok = $false
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $previousOutputEncoding = $OutputEncoding
    Push-Location -LiteralPath $ServerDir
    try {
        $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        # node가 아예 실행되지 못하면 $LASTEXITCODE가 예전 값(0일 수도 있음) 그대로 남아 통과처럼 보이므로 먼저 지워 둔다.
        $global:LASTEXITCODE = -1
        # node가 stdout에 무엇을 쓰든 이 함수의 결과($true/$false)에 섞이지 않게 화면으로만 보낸다.
        $plainPassword | & $NodeExe (Join-Path $ServerDir 'scripts\verify-admin.mjs') $Username | Out-Host
        $ok = ($LASTEXITCODE -eq 0)
    } catch {
        Write-Host "운영자 확인을 실행하지 못했습니다: $($_.Exception.Message)" -ForegroundColor Red
        $ok = $false
    } finally {
        $OutputEncoding = $previousOutputEncoding
        $plainPassword = $null
        Pop-Location
    }
    return $ok
}

# 전체 백업 복원 도우미(server\scripts\restore-backup.mjs)를 실행한다 — 결과 @{ ExitCode; Output }.
# - 백업 암호([Secret])는 표준 입력으로만 넘긴다(명령줄 인자는 이 PC의 다른 계정도 프로세스 목록에서 볼 수 있다). PowerShell 파이프
#   (… | & node)는 Windows PowerShell 5.1이 $OutputEncoding(기본 ASCII)으로 바꿔 한글을 '?'로 보내서, 프로세스의 표준 입력에 BOM
#   없는 UTF-8 바이트를 직접 쓴다($OutputEncoding과 상관없다). 운영자 확인은 위 Test-ServerAdminPassword가 따로 맡는다 — node에
#   파이프로 넘기는 곳은 그 함수 하나뿐이어야 한다(tests\Admin-Verify.Tests.ps1이 본다).
# - [Capture]면 출력(check의 JSON 한 줄)을 UTF-8로 받아 돌려주고, 아니면 node가 이 창에 바로 쓴다(한글이 그대로 보인다).
# - 인자는 큰따옴표로 감싸 넘긴다 — 경로에 공백·한글이 있어도 된다(Windows 경로에는 큰따옴표가 들어갈 수 없다). 끝의 \는 떼어
#   닫는 따옴표를 가리지 않게 한다.
function Invoke-RestoreScript {
    param([string]$NodeExe, [string]$ServerDir, [string[]]$Arguments, [securestring]$Secret, [switch]$Capture)
    $all = @((Join-Path $ServerDir 'scripts\restore-backup.mjs')) + @($Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $NodeExe
    $psi.Arguments = (@($all | ForEach-Object { '"' + $_.TrimEnd('\') + '"' }) -join ' ')
    $psi.WorkingDirectory = $ServerDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    if ($Capture) {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    }
    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        if ($Secret) {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
            try {
                $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes([System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr))
            } finally {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
            $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
        $process.StandardInput.Close()
        $output = ''
        if ($Capture) {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            $output = ($stdout.Result + $stderr.Result).Trim()
        } else {
            $process.WaitForExit()
        }
        return @{ ExitCode = $process.ExitCode; Output = $output }
    } finally {
        $process.Dispose()
    }
}

# node는 서버 폴더에서 실행한다 — verify-admin.mjs는 자기 위치 기준으로 .env를 읽지만, .env를 "현재 폴더"에서 읽는
# 서버 스크립트(reset-data.mjs 등 dotenv/config)와 같은 규칙으로 맞춰 둔다(승격된 PowerShell은 System32에서 시작한다).
Set-Location -LiteralPath $ServerDir

Write-Host '================================================================'
Write-Host ' TangoTalk 복원'
Write-Host '================================================================'
Write-Host ''
Write-Host '복원할 백업을 고르세요:'
Write-Host '  - 전체 백업(관리자 콘솔 "백업" 탭·시작 메뉴 "백업"): 백업 폴더(tangotalk_날짜_시각) 안의 manifest.json'
Write-Host '    서버 PC가 고장 나 새 PC에 설치했다면 외부 백업 위치의 TangoTalk-Backup 폴더 안에서 고르세요.'
Write-Host '  - 예전 백업(DB만): messenger_날짜_시각.dump'
Write-Host ''

# ── 복원할 백업 선택 ────────────────────────────────────────────────────
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = '복원할 백업 선택 — 백업 폴더 안의 manifest.json(전체 백업) 또는 .dump(예전 DB 백업)'
$dialog.Filter = 'TangoTalk 백업 (manifest.json, *.dump)|manifest.json;*.dump|모든 파일 (*.*)|*.*'
$dialog.InitialDirectory = if (Test-Path $BackupsDir) { $BackupsDir } else { $AppDir }
if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host '취소되었습니다.'
    exit 0
}
$selected = $dialog.FileName
$isFull = (Split-Path -Leaf $selected) -ieq 'manifest.json'
Write-Host "선택한 파일: $selected"
Write-Host ''

$pgRestore = Join-Path $PgBin 'pg_restore.exe'
$pwFile = Join-Path $SecretsDir 'db-app.pw'

if ($isFull) {
    # 전체 백업 — DB·서버 설정·인증서(+ 옆에 있으면 첨부파일)를 server\scripts\restore-backup.mjs로 되돌린다.
    $backupDir = Split-Path -Parent $selected
    if (-not (Test-Path -LiteralPath $NodeExe) -or -not (Test-Path -LiteralPath (Join-Path $ServerDir 'scripts\restore-backup.mjs'))) {
        Write-Host '이 서버 버전은 전체 백업 복원을 지원하지 않습니다 — 서버를 먼저 업데이트하세요.' -ForegroundColor Red
        Read-Host '엔터를 누르면 창이 닫힙니다'
        exit 1
    }
    $check = Invoke-RestoreScript -NodeExe $NodeExe -ServerDir $ServerDir -Arguments @('check', $backupDir) -Capture
    $info = $null
    if ($check.ExitCode -eq 0) {
        try { $info = $check.Output | ConvertFrom-Json } catch { $info = $null }
    }
    if (-not $info) {
        Write-Host ($(if ($check.Output) { $check.Output } else { '백업 정보를 읽지 못했습니다.' })) -ForegroundColor Red
        Read-Host '엔터를 누르면 창이 닫힙니다'
        exit 1
    }
    $createdAt = $info.createdAt
    try { $createdAt = ([DateTimeOffset]::Parse($info.createdAt)).LocalDateTime.ToString('yyyy-MM-dd HH:mm') } catch { }
    $madeOn = if ($info.host) { "  (만든 PC: $($info.host))" } else { '' }
    Write-Host "백업 시각: $createdAt$madeOn"
    if ($info.mirror) {
        Write-Host "첨부파일 백업: $($info.mirror)"
    } else {
        Write-Host '첨부파일 백업: 없음 — 백업 폴더 옆에 uploads 폴더가 없습니다(같은 PC로 되돌린다면 첨부파일은 그대로 있습니다).' -ForegroundColor Yellow
    }
    if (-not $info.compatible) {
        Write-Host ''
        Write-Host $info.compatError -ForegroundColor Red
        Read-Host '엔터를 누르면 창이 닫힙니다'
        exit 1
    }
    Write-Host ''
    Write-Host '지금 서버의 회원/팀/대화방/메시지와 서버 설정·인증서가 모두 위 백업 시점 내용으로 바뀝니다.' -ForegroundColor Yellow
    Write-Host '(지금 DB와 설정 파일은 바꾸기 전에 backups 폴더에 따로 남겨 둡니다.)' -ForegroundColor Yellow
    # 회원이 하나도 없는 서버(새 PC에 막 설치함)에는 확인할 운영자가 없다 — 그때는 백업 암호로만 확인한다. 회원 수를 못 읽었으면
    # (null) 확인한다.
    $needAdminCheck = ($info.users -ne 0)
} else {
    # 예전 백업(.dump — DB만) — 예전과 같이 pg_restore로 되돌린다.
    if (-not (Test-Path $pgRestore)) {
        Write-Host "pg_restore.exe를 찾을 수 없습니다($pgRestore) — 서버가 정상 설치됐는지 확인하세요." -ForegroundColor Red
        Read-Host '엔터를 누르면 창이 닫힙니다'
        exit 1
    }
    if (-not (Test-Path $pwFile)) {
        Write-Host "DB 비밀번호 파일을 찾을 수 없습니다($pwFile) — 서버가 정상 설치됐는지 확인하세요." -ForegroundColor Red
        Read-Host '엔터를 누르면 창이 닫힙니다'
        exit 1
    }
    Write-Host "지금 DB에 있는 회원/팀/대화방/메시지 등 모든 내용이 위 백업 시점 내용으로" -ForegroundColor Yellow
    Write-Host "완전히 덮어써집니다 — 되돌릴 수 없습니다." -ForegroundColor Yellow
    $needAdminCheck = $true
}
Write-Host ''

if ($needAdminCheck) {
    # "DB 데이터 초기화"와 같은 이유로 — 이 PC 앞에 앉을 수 있다는 것만으로 복원할 수 있으면
    # 안 되므로, 실제 서버 운영자 계정으로 먼저 본인 확인을 한다.
    Write-Host '먼저 서버 운영자 계정으로 본인 확인이 필요합니다.'
    $username = Read-Host '서버 운영자 아이디'
    $securePassword = Read-Host '비밀번호' -AsSecureString
    $verified = Test-ServerAdminPassword -NodeExe $NodeExe -ServerDir $ServerDir -Username $username -Password $securePassword
    $securePassword.Dispose()

    if (-not $verified) {
        Write-Host ''
        Write-Host '서버 운영자 인증에 실패했습니다. 복원을 진행하지 않습니다.' -ForegroundColor Red
        Read-Host '엔터를 누르면 창이 닫힙니다'
        exit 1
    }
    Write-Host '운영자 확인 완료.' -ForegroundColor Green
} else {
    Write-Host '이 서버에는 아직 회원이 없어(새로 설치한 서버) 운영자 확인을 건너뜁니다 — 백업 암호로 확인합니다.'
}
Write-Host ''

$backupPassword = $null
$restoreArgs = @()
if ($isFull) {
    for ($attempt = 1; $attempt -le 3 -and -not $backupPassword; $attempt++) {
        $candidate = Read-Host '백업 암호' -AsSecureString
        $result = Invoke-RestoreScript -NodeExe $NodeExe -ServerDir $ServerDir -Arguments @('verify', $backupDir) -Secret $candidate
        if ($result.ExitCode -eq 0) {
            $backupPassword = $candidate
        } else {
            $candidate.Dispose()
            if ($result.ExitCode -ne 2) {
                Read-Host '엔터를 누르면 창이 닫힙니다'
                exit 1
            }
        }
    }
    if (-not $backupPassword) {
        Write-Host '백업 암호가 3번 틀려 복원하지 않습니다. 아무 것도 바꾸지 않았습니다.' -ForegroundColor Red
        Read-Host '엔터를 누르면 창이 닫힙니다'
        exit 1
    }
    $restoreArgs = @('restore', $backupDir)
    if ($info.mirror) {
        $answer = Read-Host '첨부파일도 복원할까요? 이미 있는 파일은 그대로 둡니다 (Y/n)'
        if ($answer -match '^\s*[nN]') { $restoreArgs += '--no-uploads' }
    }
    Write-Host ''
}

$confirm = Read-Host '계속하려면 정확히 RESTORE 를 입력하세요'
if ($confirm -cne 'RESTORE') {
    if ($backupPassword) { $backupPassword.Dispose() }
    Write-Host '취소되었습니다. 아무 것도 바꾸지 않았습니다.'
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 0
}

Write-Host ''
Write-Host '복원을 진행합니다...'

# 복원 도중 서버가 DB에 계속 쓰면 안 되므로 잠깐 멈춘다.
if (Test-Path $NssmExe) {
    & $NssmExe stop $NodeServiceName 2>$null | Out-Null
}

if ($isFull) {
    try {
        $result = Invoke-RestoreScript -NodeExe $NodeExe -ServerDir $ServerDir -Arguments $restoreArgs -Secret $backupPassword
    } finally {
        $backupPassword.Dispose()
    }
    $ok = ($result.ExitCode -eq 0)
    if ($ok) {
        # 옛 백업이면 DB를 지금 서버 버전에 맞춘다(설치 프로그램 5단계와 같은 방법 — drizzle.config.js가 이 폴더의 .env를 읽는다).
        Write-Host ''
        Write-Host '- DB를 지금 서버 버전에 맞추는 중(마이그레이션)...'
        $global:LASTEXITCODE = -1
        & $NodeExe (Join-Path $ServerDir 'node_modules\drizzle-kit\bin.cjs') 'migrate'
        if ($LASTEXITCODE -ne 0) {
            $ok = $false
            Write-Host '마이그레이션에 실패했습니다 — 위 오류를 확인하고, 필요하면 서버 업데이트를 다시 적용하세요.' -ForegroundColor Red
        }
    }
} else {
    $dbPassword = (Get-Content $pwFile -Raw).Trim()
    $env:PGPASSWORD = $dbPassword
    try {
        $args = @('-h', 'localhost', '-p', $PgPort, '-U', $DbAppUser, '-d', $DbName, '--clean', '--if-exists', $selected)
        $out = & $pgRestore @args 2>&1
        $ok = ($LASTEXITCODE -eq 0)
    } finally {
        Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
        $dbPassword = $null
    }
}

if (Test-Path $NssmExe) {
    & $NssmExe start $NodeServiceName 2>$null | Out-Null
}

if (-not $ok) {
    Write-Host ''
    if ($isFull) {
        Write-Host '복원에 실패했습니다 — 위 메시지를 확인하세요.' -ForegroundColor Red
        Write-Host 'DB 복원 단계에서 실패했다면 DB는 복원 전 그대로입니다(한 번에 되돌려짐). 서버는 다시 시작했습니다.' -ForegroundColor Yellow
    } else {
        Write-Host '복원 중 오류가 발생했습니다:' -ForegroundColor Red
        Write-Host ($out | Out-String)
        Write-Host '서버는 다시 시작했지만 DB 내용이 일부만 반영됐을 수 있습니다 — 필요하면 다시' -ForegroundColor Yellow
        Write-Host '백업 파일로 복원을 시도하거나 DB 데이터 초기화 후 재시도하세요.' -ForegroundColor Yellow
    }
    Read-Host '엔터를 누르면 창이 닫힙니다'
    exit 1
}

Write-Host ''
Write-Host '완료되었습니다 — 서버가 다시 시작됐습니다.' -ForegroundColor Green
if ($isFull) {
    Write-Host '서버 주소(IP)가 백업한 서버와 다르면, 앱은 새 주소로 다시 연결해야 합니다(외부 접속 주소·DDNS를 쓰고 있었다면' -ForegroundColor Yellow
    Write-Host '공유기 포트포워딩을 이 PC로 바꾸면 그대로 연결됩니다).' -ForegroundColor Yellow
}
Read-Host '엔터를 누르면 창이 닫힙니다'
