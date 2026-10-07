<#
.SYNOPSIS
  "외부 접속 주소" 시작 메뉴 항목 — 사내망 밖(LTE/5G)에서 접속할 주소(DDNS 도메인 또는
  고정 공인 IP)를 보여주고 바꾸거나 끌 수 있게 해준다.

.DESCRIPTION
  server/src/config.js의 EXTERNAL_ADDRESS를 .env에 쓰고 서비스를 재시작해주는 GUI일 뿐이다
  (Storage-Path.ps1과 같은 방식). 서버는 뜰 때 이 주소가 TLS 인증서에 없으면 인증서를 새로
  만든다(certs.js) — 그러면 이미 연결해둔 모든 클라이언트가 페어링 코드로 다시 연결해야
  하므로, 적용 전에 지금 인증서를 읽어서 그런 경우인지 미리 알려준다. 공유기 포트포워딩은
  이 스크립트가 해줄 수 없어서 안내만 한다. 화상회의 공인 IP 설정(livekit.yaml)과 LiveKit 재시작은
  서버가 뜰 때 알아서 한다(server/src/livekitNat.js). 서비스 재시작에 관리자 권한이 필요해서, 관리자가
  아니면 스스로 관리자 권한으로 다시 실행한다.
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
$CertFile = Join-Path $ServerDir 'certs\cert.pem'
$NssmExe = Join-Path $AppDir 'tools\nssm.exe'
$NodeServiceName = 'TangoTalkServer'
$Title = 'TangoTalk 외부 접속 주소'

function Get-EnvValue {
    param([string]$Name)
    if (Test-Path $EnvFile) {
        $line = Get-Content $EnvFile | Where-Object { $_ -match "^\s*$Name\s*=" } | Select-Object -Last 1
        if ($line -and $line -match "^\s*$Name\s*=\s*(.*)$") { return $Matches[1].Trim() }
    }
    return ''
}

function Set-ExternalAddressInEnv {
    param([string]$Value)
    $lines = if (Test-Path $EnvFile) { Get-Content $EnvFile } else { @() }
    $found = $false
    $newLines = foreach ($line in $lines) {
        if ($line -match '^\s*EXTERNAL_ADDRESS\s*=') {
            $found = $true
            "EXTERNAL_ADDRESS=$Value"
        } else {
            $line
        }
    }
    if (-not $found) {
        $newLines = $newLines + @('', '# External-Address.ps1이 지정한 외부(LTE/5G) 접속 주소(비우면 사내망 전용)', "EXTERNAL_ADDRESS=$Value")
    }
    # BOM 없는 UTF-8로 쓴다 — PowerShell 5.1의 Set-Content -Encoding utf8은 BOM을 붙이는데, 첫 줄이
    # 설정이면 dotenv가 그 키 이름을 BOM째로 읽어 값을 못 찾는다.
    [System.IO.File]::WriteAllLines($EnvFile, [string[]]$newLines, (New-Object System.Text.UTF8Encoding($false)))
}

$ServerPort = Get-EnvValue 'PORT'
if (-not $ServerPort) { $ServerPort = '3000' }
$PairingPort = Get-EnvValue 'PAIRING_PORT'
if (-not $PairingPort) { $PairingPort = [string]([int]$ServerPort + 1) }

# 화상회의 미디어 포트(안내용) — 서버가 외부 주소에 맞춰 livekit.yaml의 공인 IP 설정을 고치고
# LiveKit 서비스를 재시작하지만(server/src/livekitNat.js), 공유기 포워딩은 직접 해야 한다.
$LiveKitConfig = Join-Path $AppDir 'livekit\livekit.yaml'
$MediaUdp = '50000-60000'
$MediaTcp = '7881'
if (Test-Path $LiveKitConfig) {
    $lk = Get-Content $LiveKitConfig -Raw
    if ($lk -match '(?m)^\s+port_range_start:\s*(\d+)' ) { $udpStart = $Matches[1] } else { $udpStart = '50000' }
    if ($lk -match '(?m)^\s+port_range_end:\s*(\d+)' ) { $udpEnd = $Matches[1] } else { $udpEnd = '60000' }
    $MediaUdp = "$udpStart-$udpEnd"
    if ($lk -match '(?m)^\s+tcp_port:\s*(\d+)') { $MediaTcp = $Matches[1] }
}

# server/src/externalAddress.js의 parseExternalAddress와 같은 규칙 — 서버가 못 읽는 값을
# .env에 써두면 서버는 외부 접속만 끈 채로 뜨므로(config.js) 여기서 미리 막는다.
function ConvertTo-ExternalAddress {
    param([string]$Raw)
    $value = $Raw.Trim() -replace '^(?i)https?://', '' -replace '[/?#].*$', ''
    $hostPart = $value
    $port = [int]$ServerPort
    if ($value -match '^(.+):(\d{1,5})$') {
        $hostPart = $Matches[1]
        $port = [int]$Matches[2]
    }
    $hostPart = $hostPart.ToLower()
    if ($port -lt 1 -or $port -gt 65535) { throw "포트가 올바르지 않습니다: $port" }
    $isIPv4 = $hostPart -match '^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$'
    $isDomain = $hostPart.Length -le 253 -and $hostPart -match '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$'
    if (-not $isIPv4 -and -not $isDomain) { throw "도메인(예: xxx.iptime.org) 또는 IPv4 주소만 넣을 수 있습니다: $Raw" }
    return [pscustomobject]@{ Host = $hostPart; Port = $port; IsIP = $isIPv4 }
}

# 지금 인증서가 이 주소를 이미 담고 있는지(그러면 적용해도 인증서가 안 바뀐다). 읽지 못하면 $null.
function Test-CertCoversHost {
    param([string]$HostName, [bool]$IsIP)
    try {
        if (-not (Test-Path $CertFile)) { return $false }
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $CertFile
        $san = $cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
        if (-not $san) { return $false }
        $entries = $san.Format($false) -split ',\s*'
        $wanted = if ($IsIP) { "IP Address=$HostName" } else { "DNS Name=$HostName" }
        return [bool]($entries | Where-Object { $_.Trim() -ieq $wanted })
    } catch {
        return $null
    }
}

# ── 창 구성 ──────────────────────────────────────────────────────────────
$form = New-Object System.Windows.Forms.Form
$form.Text = $Title
$form.ClientSize = New-Object System.Drawing.Size(500, 320)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

$label1 = New-Object System.Windows.Forms.Label
$label1.Text = '사내 와이파이 밖(LTE/5G)에서 접속할 주소입니다. 공유기의 DDNS 도메인(예: xxx.iptime.org)이나 고정 공인 IP를 넣으세요. 공유기 포트가 서버 포트와 다르면 "주소:포트"로 적습니다. 비워두면 사내망에서만 접속됩니다.'
$label1.Location = New-Object System.Drawing.Point(15, 15)
$label1.Size = New-Object System.Drawing.Size(470, 58)
$form.Controls.Add($label1)

$addressBox = New-Object System.Windows.Forms.TextBox
$addressBox.Location = New-Object System.Drawing.Point(15, 78)
$addressBox.Size = New-Object System.Drawing.Size(470, 24)
$addressBox.Text = Get-EnvValue 'EXTERNAL_ADDRESS'
$form.Controls.Add($addressBox)

$hintLabel = New-Object System.Windows.Forms.Label
$hintLabel.Text = "공유기에서 이 PC로 포워딩할 포트: TCP $ServerPort(메신저·재페어링·화상회의 접속), " +
    "화상회의 영상·음성용 UDP $($MediaUdp)와 TCP $MediaTcp(같은 번호로).`n" +
    "초대 링크 안내 페이지도 밖에서 열려면 TCP $($PairingPort)도(밖에서는 안내 페이지·설치 파일만 열리고 페어링은 막힘)."
$hintLabel.ForeColor = [System.Drawing.Color]::Gray
$hintLabel.Location = New-Object System.Drawing.Point(15, 108)
$hintLabel.Size = New-Object System.Drawing.Size(470, 64)
$form.Controls.Add($hintLabel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = ''
$statusLabel.Location = New-Object System.Drawing.Point(15, 176)
$statusLabel.Size = New-Object System.Drawing.Size(470, 90)
$form.Controls.Add($statusLabel)

$applyButton = New-Object System.Windows.Forms.Button
$applyButton.Text = '적용'
$applyButton.Location = New-Object System.Drawing.Point(300, 280)
$applyButton.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($applyButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = '닫기'
$closeButton.Location = New-Object System.Drawing.Point(395, 280)
$closeButton.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($closeButton)
$closeButton.Add_Click({ $form.Close() })

$applyButton.Add_Click({
    $raw = $addressBox.Text.Trim()
    $oldValue = Get-EnvValue 'EXTERNAL_ADDRESS'
    $parsed = $null
    if ($raw) {
        try {
            $parsed = ConvertTo-ExternalAddress -Raw $raw
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '오류', 'OK', 'Error') | Out-Null
            return
        }
        $raw = if ($parsed.Port -eq [int]$ServerPort) { $parsed.Host } else { "$($parsed.Host):$($parsed.Port)" }
    }
    if ($raw -eq $oldValue) {
        [System.Windows.Forms.MessageBox]::Show('이미 이 값으로 설정돼 있습니다.', $Title, 'OK', 'Information') | Out-Null
        return
    }

    if ($parsed) {
        $covered = Test-CertCoversHost -HostName $parsed.Host -IsIP $parsed.IsIP
        if ($covered -ne $true) {
            $result = [System.Windows.Forms.MessageBox]::Show(
                "서버 인증서에 이 주소가 없어서, 서버가 재시작할 때 인증서를 새로 만듭니다.`n`n" +
                "그러면 이미 연결해둔 모든 클라이언트(PC·모바일)가 로그인 화면의 '서버 주소 변경'에서 " +
                "페어링 코드('새 기기 페어링 코드 발급')로 다시 연결해야 접속됩니다(사내 와이파이 밖에서는 외부 주소로 재페어링).`n`n계속할까요?",
                $Title, 'YesNo', 'Warning'
            )
            if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
                $statusLabel.ForeColor = [System.Drawing.Color]::Black
                $statusLabel.Text = '취소했습니다. 아무 것도 바꾸지 않았습니다.'
                return
            }
        }
    }

    $applyButton.Enabled = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Set-ExternalAddressInEnv -Value $raw
        $addressBox.Text = $raw

        if (Test-Path $NssmExe) {
            $statusLabel.ForeColor = [System.Drawing.Color]::Black
            $statusLabel.Text = '서버 재시작 중...'
            [System.Windows.Forms.Application]::DoEvents()
            & $NssmExe restart $NodeServiceName | Out-Null
        }

        $statusLabel.ForeColor = [System.Drawing.Color]::Green
        if ($parsed) {
            $statusLabel.Text = "적용됐습니다. 외부 접속 주소: https://$($parsed.Host):$($parsed.Port)`n" +
                '앱은 사내 와이파이에서 한 번 접속하면 이 주소를 받아 저장하고, 밖에서는 자동으로 이 주소로 전환합니다.'
        } else {
            $statusLabel.Text = '외부 접속을 껐습니다. 이제 사내망에서만 접속됩니다(공유기 포트포워딩도 지우세요).'
        }
    } catch {
        $statusLabel.ForeColor = [System.Drawing.Color]::Red
        $statusLabel.Text = "오류: $($_.Exception.Message)"
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $applyButton.Enabled = $true
    }
})

[System.Windows.Forms.Application]::Run($form)
