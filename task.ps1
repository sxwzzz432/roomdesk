# Windows 下没有 make 时的等价入口
# 用法：pwsh ./task.ps1 up  /  pwsh ./task.ps1 test  /  pwsh ./task.ps1 restore -File backups/x.dump
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'pull', 'build', 'images', 'up', 'down', 'reset', 'ps', 'logs', 'logs-db',
                 'logs-worker', 'migrate', 'test', 'psql', 'psql-app', 'psql-reader', 'pools',
                 'bench', 'backup', 'restore')]
    [string]$Task = 'help',
    [string]$File
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------
# 脚本目录 + 「真正的」bash
#   注意：PowerShell 里 `bash` 可能解析到 C:\Windows\System32\bash.exe（WSL 的启动器），
#   机器上没装发行版时会直接失败：execvpe(/bin/bash) failed。
#   这里显式找 Git Bash，找不到才退回 PATH 上的 bash。
# ---------------------------------------------------------------
$script:RootMu = $PSScriptRoot
$script:GitBash = $null
foreach ($cand in @(
        'C:\Program Files\Git\bin\bash.exe',
        'C:\Program Files (x86)\Git\bin\bash.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe'))) {
    if (Test-Path $cand) { $script:GitBash = $cand; break }
}
if (-not $script:GitBash) {
    $cmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -notmatch '\\System32\\') { $script:GitBash = $cmd.Source }
}
if (-not $script:GitBash) {
    throw '找不到 Git Bash（migrate / backup / restore 需要）。装 Git for Windows，或改用 make（在 Git Bash 里跑）。'
}

function Invoke-Compose {
    param([string[]]$Args)
    docker compose @Args
    if ($LASTEXITCODE -ne 0) { throw "docker compose $($Args -join ' ') 失败（退出码 $LASTEXITCODE）" }
}

switch ($Task) {
    'help' {
        @'
pull        预拉基础镜像（规避 BuildKit 拉元数据超时）
build       只构建镜像（含 test 用的 dev 目标），不启动
images      看本项目镜像体积
up          构建并启动全部服务（含一次性迁移容器）
down        停止服务（保留数据卷）
reset       删除数据卷后重建（数据全丢）
ps          容器状态
logs        全部日志     logs-db 数据库日志     logs-worker worker 日志
migrate     在宿主机上跑迁移（不用 Docker 时）
test        用 dev 目标镜像跑测试（先确保 api healthy）
psql        超级用户 psql        psql-app 应用角色 psql（走 pgbouncer）
psql-reader 只读角色 psql        pools    pgbouncer SHOW POOLS / STATS
bench       执行计划 / 慢查询 / 分区剪枝实验
backup      备份到 ./backups     restore -File backups/xxx.dump
'@
    }
    'pull' {
        foreach ($img in 'python:3.12-slim', 'postgres:16-alpine', 'adminer:4', 'alpine:3.20') {
            Write-Host "=== pulling $img ===" -ForegroundColor Cyan
            docker pull $img
        }
    }
    'build' { Invoke-Compose @('--profile', 'test', 'build') }
    'images' {
        docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}' | Select-String -Pattern 'roomdesk|REPOSITORY'
    }
    'up' {
        Invoke-Compose @('up', '-d', '--build')
        Write-Host ''
        Write-Host '  前端界面   http://localhost:8000/ui/'
        Write-Host '  API 文档   http://localhost:8000/docs'
        Write-Host '  运维面板   http://localhost:8000/api/ops/db'
        Write-Host '  Adminer    http://localhost:8080'
        Write-Host ''
    }
    'down' { Invoke-Compose @('--profile', 'ops', 'down') }
    'reset' {
        Invoke-Compose @('--profile', 'ops', 'down', '-v')
        Invoke-Compose @('up', '-d', '--build')
    }
    'ps' { Invoke-Compose @('--profile', 'ops', 'ps') }
    'logs' { Invoke-Compose @('logs', '-f', '--tail=100') }
    'logs-db' { Invoke-Compose @('logs', '-f', '--tail=100', 'db') }
    'logs-worker' { Invoke-Compose @('logs', '-f', '--tail=100', 'worker') }
    'migrate' { bash scripts/migrate.sh }
    'test' { Invoke-Compose @('--profile', 'test', 'run', '--rm', 'test') }
    'psql' { Invoke-Compose @('exec', 'db', 'sh', '-lc', 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"') }
    'psql-app' {
        Invoke-Compose @('exec', '-e', 'PGPASSWORD=app_pw', 'db',
                         'psql', '-h', 'pgbouncer', '-p', '6432', '-U', 'roomdesk_app', '-d', 'roomdesk')
    }
    'psql-reader' {
        Invoke-Compose @('exec', '-e', 'PGPASSWORD=reader_pw', 'db',
                         'psql', '-U', 'roomdesk_reader', '-d', 'roomdesk')
    }
    'pools' {
        Invoke-Compose @('exec', '-e', 'PGPASSWORD=pgb_admin_pw', 'pgbouncer',
                         'psql', '-h', '127.0.0.1', '-p', '6432', '-U', 'pgb_admin', 'pgbouncer',
                         '-c', 'SHOW POOLS;', '-c', 'SHOW STATS;')
    }
    'bench' {
        Invoke-Compose @('exec', '-T', 'db', 'sh', '-lc',
                         'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /scripts/explain_lab.sql')
    }
    'backup' { & $script:GitBash (Join-Path $script:RootMu 'scripts/backup.sh') }
    'restore' {
        if (-not $File) { throw '缺少 -File 参数，例如：pwsh ./task.ps1 restore -File backups/roomdesk-xxxx.dump' }
        & $script:GitBash (Join-Path $script:RootMu 'scripts/restore.sh') $File
    }
}
