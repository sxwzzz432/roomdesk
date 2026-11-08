#Requires -Version 5.1
<#
================================================================
  RoomDesk · 本机模式一键启动（不使用 Docker）
================================================================
  为什么还需要本机模式：
    Docker 负责"整套多服务编排 + pgbouncer 连接池"，
    但日常改代码时，只跑「API + 本机 PostgreSQL」最快。

  这个脚本按重构后的项目结构做了完整的预检和自动修复：
    1. 找工具       psql / pg_isready / bash(Git Bash) / python
    2. 拉起数据库   没在跑就调 D:\PostgreSQL\start-pg.cmd
    3. 建库         数据库不存在就 createdb
    4. 跑迁移       调 scripts/migrate.sh：bootstrap(扩展/三角色/两 schema)
                    → db/migrations/*.sql → seed，与容器里的 migrator 完全同一套
    5. 装依赖       python 少了 fastapi/psycopg 就 pip install requirements-dev.txt
    6. 刷读模型     报表读物化视图，本地没有 worker 时先刷一次
    7. 起服务       （可选）worker 窗口 + API 前台

  用法：
    双击 run-local.cmd
    或  powershell -ExecutionPolicy Bypass -File run-local.ps1 [-Port 8001] [-NoWorker]

  常用参数：
    -Port 8001        换 API 端口
    -NoWorker         不拉起 worker（LISTEN/NOTIFY 与定时刷新就没有了）
    -NoReload         不用 --reload（启动更稳，适合长时间跑）
    -Migrate          强制重跑迁移（幂等，只 apply 新的）
    -PreflightOnly    只做检查/准备，不启动服务（排查环境用）
    -Reset            删掉本机库重建（危险，会丢本地数据）
================================================================
#>
[CmdletBinding()]
param(
    [string]$DbName = 'roomdesk_local',
    [string]$PgHost = '127.0.0.1',
    [int]$PgPort = 5432,
    [string]$SuperUser = 'postgres',
    [string]$SuperPassword = 'postgres',
    [int]$Port = 8000,
    [switch]$NoReload,
    [switch]$NoWorker,
    [switch]$Migrate,
    [switch]$PreflightOnly,
    [switch]$Reset
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppDir = Join-Path $Root 'app'
$WorkerDir = Join-Path $Root 'worker'

# ---------------------------------------------------------------
# 输出helper
# ---------------------------------------------------------------
function Write-Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "   [OK]  $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "   [WARN] $msg" -ForegroundColor Yellow }
function Fail($msg, $hint) {
    Write-Host "`n   [FAIL] $msg" -ForegroundColor Red
    if ($hint) { Write-Host "          $hint" -ForegroundColor Yellow }
    Write-Host ''
    exit 1
}

# ---------------------------------------------------------------
# 0. .env（与 docker compose 共用一份配置，只取角色口令这类值）
# ---------------------------------------------------------------
function Import-DotEnv([string]$path) {
    $map = @{}
    foreach ($line in (Get-Content -Path $path -Encoding UTF8)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $t.Substring(0, $i).Trim()
        $v = $t.Substring($i + 1).Trim().Trim('"').Trim("'")
        $map[$k] = $v
    }
    return $map
}

$dotEnv = @{}
$envPath = Join-Path $Root '.env'
if (Test-Path $envPath) {
    $dotEnv = Import-DotEnv $envPath
    Write-Host "已读取 $envPath" -ForegroundColor DarkGray
} else {
    Write-Host "没有 .env，使用默认值（可 copy .env.example .env 后修改）" -ForegroundColor DarkGray
}

function Get-Cfg([string]$key, [string]$default) {
    if ($dotEnv.ContainsKey($key) -and $dotEnv[$key] -ne '') { return $dotEnv[$key] }
    return $default
}

$AppUser = Get-Cfg 'APP_USER' 'roomdesk_app'
$AppPass = Get-Cfg 'APP_PASSWORD' 'app_pw'
$ReaderUser = Get-Cfg 'READER_USER' 'roomdesk_reader'
$ReaderPass = Get-Cfg 'READER_PASSWORD' 'reader_pw'
$MigUser = Get-Cfg 'MIGRATOR_USER' 'roomdesk_migrator'
$MigPass = Get-Cfg 'MIGRATOR_PASSWORD' 'migrator_pw'
$AdminToken = Get-Cfg 'ADMIN_TOKEN' 'dev-admin-token'
$RefreshSec = Get-Cfg 'REFRESH_INTERVAL' '15'

# ---------------------------------------------------------------
# 1. 找工具
# ---------------------------------------------------------------
Write-Step "1/7 检查工具链"

function Find-Exe([string]$name, [string[]]$extraPaths) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in $extraPaths) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}

# PostgreSQL 客户端：优先 PATH，其次常见的本机安装目录
$pgCandidates = @()
$pgCandidates += Get-ChildItem -Path 'D:\PostgreSQL' -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'bin' }
$pgCandidates += 'C:\Program Files\PostgreSQL\16\bin', 'C:\Program Files\PostgreSQL\17\bin'

$psql = Find-Exe 'psql' ($pgCandidates | ForEach-Object { Join-Path $_ 'psql.exe' })
if (-not $psql) {
    Fail "找不到 psql" "两条路：① 装 PostgreSQL（本机已装在 D:\PostgreSQL）；② 直接用 Docker：docker compose up -d --build"
}
$pgBin = Split-Path -Parent $psql
$env:Path = "$pgBin;" + $env:Path
$pgIsReady = Join-Path $pgBin 'pg_isready.exe'
$createdb = Join-Path $pgBin 'createdb.exe'
$dropdb = Join-Path $pgBin 'dropdb.exe'
Write-Ok "PostgreSQL 客户端：$pgBin"

# Git Bash：migrate.sh 需要真正的 bash（不能是 WSL 的 System32\bash.exe）
$bashCandidates = @(
    'C:\Program Files\Git\bin\bash.exe',
    'C:\Program Files (x86)\Git\bin\bash.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
)
$bash = $null
foreach ($c in $bashCandidates) { if (Test-Path $c) { $bash = $c; break } }
if (-not $bash) {
    $cmd = Get-Command 'bash' -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -notmatch '\\System32\\') { $bash = $cmd.Source }
}
if (-not $bash) {
    Fail "找不到 Git Bash（migrate.sh 需要）" "装 Git for Windows，或改用 Docker：docker compose up -d --build"
}
Write-Ok "bash：$bash"

# Python
$python = Find-Exe 'python' @()
if (-not $python) { Fail "找不到 python" "装 Python 3.11+ 并勾选 Add to PATH" }
$pyVer = (& $python --version 2>&1) -join ' '
Write-Ok "Python：$pyVer ($python)"

# ---------------------------------------------------------------
# 2. 数据库是否在跑
# ---------------------------------------------------------------
Write-Step "2/7 检查数据库进程"

function Test-PgAlive {
    & $pgIsReady -h $PgHost -p $PgPort -q 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

if (Test-PgAlive) {
    Write-Ok "$PgHost`:$PgPort 可以连接"
} else {
    Write-Warn2 "$PgHost`:$PgPort 连不上，尝试启动本机 PostgreSQL ..."
    $startCmd = 'D:\PostgreSQL\start-pg.cmd'
    if (Test-Path $startCmd) {
        & cmd.exe /c "`"$startCmd`"" | Out-Null
        for ($i = 0; $i -lt 30; $i++) { if (Test-PgAlive) { break }; Start-Sleep -Seconds 1 }
    }
    if (-not (Test-PgAlive)) {
        Fail "数据库没有起来" "手动执行 D:\PostgreSQL\start-pg.cmd，或看 D:\PostgreSQL\log\server.log"
    }
    Write-Ok "数据库已启动"
}

$env:PGPASSWORD = $SuperPassword

# ---------------------------------------------------------------
# 3. 库是否存在
# ---------------------------------------------------------------
Write-Step "3/7 检查数据库 $DbName"

$exists = (& $psql -h $PgHost -p $PgPort -U $SuperUser -d postgres -tAc `
        "SELECT 1 FROM pg_database WHERE datname = '$DbName'") -join ''
$exists = $exists.Trim()

if ($Reset -and $exists -eq '1') {
    Write-Warn2 "-Reset：正在删除数据库 $DbName ..."
    & $dropdb -h $PgHost -p $PgPort -U $SuperUser --if-exists $DbName
    $exists = ''
}

if ($exists -ne '1') {
    Write-Warn2 "数据库不存在，正在创建 ..."
    & $createdb -h $PgHost -p $PgPort -U $SuperUser -E UTF8 $DbName
    if ($LASTEXITCODE -ne 0) { Fail "createdb $DbName 失败" "检查超级用户 $SuperUser 的口令（-SuperPassword）" }
    Write-Ok "已创建 $DbName"
} else {
    Write-Ok "数据库已存在"
}

# ---------------------------------------------------------------
# 4. schema 是否已迁移（没有就跑 migrate.sh，和容器里的 migrator 同一套）
# ---------------------------------------------------------------
Write-Step "4/7 检查表结构与角色"

$hasTable = ((& $psql -h $PgHost -p $PgPort -U $SuperUser -d $DbName -tAc `
            "SELECT to_regclass('roomdesk.bookings') IS NOT NULL") -join '').Trim()
$hasRole = ((& $psql -h $PgHost -p $PgPort -U $SuperUser -d $DbName -tAc `
            "SELECT 1 FROM pg_roles WHERE rolname = '$AppUser'") -join '').Trim()

if ($hasTable -eq 't' -and $hasRole -eq '1' -and -not $Migrate) {
    Write-Ok "已迁移（roomdesk.bookings 存在，$AppUser 存在）"
} else {
    if ($Migrate) { Write-Warn2 "-Migrate：强制运行迁移（幂等）" }
    else { Write-Warn2 "表结构或角色缺失，开始初始化 ..." }

    $env:PGHOST = $PgHost
    $env:PGPORT = "$PgPort"
    $env:DB_NAME = $DbName
    $env:SUPERUSER_USER = $SuperUser
    $env:SUPERUSER_PASSWORD = $SuperPassword
    $env:MIGRATOR_USER = $MigUser
    $env:MIGRATOR_PASSWORD = $MigPass
    $env:APP_USER = $AppUser
    $env:APP_PASSWORD = $AppPass
    $env:READER_USER = $ReaderUser
    $env:READER_PASSWORD = $ReaderPass
    $env:SEED = '1'
    $env:PGPASSWORD = $SuperPassword

    # Git Bash 只认 POSIX 风格的路径，这里把反斜杠换掉
    $migrateScript = (Join-Path $Root 'scripts/migrate.sh') -replace '\\', '/'
    # psql 的 NOTICE 走 stderr，PowerShell 5.1 会把它当成错误记录；
    # 这里临时放宽 EAP、把两路输出逐行转发，并用 PGOPTIONS 压掉 NOTICE 噪音。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $env:PGOPTIONS = '-c client_min_messages=warning'
    & $bash $migrateScript 2>&1 | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
    $migrateRc = $LASTEXITCODE
    Remove-Item Env:\PGOPTIONS -ErrorAction SilentlyContinue
    $ErrorActionPreference = $prevEap

    if ($migrateRc -ne 0) {
        Fail "迁移失败（退出码 $migrateRc）" "常见原因：超级用户口令不对、端口不是 $PgPort、或 bash 不是 Git Bash"
    }
    Write-Ok "迁移完成（bootstrap → migrations → seed）"
}

# ---------------------------------------------------------------
# 5. Python 依赖
# ---------------------------------------------------------------
Write-Step "5/7 检查 Python 依赖"

& $python -c "import fastapi, uvicorn, psycopg, psycopg_pool" 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Ok "fastapi / uvicorn / psycopg 已就绪"
} else {
    Write-Warn2 "依赖不全，正在安装 app/requirements-dev.txt ..."
    & $python -m pip install --quiet -r (Join-Path $AppDir 'requirements-dev.txt')
    if ($LASTEXITCODE -ne 0) { Fail "pip install 失败" "检查网络，或先手动 pip install -r app/requirements-dev.txt" }
    & $python -c "import fastapi, uvicorn, psycopg, psycopg_pool" 2>$null
    if ($LASTEXITCODE -ne 0) { Fail "依赖仍不完整" "手动 pip install -r app/requirements-dev.txt" }
    Write-Ok "依赖安装完成"
}

# ---------------------------------------------------------------
# 6. 本地没有 worker：先手动刷一次读模型，保证报表接口有数据
# ---------------------------------------------------------------
Write-Step "6/7 刷新读模型（物化视图）"

$env:PGPASSWORD = $AppPass
& $psql -h $PgHost -p $PgPort -U $AppUser -d $DbName -q -v ON_ERROR_STOP=1 -c `
    "REFRESH MATERIALIZED VIEW CONCURRENTLY reporting.mv_room_daily_usage" `
    -c "UPDATE reporting.report_state SET refreshed_at = now(), row_count = (SELECT count(*) FROM reporting.mv_room_daily_usage), last_source = 'local-script' WHERE name = 'mv_room_daily_usage'" 2>$null |
    Out-Null
if ($LASTEXITCODE -eq 0) { Write-Ok "reporting.mv_room_daily_usage 已刷新" }
else { Write-Warn2 "刷新失败（可能 worker 正在刷，或物化视图还不存在），跳过" }

$env:PGPASSWORD = $SuperPassword

# ---------------------------------------------------------------
# 7. 启动
# ---------------------------------------------------------------
$dsn = "postgresql://${AppUser}:${AppPass}@${PgHost}:${PgPort}/${DbName}"

Write-Step "7/7 启动服务"
Write-Host ""
Write-Host "  本机模式：API 直连 ${PgHost}:${PgPort}（没有 pgbouncer 这一层）" -ForegroundColor DarkGray
Write-Host "  数据库：  $DbName   角色：$AppUser" -ForegroundColor DarkGray
Write-Host "  前端界面：http://127.0.0.1:$Port/ui/    ← 平时用这个" -ForegroundColor Green
Write-Host "  API 文档：http://127.0.0.1:$Port/docs" -ForegroundColor Green
Write-Host "  健康检查：http://127.0.0.1:$Port/health  （db_user 应为 $AppUser）" -ForegroundColor Green
Write-Host "  运维面板：http://127.0.0.1:$Port/api/ops/db" -ForegroundColor Green
if ($NoWorker) {
    Write-Host "  事件流：  worker 已跳过 → /api/ops/notifications 不会增长" -ForegroundColor DarkGray
} else {
    Write-Host "  事件流：  http://127.0.0.1:$Port/api/ops/notifications （worker 在另一个窗口）" -ForegroundColor Green
}
Write-Host "  停止：    API 窗口 Ctrl+C；worker 窗口直接关掉" -ForegroundColor DarkGray
Write-Host ""

if ($PreflightOnly) {
    Write-Host "-PreflightOnly：检查与准备全部完成，不启动服务。" -ForegroundColor Yellow
    exit 0
}

$env:DATABASE_URL = $dsn
$env:ADMIN_TOKEN = $AdminToken
$env:DB_POOL_MIN = '1'
$env:DB_POOL_MAX = '10'
$env:TZ = 'Asia/Shanghai'

# --- worker（可选）---
if (-not $NoWorker) {
    if (-not (Test-Path (Join-Path $WorkerDir 'consumer.py'))) {
        Write-Warn2 "worker/consumer.py 不存在，跳过 worker"
    } else {
        $env:WORKER_DSN = $dsn
        $env:REFRESH_INTERVAL = $RefreshSec
        $wargs = @('-u', 'consumer.py')
        Start-Process -FilePath $python -ArgumentList $wargs -WorkingDirectory $WorkerDir `
            -WindowStyle Normal | Out-Null
        Write-Ok "worker 已在新窗口启动（LISTEN roomdesk_bookings + 定时刷新读模型）"
        Start-Sleep -Seconds 2
    }
}

# --- API（前台）---
Write-Ok "启动 API ..."
Push-Location $AppDir
$uvArgs = @('-m', 'uvicorn', 'main:app', '--host', '127.0.0.1', '--port', "$Port")
if (-not $NoReload) { $uvArgs += '--reload' }
try {
    & $python @uvArgs
} finally {
    Pop-Location
}
