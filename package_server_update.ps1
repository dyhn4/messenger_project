# 운영 서버를 git 없이 업데이트할 수 있도록, server/ 소스를 실데이터/비밀값 없이 정리해서
# zip 하나로 묶는다(클라이언트를 publish_release.ps1로 설치 파일 하나 만들어 배포하는 것과
# 같은 발상 — "빌드해서 파일 하나로 옮긴다"). build_server_installer.ps1의 스테이징과 같은
# 제외 목록을 쓰지만, 이건 새 PC 전체 설치용이 아니라 "이미 떠 있는 pm2 서버"의 코드만
# 갈아끼우는 용도라 Node.js 런타임/PostgreSQL/NSSM은 담지 않는다(운영 서버에 이미 있다고 가정).
#
# 사용법: 저장소 루트에서 .\package_server_update.ps1
# 결과: server\deploy\output\server-update.zip
#   -> 이 파일 하나만 USB/사내 공유 폴더/클라우드 등 원하는 방법으로 운영 서버 PC에 옮긴 뒤,
#      그 PC에서 update_server.ps1을 실행하면 적용됩니다(README "운영 중인 서버 업데이트" 참고).

$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
$Server = Join-Path $Root 'server'
$DeployDir = Join-Path $Server 'deploy'
$Stage = Join-Path $DeployDir 'stage'
$OutDir = Join-Path $DeployDir 'output'

Remove-Item $Stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Stage | Out-Null
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host '1) server/ 소스 정리 중(실데이터/비밀값 제외)...' -ForegroundColor Cyan
# robocopy가 제외 목록 처리가 더 안정적이라 Copy-Item 대신 쓴다(exit code 1/2/3은 성공으로
# 취급 — robocopy는 실패가 아니어도 0이 아닌 코드를 돌려준다). build_server_installer.ps1의
# 스테이징 제외 목록과 맞춘다(ecosystem.config.cjs는 비밀값이 아니라 여기서는 포함시킨다 —
# pm2 운영 서버는 이 파일이 실제로 필요하다).
$robocopyArgs = @(
    $Server, $Stage, '/E',
    '/XD', 'node_modules', 'certs', 'uploads', 'mailstore', 'releases', 'installer', 'deploy', 'backups',
    '/XF', '.env', '*.log', '.jwt-secret', '.db-encryption-key', '.web-push-vapid.json', 'firebase-service-account.json', 'db.json.bak',
    '/NFL', '/NDL', '/NJH', '/NJS'
)
robocopy @robocopyArgs | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy 실패(코드 $LASTEXITCODE)" }
# 앱의 "도움말"이 여는 초보자용 안내 웹페이지(server/guide/)도 같이 담겨야 한다 — 위 제외
# 목록을 고치다 실수로 빠지는 일이 없게 확인한다.
if (-not (Test-Path (Join-Path $Stage 'guide\index.html'))) { throw 'server/guide/index.html이 스테이징에 없습니다(초보자용 도움말).' }

# git 없이도 어느 시점 코드인지 나중에 확인할 수 있도록 기록해둔다(update_server.ps1이
# 적용 후 이 값을 출력해줌).
$commit = git rev-parse --short HEAD 2>$null
if (-not $commit) { $commit = '(git 정보 없음)' }
$builtAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
@{ builtAt = $builtAt; commit = $commit } | ConvertTo-Json |
    Set-Content -Path (Join-Path $Stage 'update-info.json') -Encoding utf8

Write-Host '2) 압축하는 중...' -ForegroundColor Cyan
$zipPath = Join-Path $OutDir 'server-update.zip'
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $zipPath

Write-Host ''
Write-Host "완료: $zipPath" -ForegroundColor Green
Write-Host '이 파일 하나만 운영 서버 PC로 옮긴 뒤, 그 PC에서 update_server.ps1을 실행하세요.' -ForegroundColor DarkGray
