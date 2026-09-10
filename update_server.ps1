# 운영 서버에서 실행 — git 없이, package_server_update.ps1이 만든 zip으로 서버 코드만
# 최신으로 올린다. DB 데이터는 전혀 건드리지 않는다.
#
# 사용법: 이 zip 파일을 이 스크립트와 같은 폴더에 "server-update.zip"이라는 이름으로 두고
#   .\update_server.ps1
# 또는 다른 경로/이름을 쓰려면
#   .\update_server.ps1 -ZipPath "C:\받은위치\server-update.zip"
#
# 하는 일: zip 풀기(코드) -> npm install(패키지) -> drizzle-kit migrate(스키마, 추가만 함)
# -> pm2 restart 순서로 진행하고, 어느 단계든 실패하면 즉시 멈춘다.
#
# DB 데이터가 안전한 이유: zip 안에는 애초에 .env/certs/uploads/releases/node_modules —
# 즉 이 서버 고유의 실데이터·비밀값이 전혀 들어있지 않다(package_server_update.ps1이 만들 때
# 제외함). db:migrate는 아직 적용 안 된 새 마이그레이션 파일만 골라 실행하고(이미 적용된 건
# 건너뜀), 지금까지 이 저장소의 모든 마이그레이션은 CREATE TABLE / ALTER TABLE ADD COLUMN류의
# "추가"만 해왔다(기존 행을 지우거나 바꾸는 마이그레이션은 없음). pm2 재시작은 Node.js
# 프로세스만 내렸다 올리는 것이라 Postgres 프로세스/데이터에는 아예 손대지 않는다.
#
# 처음 서버를 띄우는 것이라면(pm2에 messenger-server가 아직 없다면) 이 스크립트 대신
# README의 "pm2로 서버 운영하기"에 나온 npm run pm2:start를 먼저 한 번 실행하세요.

param(
    [string]$ZipPath = "$PSScriptRoot\server-update.zip"
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$Server = Join-Path $repoRoot 'server'

if (-not (Test-Path $ZipPath)) {
    throw "업데이트 zip을 찾을 수 없습니다: $ZipPath (package_server_update.ps1로 만든 server-update.zip을 이 경로에 두거나 -ZipPath로 위치를 알려주세요.)"
}

Write-Host "1/4 업데이트 코드 적용 중..." -ForegroundColor Cyan
$tmp = Join-Path $env:TEMP "server-update-$(Get-Date -Format 'yyyyMMddHHmmss')"
Expand-Archive -Path $ZipPath -DestinationPath $tmp

# zip 안에는 .env/certs/uploads/releases/node_modules 같은 이 서버 고유의 실데이터·비밀값이
# 애초에 없으므로(package_server_update.ps1이 제외해서 만듦), 그대로 덮어써도 안전하다.
# 혹시 이 서버 쪽에 그런 폴더가 남아있어도 robocopy 대상에서 제외해 절대 건드리지 않는다.
$robocopyArgs = @(
    $tmp, $Server, '/E',
    '/XD', 'node_modules', 'certs', 'uploads', 'releases', 'installer', 'deploy',
    '/NFL', '/NDL', '/NJH', '/NJS'
)
robocopy @robocopyArgs | Out-Null
if ($LASTEXITCODE -ge 8) { throw "코드 적용 실패(robocopy 코드 $LASTEXITCODE)" }
Remove-Item $tmp -Recurse -Force

Set-Location $Server

Write-Host "2/4 패키지 설치 중 (npm install)..." -ForegroundColor Cyan
npm install
if ($LASTEXITCODE -ne 0) { throw "npm install 실패" }

Write-Host "3/4 DB 마이그레이션 적용 중 — 기존 데이터는 그대로 두고 새로 추가된 구조만 반영합니다..." -ForegroundColor Cyan
npm run db:migrate
if ($LASTEXITCODE -ne 0) { throw "db:migrate 실패" }

Write-Host "4/4 서버 재시작 중 (pm2)..." -ForegroundColor Cyan
npm run pm2:restart
if ($LASTEXITCODE -ne 0) { throw "pm2 재시작 실패" }

$infoPath = Join-Path $Server 'update-info.json'
if (Test-Path $infoPath) {
    $info = Get-Content $infoPath -Raw | ConvertFrom-Json
    Write-Host "적용된 버전: 커밋 $($info.commit) ($($info.builtAt) 빌드)" -ForegroundColor DarkGray
}

Write-Host "완료 — 서버가 새 코드로 재시작됐습니다. DB 데이터는 전혀 건드리지 않았습니다." -ForegroundColor Green
Write-Host "로그 확인: npm run pm2:logs (server 폴더에서)" -ForegroundColor DarkGray
