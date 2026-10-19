# 아이폰 앱 배포 서명 준비 — 맥 없이 Windows에서 Apple 배포 인증서(.p12)를 만들고, GitHub Secrets에 넣을 base64 글을 만든다.
# 순서(README "아이폰 앱" — Apple 개발자 등록 뒤):
#   1) .\client\tool\ios_signing.ps1 csr -Email 나@회사.com
#        → 개인 키(ios_dist.key)와 인증서 요청(ios_dist.csr)을 만든다. developer.apple.com → Certificates → [+] →
#          "Apple Distribution"에 ios_dist.csr을 올리고, 받은 distribution.cer을 같은 폴더에 둔다.
#   2) developer.apple.com에서 App Store 프로비저닝 프로파일 두 개(앱·화면 공유 확장)를 만들어 받아 같은 폴더에 둔다.
#   3) .\client\tool\ios_signing.ps1 p12
#        → .p12 암호를 묻고 ios_dist.p12를 만든 뒤, Secrets에 넣을 글을 *.base64.txt로 쓴다(.p12와 폴더의 *.mobileprovision 전부).
# 개인 키·.p12는 저장소 밖(기본 %USERPROFILE%\ios-signing)에 두고 잃어버리지 않게 따로 보관한다 — 잃으면 인증서를 새로 만들어야 한다.
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet("csr", "p12")]
  [string]$Step,
  [string]$Email = "",
  [string]$Dir = (Join-Path $env:USERPROFILE "ios-signing")
)

$ErrorActionPreference = "Stop"

# Git for Windows에 openssl이 들어 있다 — PATH에 없으면 거기서 찾는다.
$openssl = (Get-Command openssl -ErrorAction SilentlyContinue).Source
if (-not $openssl) {
  $candidate = Join-Path $env:ProgramFiles "Git\usr\bin\openssl.exe"
  if (Test-Path $candidate) { $openssl = $candidate }
}
if (-not $openssl) { throw "openssl을 찾지 못했습니다. Git for Windows를 설치하거나 openssl을 PATH에 넣으세요." }

New-Item -ItemType Directory -Force $Dir | Out-Null
$key = Join-Path $Dir "ios_dist.key"
$csr = Join-Path $Dir "ios_dist.csr"
$cer = Join-Path $Dir "distribution.cer"
$pem = Join-Path $Dir "distribution.pem"
$p12 = Join-Path $Dir "ios_dist.p12"

function Write-Base64([string]$path) {
  $out = "$path.base64.txt"
  [IO.File]::WriteAllText($out, [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)))
  Write-Host "  $out"
}

if ($Step -eq "csr") {
  if (-not $Email) { throw "-Email에 Apple 개발자 계정 이메일을 넣으세요." }
  if (Test-Path $key) { throw "$key 가 이미 있습니다 — 새로 만들려면 그 파일을 먼저 옮기세요(이미 만든 인증서의 개인 키일 수 있다)." }
  & $openssl req -new -newkey rsa:2048 -nodes -keyout $key -out $csr -subj "/emailAddress=$Email/CN=TangoTalk Distribution/C=KR"
  if ($LASTEXITCODE -ne 0) { throw "인증서 요청을 만들지 못했습니다." }
  Write-Host ""
  Write-Host "만들었습니다: $csr"
  Write-Host "developer.apple.com > Certificates > [+] > Apple Distribution에 이 파일을 올리고, 받은 distribution.cer을 $Dir 에 두세요."
  Write-Host "그다음 프로비저닝 프로파일 두 개를 받아 같은 폴더에 두고 '.\client\tool\ios_signing.ps1 p12'를 실행합니다."
  exit 0
}

# p12 — 받은 인증서(DER)와 개인 키를 하나로 묶는다. 맥의 키체인(security import)이 읽는 예전 암호화 방식(3DES·SHA1)으로 만든다 —
# OpenSSL 3의 기본(AES·PBKDF2)으로 만들면 GitHub 맥 러너에서 "MAC verification failed"로 못 읽는다.
if (-not (Test-Path $key)) { throw "$key 가 없습니다 — 먼저 'csr' 단계를 실행하세요." }
if (-not (Test-Path $cer)) { throw "$cer 가 없습니다 — Apple에서 받은 배포 인증서를 이 이름으로 두세요." }
$secure = Read-Host ".p12 암호(GitHub Secrets의 IOS_DIST_CERT_PASSWORD에 같은 값을 넣습니다)" -AsSecureString
$env:TT_P12_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
try {
  & $openssl x509 -inform DER -in $cer -out $pem
  if ($LASTEXITCODE -ne 0) { throw "distribution.cer을 읽지 못했습니다." }
  & $openssl pkcs12 -export -inkey $key -in $pem -out $p12 -name "TangoTalk Distribution" `
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -passout env:TT_P12_PASSWORD
  if ($LASTEXITCODE -ne 0) { throw ".p12를 만들지 못했습니다." }
} finally {
  Remove-Item Env:TT_P12_PASSWORD -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "만들었습니다: $p12"
Write-Host "GitHub 저장소 > Settings > Secrets and variables > Actions에 넣을 글:"
Write-Base64 $p12
Write-Host "    → IOS_DIST_CERT_P12"
$profiles = Get-ChildItem $Dir -Filter *.mobileprovision
if ($profiles.Count -eq 0) {
  Write-Host "프로비저닝 프로파일(*.mobileprovision)이 아직 없습니다 — 받아 두고 이 단계를 다시 실행하면 그것도 만들어 줍니다."
}
foreach ($profile in $profiles) {
  Write-Base64 $profile.FullName
}
if ($profiles.Count -gt 0) {
  Write-Host "    → 앱(com.teamtalk.messenger) 프로파일은 IOS_PROFILE_APP, 화면 공유(…BroadcastExtension) 프로파일은 IOS_PROFILE_BROADCAST"
}
Write-Host "base64 글 파일은 Secrets에 넣은 뒤 지워도 됩니다(원본 .p12·키는 따로 보관)."
