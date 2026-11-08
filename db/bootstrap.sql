-- ============================================================
--  db/bootstrap.sql —— 以【超级用户】执行（migrator 容器第一步）
--
--  只做「集群级」的事：扩展、登录角色、schema、schema 级权限。
--  表 / 视图 / 函数等对象全部交给 db/migrations/*.sql，由 roomdesk_migrator 执行。
--
--  全部幂等，每次容器启动都可以重跑。
--  变量由 scripts/migrate.sh 通过 psql -v 传入。
-- ============================================================
\set ON_ERROR_STOP on

-- ------------------------------------------------------------
-- 1. 扩展
--    btree_gist  : 让 GiST 支持 bigint 的等值比较（EXCLUDE 约束必需）
--    pg_trgm     : ILIKE '%关键词%' 能走索引
--    pg_stat_statements : 按 SQL 指纹统计耗时，/api/ops/db 会读它
-- ------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- ------------------------------------------------------------
-- 2. 角色（\gexec：把 SELECT 的结果当 SQL 执行，天然幂等）
--    roomdesk_migrator : 拥有 schema，能 DDL，不给应用用
--    roomdesk_app      : 应用的唯一身份，只有 DML + 函数执行权，不能建表
--    roomdesk_reader   : 只读，给报表/排查用
-- ------------------------------------------------------------
SELECT format('CREATE ROLE %I LOGIN', :'migrator_user')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'migrator_user') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'migrator_user', :'migrator_password') \gexec

SELECT format('CREATE ROLE %I LOGIN', :'app_user')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password') \gexec

SELECT format('CREATE ROLE %I LOGIN', :'reader_user')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'reader_user') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'reader_user', :'reader_password') \gexec

-- ------------------------------------------------------------
-- 3. schema
--    roomdesk  : 业务表（owner = migrator）
--    reporting : 读模型（物化视图）；给 app CREATE 权限，
--                这样物化视图可以归 app 所有，app/worker 才能 REFRESH CONCURRENTLY
--                （REFRESH 权限只跟着 owner 走，没有对应的 GRANT）
-- ------------------------------------------------------------
SELECT format('CREATE SCHEMA IF NOT EXISTS roomdesk AUTHORIZATION %I', :'migrator_user') \gexec
SELECT format('CREATE SCHEMA IF NOT EXISTS reporting AUTHORIZATION %I', :'migrator_user') \gexec

-- ------------------------------------------------------------
-- 4. schema 级权限
-- ------------------------------------------------------------
SELECT format('GRANT USAGE ON SCHEMA roomdesk TO %I', :'app_user') \gexec
SELECT format('GRANT USAGE ON SCHEMA reporting TO %I', :'app_user') \gexec
SELECT format('GRANT USAGE ON SCHEMA roomdesk TO %I', :'reader_user') \gexec
SELECT format('GRANT USAGE ON SCHEMA reporting TO %I', :'reader_user') \gexec
-- 只给 reporting 的 CREATE，业务 schema 一律不给
SELECT format('GRANT CREATE ON SCHEMA reporting TO %I', :'app_user') \gexec

-- ------------------------------------------------------------
-- 4.1 让 migrator 成为 app 的成员
--     PostgreSQL 要求「把对象 owner 改成 X」时，当前角色必须是 X 的成员，
--     所以 0005 里把物化视图转交给 app 需要这一条。
-- ------------------------------------------------------------
SELECT format('GRANT %I TO %I', :'app_user', :'migrator_user') \gexec

-- ------------------------------------------------------------
-- 5. 库级权限
-- ------------------------------------------------------------
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db_name', :'app_user') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db_name', :'reader_user') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db_name', :'migrator_user') \gexec

-- ------------------------------------------------------------
-- 6. 角色级默认设置：search_path 放在角色上，
--    这样无论走 pgbouncer 事务池还是直连，路径都一致。
-- ------------------------------------------------------------
SELECT format('ALTER ROLE %I SET search_path = roomdesk, reporting, public', :'migrator_user') \gexec
SELECT format('ALTER ROLE %I SET search_path = roomdesk, reporting, public', :'app_user') \gexec
SELECT format('ALTER ROLE %I SET search_path = roomdesk, reporting, public', :'reader_user') \gexec
-- 让报错里带语句、慢查询日志更好定位
SELECT format('ALTER ROLE %I SET log_min_duration_statement = 200', :'migrator_user') \gexec

-- ------------------------------------------------------------
-- 7. 观测视图的使用权（pg_stat_statements 视图默认只给超级用户）
-- ------------------------------------------------------------
SELECT format('GRANT SELECT ON public.pg_stat_statements TO %I', :'app_user') \gexec
SELECT format('GRANT SELECT ON public.pg_stat_statements TO %I', :'reader_user') \gexec

-- 预定义角色 pg_read_all_stats：不给它的话，pg_stat_statements 会把「别人执行的
-- 语句」的 query 文本显示成 <insufficient privilege>（PG 14+ 的行为）。
SELECT format('GRANT pg_read_all_stats TO %I', :'app_user') \gexec
SELECT format('GRANT pg_read_all_stats TO %I', :'reader_user') \gexec

\echo 'bootstrap: 扩展 / 角色 / schema / 权限 已就绪'
