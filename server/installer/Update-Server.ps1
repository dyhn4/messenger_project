<#
.SYNOPSIS
  "서버 업데이트" 시작 메뉴 항목 — package_server_update.ps1로 만든 업데이트 zip을 골라서
  적용하는 간단한 창을 띄운다. DB 데이터는 건드리지 않는다(코드/패키지/스키마만 갱신).

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

    try {
        Write-Log '1/4 업데이트 코드 적용 중...'
        $tmp = Join-Path $env:TEMP "server-update-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Expand-Archive -Path $zipPath -DestinationPath $tmp -Force

        # zip 안에는 .env/certs/uploads/releases/node_modules 같은 이 서버 고유의
        # 실데이터·비밀값이 애초에 없으므로(package_server_update.ps1이 제외해서 만듦)
        # 그대로 덮어써도 안전하다. 혹시 이 서버 쪽에 그런 폴더가 남아있어도 robocopy
        # 대상에서 제외해 절대 건드리지 않는다.
        $robocopyArgs = @(
            $tmp, $ServerDir, '/E',
            '/XD', 'node_modules', 'certs', 'uploads', 'releases', 'installer', 'deploy',
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

        Write-Log '2/4 패키지 설치 중 (npm install)...'
        Push-Location $ServerDir
        try {
            & $NodeExe $NpmCli install --no-audit --no-fund 2>&1 | ForEach-Object { Write-Log "  [npm] $_" }
            if ($LASTEXITCODE -ne 0) { throw "npm install 실패(종료 코드 $LASTEXITCODE)" }
        } finally {
            Pop-Location
        }
        Write-Log '  패키지 설치 완료'

        Write-Log '3/4 DB 마이그레이션 적용 중 — 기존 데이터는 그대로 두고 새로 추가된 구조만 반영합니다...'
        $drizzleKitCli = Join-Path $ServerDir 'node_modules\drizzle-kit\bin.cjs'
        Push-Location $ServerDir
        try {
            & $NodeExe $drizzleKitCli 'migrate' 2>&1 | ForEach-Object { Write-Log "  [migrate] $_" }
            if ($LASTEXITCODE -ne 0) { throw "마이그레이션 실패(종료 코드 $LASTEXITCODE)" }
        } finally {
            Pop-Location
        }
        Write-Log '  마이그레이션 완료'

        Write-Log '4/4 서버 재시작 중...'
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
        [System.Windows.Forms.MessageBox]::Show('업데이트가 완료됐습니다.', 'TangoTalk 서버 업데이트', 'OK', 'Information') | Out-Null
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
