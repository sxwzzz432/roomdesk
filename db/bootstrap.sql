-- db/bootstrap.sql —— 超级用户执行：扩展 / 角色 / schema / schema 级权限（幂等）
-- 表与视图等对象全部在 db/migrations/ 下，由 roomdesk_migrator 执行。
\set ON_ERROR_STOP on

-- btree_gist: EXCLUDE 约束需要 GiST 支持等值比较；pg_trgm: ILIKE 走索引；pg_stat_statements: /api/ops/db 用
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- \gexec 把 SELECT 的结果当 SQL 执行，所以不需要 DO 块也能幂等
SELECT format('CREATE ROLE %I LOGIN', :'migrator_user')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'migrator_user') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'migrator_user', :'migrator_password') \gexec

SELECT format('CREATE ROLE %I LOGIN', :'app_user')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password') \gexec

SELECT format('CREATE ROLE %I LOGIN', :'reader_user')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'reader_user') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'reader_user', :'reader_password') \gexec

-- reporting 归 migrator；给 app 该 schema 的 CREATE，是为了让物化视图能转交 owner
-- （REFRESH 权限只跟 owner 走，没有对应 GRANT）。业务 schema roomdesk 不给任何 DDL 权限。
SELECT format('CREATE SCHEMA IF NOT EXISTS roomdesk AUTHORIZATION %I', :'migrator_user') \gexec
SELECT format('CREATE SCHEMA IF NOT EXISTS reporting AUTHORIZATION %I', :'migrator_user') \gexec

SELECT format('GRANT USAGE ON SCHEMA roomdesk TO %I', :'app_user') \gexec
SELECT format('GRANT USAGE ON SCHEMA reporting TO %I', :'app_user') \gexec
SELECT format('GRANT USAGE ON SCHEMA roomdesk TO %I', :'reader_user') \gexec
SELECT format('GRANT USAGE ON SCHEMA reporting TO %I', :'reader_user') \gexec
SELECT format('GRANT CREATE ON SCHEMA reporting TO %I', :'app_user') \gexec

-- 把对象 owner 改成 X 要求当前角色是 X 的成员，0005 转移物化视图 owner 需要这条
SELECT format('GRANT %I TO %I', :'app_user', :'migrator_user') \gexec

SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db_name', :'app_user') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db_name', :'reader_user') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db_name', :'migrator_user') \gexec

-- search_path 设在角色上：走 pgbouncer 事务池或直连，行为都一致
SELECT format('ALTER ROLE %I SET search_path = roomdesk, reporting, public', :'migrator_user') \gexec
SELECT format('ALTER ROLE %I SET search_path = roomdesk, reporting, public', :'app_user') \gexec
SELECT format('ALTER ROLE %I SET search_path = roomdesk, reporting, public', :'reader_user') \gexec
SELECT format('ALTER ROLE %I SET log_min_duration_statement = 200', :'migrator_user') \gexec

SELECT format('GRANT SELECT ON public.pg_stat_statements TO %I', :'app_user') \gexec
SELECT format('GRANT SELECT ON public.pg_stat_statements TO %I', :'reader_user') \gexec

-- 缺 pg_read_all_stats 时，别人执行的语句在 pg_stat_statements 里只显示 <insufficient privilege>
SELECT format('GRANT pg_read_all_stats TO %I', :'app_user') \gexec
SELECT format('GRANT pg_read_all_stats TO %I', :'reader_user') \gexec

\echo 'bootstrap: 扩展 / 角色 / schema / 权限 已就绪'
