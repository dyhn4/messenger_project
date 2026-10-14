<#
.SYNOPSIS
  "서버 업데이트" 시작 메뉴 항목 — package_server_update.ps1로 만든 업데이트 zip을 골라서
  적용하는 간단한 창을 띄운다. DB 데이터는 건드리지 않는다(코드/패키지/스키마만 갱신). 그 전에
  매번 설치 폴더 접근 권한을 SYSTEM/Administrators 전용으로 다시 맞춘다(Folder-Acl.ps1).

.DESCRIPTION
  update_server.ps1(저장소 루트, pm2로 운영하는 서버용)과 하는 일은 같지만, 이 설치
  프로그램으로 깐 서버는 pm2가 아니라 NSSM 서비스(TangoTalkServer)로 떠 있고 명령줄 대신
  파일 선택 창을 쓰는 게 더 편해서 별도로 만들었다. NSSM 서비스 재시작에는 관리자 권한이
  필요해서, 관리자가 아니면 스스로 관리자 권한으로 다시 실행한다.
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
$NodeExe = Join-Path $AppDir 'node\node.exe'
$NpmCli = Join-Path $AppDir 'node\node_modules\npm\bin\npm-cli.js'
$NssmExe = Join-Path $AppDir 'tools\nssm.exe'
$NodeServiceName = 'TangoTalkServer'

# 설치 폴더 접근 권한 잠금 공용 함수(설치 프로그램이 이 스크립트와 같은 폴더에 함께 넣는다 — Folder-Acl.ps1).
$AclHelper = Join-Path $AppDir 'Folder-Acl.ps1'
if (Test-Path -LiteralPath $AclHelper) { . $AclHelper }

# ── 창 구성 ──────────────────────────────────────────────────────────────
$form = New-Object System.Windows.Forms.Form
$form.Text = 'TangoTalk 서버 업데이트'
$form.ClientSize = New-Object System.Drawing.Size(480, 360)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

$label1 = New-Object System.Windows.Forms.Label
$label1.Text = '업데이트 파일(.zip)을 선택하세요 — 개발 PC에서 package_server_update.ps1로 만든 파일입니다.'
$label1.Location = New-Object System.Drawing.Point(15, 15)
$label1.Size = New-Object System.Drawing.Size(450, 40)
$form.Controls.Add($label1)

$pathBox = New-Object System.Windows.Forms.TextBox
$pathBox.Location = New-Object System.Drawing.Point(15, 58)
$pathBox.Size = New-Object System.Drawing.Size(340, 24)
$pathBox.ReadOnly = $true
$form.Controls.Add($pathBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = '찾아보기...'
$browseButton.Location = New-Object System.Drawing.Point(365, 57)
$browseButton.Size = New-Object System.Drawing.Size(100, 26)
$form.Controls.Add($browseButton)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = '업데이트 시작'
$startButton.Location = New-Object System.Drawing.Point(15, 94)
$startButton.Size = New-Object System.Drawing.Size(450, 34)
$startButton.Enabled = $false
$form.Controls.Add($startButton)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(15, 140)
$logBox.Size = New-Object System.Drawing.Size(450, 205)
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($logBox)

function Write-Log {
    param([string]$Message)
    $logBox.AppendText("$Message`r`n")
    $logBox.SelectionStart = $logBox.Text.Length
    $logBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# 서버 서비스(NSSM)의 환경 변수에 NODE_ENV=production을 넣는다 — 되면 $true. Setup-TangoTalkServer.ps1에도 똑같이 들어 있다 —
# 고치면 둘 다 고치고 tests\Service-Env.Tests.ps1을 돌릴 것(둘이 같은지도 본다).
# - Express는 NODE_ENV가 production이 아니면, 처리하지 못한 오류의 응답에 스택 트레이스(서버의 절대 경로)를 그대로
#   싣는다 — 서버를 인터넷에 열면 누구나 볼 수 있다. 서버 코드에는 NODE_ENV를 따로 보는 곳이 없다.
# - 이 스크립트 자신의 환경 변수($env:NODE_ENV)로 넣으면 안 된다 — 같은 프로세스에서 도는 npm install(Update-Server.ps1)이
#   devDependencies를 빼고 설치해(npm 7+) 마이그레이션에 쓰는 drizzle-kit이 깨진다. 그래서 서비스 설정에만 넣는다.
# - NSSM은 서비스를 시작할 때 서비스 키의 Parameters\AppEnvironmentExtra(REG_MULTI_SZ, 한 줄에 "이름=값" 하나)를 읽어 환경
#   변수로 더한다. nssm set으로 여러 줄을 한 번에 넣는 방법은 NSSM 버전마다 달라(번들한 2.24에서는 확인하지 못했다 — 인자를
#   공백으로 이어 한 줄로 만들면 NODE_ENV가 조용히 안 들어간다) 그 값을 직접 읽고 쓴다. 관리자가 따로 넣어 둔 다른 변수는
#   그대로 두고 NODE_ENV 줄만 바꾼다(nssm get은 파이프로 받으면 UTF-16으로 출력해 깨져 읽히기도 한다).
# - 서비스는 시작할 때 이 값을 읽으므로 시작/재시작 "전에" 부른다. 서비스 키가 없으면(NSSM 서비스가 아니면) 만들지 않고 $false.
function Set-NodeServiceProductionEnv {
    $paramsKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$NodeServiceName\Parameters"
    try {
        $current = (Get-Item -LiteralPath $paramsKey -ErrorAction Stop).GetValue('AppEnvironmentExtra')
        $entries = [string[]](@(@($current) | Where-Object { $_ -and $_ -notmatch '^NODE_ENV=' }) + 'NODE_ENV=production')
        Set-ItemProperty -LiteralPath $paramsKey -Name 'AppEnvironmentExtra' -Value $entries -Type MultiString -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

$browseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'zip 파일 (*.zip)|*.zip'
    $dialog.Title = '업데이트 zip 파일 선택'
    $downloads = Join-Path $env:USERPROFILE 'Downloads'
    if (Test-Path $downloads) { $dialog.InitialDirectory = $downloads }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $pathBox.Text = $dialog.FileName
        $startButton.Enabled = $true
    }
})

$startButton.Add_Click({
    $zipPath = $pathBox.Text
    if (-not (Test-Path $zipPath)) {
        [System.Windows.Forms.MessageBox]::Show('선택한 파일을 찾을 수 없습니다.', '오류', 'OK', 'Error') | Out-Null
        return
    }

    $startButton.Enabled = $false
    $browseButton.Enabled = $false
    $logBox.Clear()
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    $aclWarnings = @()
    $serviceWarning = $null
    try {
        # 매 업데이트마다 설치 폴더 권한을 SYSTEM/Administrators 전용으로 다시 맞춘다(이유는 Folder-Acl.ps1).
        # 맨 먼저 하는 이유: 이번에 복사·설치되는 코드와 패키지도 처음부터 잠긴 폴더 안에 만들어지게. 업데이트
        # 자체와는 별개라 실패해도 업데이트는 계속하고 경고만 남긴다.
        Write-Log '1/5 설치 폴더 접근 권한 점검 중(파일이 많아 1~2분 걸릴 수 있습니다)...'
        try {
            if (-not (Get-Command Protect-InstallDir -ErrorAction SilentlyContinue)) {
                throw 'Folder-Acl.ps1을 찾을 수 없습니다 — 최신 서버 설치 프로그램(tangotalk-server-setup.exe)을 한 번 다시 실행하세요.'
            }
            $aclWarnings = @(Protect-InstallDir -AppDir $AppDir -Tick { [System.Windows.Forms.Application]::DoEvents() })
            Write-Log '  SYSTEM/Administrators 전용으로 잠금 완료'
        } catch {
            $aclWarnings = @("접근 권한을 잠그지 못했습니다: $($_.Exception.Message)")
        }
        foreach ($warning in $aclWarnings) { Write-Log "  경고: $warning" }

        Write-Log '2/5 업데이트 코드 적용 중...'
        $tmp = Join-Path $env:TEMP "server-update-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Expand-Archive -Path $zipPath -DestinationPath $tmp -Force

        # zip 안에는 .env/certs/uploads/releases/node_modules 같은 이 서버 고유의
        # 실데이터·비밀값이 애초에 없으므로(package_server_update.ps1이 제외해서 만듦)
        # 그대로 덮어써도 안전하다. 혹시 이 서버 쪽에 그런 폴더가 남아있어도 robocopy
        # 대상에서 제외해 절대 건드리지 않는다.
        $robocopyArgs = @(
            $tmp, $ServerDir, '/E',
            '/XD', 'node_modules', 'certs', 'uploads', 'releases', 'installer', 'deploy', 'backups',
            '/NFL', '/NDL', '/NJH', '/NJS'
        )
        robocopy @robocopyArgs | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "코드 적용 실패(robocopy 코드 $LASTEXITCODE)" }
        # 초보자용 도움말(guide/)은 서버가 그대로 서빙하는 정적 파일뿐이라 통째로 맞춘다(/MIR) —
        # 위 /E 복사는 새 파일을 더하기만 해서, 이름이 바뀌거나 빠진 스크린샷이 계속 남는다.
        $guideSrc = Join-Path $tmp 'guide'
        if (Test-Path $guideSrc) {
            robocopy $guideSrc (Join-Path $ServerDir 'guide') /MIR /NFL /NDL /NJH /NJS | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "도움말 적용 실패(robocopy 코드 $LASTEXITCODE)" }
            Write-Log '  도움말(guide) 갱신 완료'
        }
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log '  코드 적용 완료'

        Write-Log '3/5 패키지 설치 중 (npm install)...'
        Push-Location $ServerDir
        try {
            & $NodeExe $NpmCli install --no-audit --no-fund 2>&1 | ForEach-Object { Write-Log "  [npm] $_" }
            if ($LASTEXITCODE -ne 0) { throw "npm install 실패(종료 코드 $LASTEXITCODE)" }
        } finally {
            Pop-Location
        }
        Write-Log '  패키지 설치 완료'

        Write-Log '4/5 DB 마이그레이션 적용 중 — 기존 데이터는 그대로 두고 새로 추가된 구조만 반영합니다...'
        $drizzleKitCli = Join-Path $ServerDir 'node_modules\drizzle-kit\bin.cjs'
        Push-Location $ServerDir
        try {
            & $NodeExe $drizzleKitCli 'migrate' 2>&1 | ForEach-Object { Write-Log "  [migrate] $_" }
            if ($LASTEXITCODE -ne 0) { throw "마이그레이션 실패(종료 코드 $LASTEXITCODE)" }
        } finally {
            Pop-Location
        }
        Write-Log '  마이그레이션 완료'

        Write-Log '5/5 서버 재시작 중...'
        # 재시작 전에 서비스가 운영 모드(NODE_ENV=production)로 돌게 맞춘다(이유는 Set-NodeServiceProductionEnv). 콘솔 모드로
        # 설치해 서비스가 없으면 건너뛴다 — 그때는 "서버 콘솔로 실행"(Start-ServerConsole.ps1)이 직접 넣는다.
        if (Get-Service -Name $NodeServiceName -ErrorAction SilentlyContinue) {
            if (Set-NodeServiceProductionEnv) {
                Write-Log '  서버 서비스 운영 모드(NODE_ENV=production) 확인'
            } else {
                # nssm set … AppEnvironmentExtra는 그 칸을 통째로 바꿔 다른 환경 변수까지 지우므로 설정 창(nssm edit)으로 안내한다.
                $serviceWarning = "서버 서비스에 NODE_ENV=production을 넣지 못했습니다 — 처리하지 못한 오류가 나면 응답에 서버 내부 경로가 보일 수 있습니다. 관리자 권한 PowerShell에서 & `"$NssmExe`" edit $NodeServiceName 을 실행해 Environment 탭에 NODE_ENV=production 한 줄을 더하고(다른 줄은 그대로 두세요) [Edit service]를 누른 뒤 `"서버 재시작`"을 누르세요."
                Write-Log "  경고: $serviceWarning"
            }
        }
        & $NssmExe restart $NodeServiceName | Out-Null
        Write-Log '  서버 재시작 완료'

        $infoPath = Join-Path $ServerDir 'update-info.json'
        if (Test-Path $infoPath) {
            $info = Get-Content $infoPath -Raw | ConvertFrom-Json
            Write-Log ''
            Write-Log "적용된 버전: 커밋 $($info.commit) ($($info.builtAt) 빌드)"
        }

        Write-Log ''
        Write-Log '완료 — 서버가 새 코드로 재시작됐습니다. DB 데이터는 전혀 건드리지 않았습니다.'
        if ($aclWarnings.Count -gt 0 -or $serviceWarning) {
            $warningAreas = @()
            if ($aclWarnings.Count -gt 0) { $warningAreas += '설치 폴더 접근 권한 잠금' }
            if ($serviceWarning) { $warningAreas += '서버 서비스 운영 모드 설정' }
            [System.Windows.Forms.MessageBox]::Show(
                "업데이트가 완료됐습니다.`n`n다만 $($warningAreas -join '·') 중 경고가 있었습니다 — 창의 로그(`"경고:`" 줄)를 확인하세요.",
                'TangoTalk 서버 업데이트', 'OK', 'Warning'
            ) | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show('업데이트가 완료됐습니다.', 'TangoTalk 서버 업데이트', 'OK', 'Information') | Out-Null
        }
    } catch {
        Write-Log ''
        Write-Log "오류: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "업데이트 중 오류가 발생했습니다:`n`n$($_.Exception.Message)`n`n서버가 재시작되지 않았을 수 있습니다 — 필요하면 서비스 상태를 확인하세요.",
            'TangoTalk 서버 업데이트', 'OK', 'Error'
        ) | Out-Null
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $browseButton.Enabled = $true
        $startButton.Enabled = $true
    }
})

[System.Windows.Forms.Application]::Run($form)
