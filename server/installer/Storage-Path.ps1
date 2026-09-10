<#
.SYNOPSIS
  "첨부파일 저장소" 시작 메뉴 항목 — 채팅 첨부파일이 저장되는 폴더를 보여주고, NAS나 다른
  PC의 공유 폴더 등으로 바꿀 수 있게 해준다.

.DESCRIPTION
  server/src/config.js의 UPLOADS_DIR은 원래부터 환경변수로 바꿀 수 있게 되어 있었다(안
  주면 기본값 {app}\server\uploads) — 이 스크립트는 그 값을 .env에 직접 쓰고 서비스를
  재시작해주는 GUI일 뿐, 새 메커니즘을 만드는 게 아니다. 경로를 바꾸면 기존 파일을 새
  위치로 옮길지 물어본다(안 옮기면 예전 첨부파일 링크가 깨질 수 있음). 서비스 재시작에
  관리자 권한이 필요해서, 관리자가 아니면 스스로 관리자 권한으로 다시 실행한다.
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
$DefaultUploadsDir = Join-Path $ServerDir 'uploads'
$NssmExe = Join-Path $AppDir 'tools\nssm.exe'
$NodeServiceName = 'TangoTalkServer'

function Get-CurrentUploadsDir {
    if (Test-Path $EnvFile) {
        $line = Get-Content $EnvFile | Where-Object { $_ -match '^\s*UPLOADS_DIR\s*=' } | Select-Object -Last 1
        if ($line -and $line -match '^\s*UPLOADS_DIR\s*=\s*(.*)$') {
            $value = $Matches[1].Trim()
            if ($value) { return $value }
        }
    }
    return $DefaultUploadsDir
}

function Set-UploadsDirInEnv {
    param([string]$NewPath)
    $lines = if (Test-Path $EnvFile) { Get-Content $EnvFile } else { @() }
    $found = $false
    $newLines = foreach ($line in $lines) {
        if ($line -match '^\s*UPLOADS_DIR\s*=') {
            $found = $true
            "UPLOADS_DIR=$NewPath"
        } else {
            $line
        }
    }
    if (-not $found) {
        $newLines = $newLines + @('', "# Storage-Path.ps1이 지정한 첨부파일 저장 위치(비우면 기본값 server\uploads 사용)", "UPLOADS_DIR=$NewPath")
    }
    Set-Content -Path $EnvFile -Value $newLines -Encoding utf8
}

# ── 창 구성 ──────────────────────────────────────────────────────────────
$form = New-Object System.Windows.Forms.Form
$form.Text = 'TangoTalk 첨부파일 저장소'
$form.ClientSize = New-Object System.Drawing.Size(480, 200)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

$label1 = New-Object System.Windows.Forms.Label
$label1.Text = '채팅 첨부파일(이미지 등)이 저장되는 위치입니다. NAS나 다른 PC의 공유 폴더(\\서버\공유)로도 지정할 수 있습니다.'
$label1.Location = New-Object System.Drawing.Point(15, 15)
$label1.Size = New-Object System.Drawing.Size(450, 40)
$form.Controls.Add($label1)

$pathBox = New-Object System.Windows.Forms.TextBox
$pathBox.Location = New-Object System.Drawing.Point(15, 58)
$pathBox.Size = New-Object System.Drawing.Size(340, 24)
$pathBox.Text = Get-CurrentUploadsDir
$form.Controls.Add($pathBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = '찾아보기...'
$browseButton.Location = New-Object System.Drawing.Point(365, 57)
$browseButton.Size = New-Object System.Drawing.Size(100, 26)
$form.Controls.Add($browseButton)

$hintLabel = New-Object System.Windows.Forms.Label
$hintLabel.Text = '(NAS/네트워크 경로는 위 칸에 \\서버\공유\폴더 형식으로 직접 입력하세요.)'
$hintLabel.ForeColor = [System.Drawing.Color]::Gray
$hintLabel.Location = New-Object System.Drawing.Point(15, 86)
$hintLabel.Size = New-Object System.Drawing.Size(450, 20)
$form.Controls.Add($hintLabel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = ''
$statusLabel.Location = New-Object System.Drawing.Point(15, 112)
$statusLabel.Size = New-Object System.Drawing.Size(450, 44)
$form.Controls.Add($statusLabel)

$applyButton = New-Object System.Windows.Forms.Button
$applyButton.Text = '적용'
$applyButton.Location = New-Object System.Drawing.Point(280, 160)
$applyButton.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($applyButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = '닫기'
$closeButton.Location = New-Object System.Drawing.Point(375, 160)
$closeButton.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($closeButton)
$closeButton.Add_Click({ $form.Close() })

$browseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = '첨부파일을 저장할 폴더를 선택하세요'
    $current = $pathBox.Text.Trim()
    if ($current -and (Test-Path $current)) { $dialog.SelectedPath = $current }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $pathBox.Text = $dialog.SelectedPath
    }
})

$applyButton.Add_Click({
    $newPath = $pathBox.Text.Trim()
    if (-not $newPath) {
        [System.Windows.Forms.MessageBox]::Show('경로를 입력하세요.', '오류', 'OK', 'Error') | Out-Null
        return
    }
    $oldPath = Get-CurrentUploadsDir
    if ($newPath -eq $oldPath) {
        [System.Windows.Forms.MessageBox]::Show('이미 이 경로를 쓰고 있습니다.', 'TangoTalk 첨부파일 저장소', 'OK', 'Information') | Out-Null
        return
    }

    $applyButton.Enabled = $false
    $browseButton.Enabled = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $statusLabel.ForeColor = [System.Drawing.Color]::Black
    $statusLabel.Text = '확인 중...'
    [System.Windows.Forms.Application]::DoEvents()

    try {
        # 새 경로가 없으면 만들어본다(NAS 등 네트워크 경로는 상위 공유 폴더 자체가 이미
        # 있어야 하고, 여기서는 그 안에 하위 폴더 하나를 만드는 정도만 시도한다).
        if (-not (Test-Path $newPath)) {
            New-Item -ItemType Directory -Path $newPath -Force -ErrorAction Stop | Out-Null
        }
        # 실제로 쓸 수 있는지 파일 하나 써서 확인.
        $testFile = Join-Path $newPath ".tangotalk-write-test-$(Get-Random)"
        Set-Content -Path $testFile -Value 'test' -ErrorAction Stop
        Remove-Item $testFile -Force -ErrorAction SilentlyContinue

        $moveFiles = $false
        if ((Test-Path $oldPath) -and (Get-ChildItem $oldPath -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            $result = [System.Windows.Forms.MessageBox]::Show(
                "기존 저장 위치($oldPath)에 첨부파일이 있습니다.`n새 위치로 옮길까요?`n`n" +
                "옮기지 않으면 예전에 보낸 첨부파일을 못 열게 될 수 있습니다.",
                'TangoTalk 첨부파일 저장소', 'YesNoCancel', 'Warning'
            )
            if ($result -eq [System.Windows.Forms.DialogResult]::Cancel) {
                $statusLabel.Text = '취소했습니다. 아무 것도 바꾸지 않았습니다.'
                return
            }
            $moveFiles = ($result -eq [System.Windows.Forms.DialogResult]::Yes)
        }

        if ($moveFiles) {
            $statusLabel.Text = '기존 파일 옮기는 중...'
            [System.Windows.Forms.Application]::DoEvents()
            $robocopyArgs = @($oldPath, $newPath, '/E', '/MOVE', '/NFL', '/NDL', '/NJH', '/NJS')
            robocopy @robocopyArgs | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "파일 이동 실패(robocopy 코드 $LASTEXITCODE) — 저장 위치는 바꾸지 않았습니다." }
        }

        Set-UploadsDirInEnv -NewPath $newPath

        if (Test-Path $NssmExe) {
            $statusLabel.Text = '서버 재시작 중...'
            [System.Windows.Forms.Application]::DoEvents()
            & $NssmExe restart $NodeServiceName | Out-Null
        }

        $statusLabel.ForeColor = [System.Drawing.Color]::Green
        $statusLabel.Text = "적용됐습니다. 새 저장 위치: $newPath"
        [System.Windows.Forms.MessageBox]::Show('첨부파일 저장 위치가 변경됐습니다.', 'TangoTalk 첨부파일 저장소', 'OK', 'Information') | Out-Null
    } catch {
        $statusLabel.ForeColor = [System.Drawing.Color]::Red
        $statusLabel.Text = "오류: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "저장 위치를 바꾸지 못했습니다:`n`n$($_.Exception.Message)",
            'TangoTalk 첨부파일 저장소', 'OK', 'Error'
        ) | Out-Null
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $applyButton.Enabled = $true
        $browseButton.Enabled = $true
    }
})

[System.Windows.Forms.Application]::Run($form)
